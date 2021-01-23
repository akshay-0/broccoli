#!/bin/bash
set -eu

usage()
{
   echo ""
   echo "Usage: $0 [-a] [-d] [-f] [-k] [-r] [-s] [-w]"
   echo -e "\t-a create Acr"
   echo -e "\t-d build and publish Docker image to container registry"
   echo -e "\t-f upload locust Files to file share"
   echo -e "\t-k create Key vault and client app"
   echo -e "\t-r Run load test"
   echo -e "\t-s create Storage account"
   echo -e "\t-w create Workspaces and computes"
   exit 2
}

create_acr=
create_storage=
create_key_vault=
create_workspaces=
publish_docker_image=
upload_locust_files=
run_load_test=

while getopts "adfkrswh" name
do
    case "$name" in
        a) create_acr=true ;;
        d) publish_docker_image=true ;;
        f) upload_locust_files=true ;;
        k) create_key_vault=true ;;
        r) run_load_test=true ;;
        s) create_storage=true ;;
        w) create_workspaces=true ;;
        h) usage ;;
        ?) usage ;;
    esac
done

source .config

if [ "$create_workspaces" = true ] ; then
    echo ""
    echo "Creating $num_workspaces workspaces..."

    pushd setup

    python setup.py \
        --subscription $workspace_subscription_id \
        --resource-group $workspace_resource_group \
        --location $workspace_location \
        --num-workspaces $num_workspaces \
        --workspace-prefix $workspace_name_prefix \
        --compute-name $compute_name \
        --vm-size $vm_size \
        --min-nodes $min_nodes \
        --max-nodes $max_nodes

    popd
fi

if [ "$create_acr" = true ] ; then
    echo ""
    echo "Creating ACR $acr_name..."

    az acr create \
        --subscription $acr_subscription_id \
        --resource-group $acr_resource_group \
        --location $acr_location \
        --name $acr_name \
        --sku Basic
fi

if [ "$publish_docker_image" = true ] ; then
    echo ""
    echo "Publishing docker image to $acr_name..."

    pushd docker

    az acr build \
        --subscription $acr_subscription_id \
        --resource-group $acr_resource_group \
        --registry $acr_name \
        --image $docker_image .

    popd
fi

if [ "$create_storage" = true ] ; then
    echo ""
    echo "Creating storage account..."

    az storage account create \
        --subscription $storage_subscription_id \
        --resource-group $storage_resource_group \
        --location $storage_location \
        --name $storage_account_name \
        --kind StorageV2 \
        --location $location \
        --sku Standard_LRS
fi

if [ "$upload_locust_files" = true ] ; then
    echo ""
    echo "Uploading files to file share $file_share_name..."

    storage_connection=$(az storage account show-connection-string \
        --subscription $storage_subscription_id \
        --resource-group $storage_resource_group \
        --name $storage_account_name -o tsv)

    az storage share create \
        --name $file_share_name \
        --connection-string $storage_connection

    az storage file delete-batch \
        --source $file_share_name \
        --connection-string $storage_connection

    az storage file upload-batch \
        --destination $file_share_name \
        --source locust/ \
        --connection-string $storage_connection
fi

if [ "$create_key_vault" = true ] ; then
    echo ""
    echo "Creating key vault $key_vault_name..."

    az keyvault create \
        --subscription $key_vault_subscription_id \
        --resource-group $key_vault_resource_group \
        --location $location \
        --name $key_vault_name
fi

set +e

az keyvault secret show \
    --subscription $key_vault_subscription_id \
    --vault-name $key_vault_name \
    --name $client_secret_name > /dev/null 2>&1

out=$?

set -e

if [ $out -ne 0 ] ; then
    echo ""
    echo "Creating new service principal..."

    out=$(az ad sp create-for-rbac --skip-assignment --query '[appId, password, tenant]' -o json)

    client_id=$(echo $out | jq -r .[0])
    client_secret=$(echo $out | jq -r .[1])
    tenant_id=$(echo $out | jq -r .[2])

    echo ""
    echo -e "\t***"
    echo -e "\t* Created new service principal with appId $client_id"
    echo -e "\t***"
    echo ""

    az keyvault secret set \
        --subscription $key_vault_subscription_id \
        --vault-name $key_vault_name \
        --name $client_id_name \
        --value $client_id \
        --query id -o tsv

    az keyvault secret set \
        --subscription $key_vault_subscription_id \
        --vault-name $key_vault_name \
        --name $client_secret_name \
        --value $client_secret \
        --query id -o tsv

    az keyvault secret set \
        --subscription $key_vault_subscription_id \
        --vault-name $key_vault_name \
        --name $tenant_id_name \
        --value $tenant_id \
        --query id -o tsv
fi

if [ "$run_load_test" = true ] ; then
    echo ""
    echo "***"
    echo "Creating workers..."

    az acr update \
        --subscription $acr_subscription_id \
        --resource-group $acr_resource_group \
        --name $acr_name \
        --admin-enabled true \
        --query adminUserEnabled

    acr_username=$(az acr credential show \
        --subscription $acr_subscription_id \
        --resource-group $acr_resource_group \
        --name $acr_name \
        --query username -o tsv)

    acr_password=$(az acr credential show \
        --subscription $acr_subscription_id \
        --resource-group $acr_resource_group \
        --name $acr_name \
        --query passwords[0].value -o tsv)

    storage_connection=$(az storage account show-connection-string \
        --subscription $storage_subscription_id \
        --resource-group $storage_resource_group \
        --name $storage_account_name -o tsv)

    storage_key=$(az storage account keys list \
        --subscription $storage_subscription_id \
        --resource-group $storage_resource_group \
        --account-name $storage_account_name \
        --query [0].value -o tsv)

    client_id=$(az keyvault secret show \
        --subscription $key_vault_subscription_id \
        --vault-name $key_vault_name \
        --name $client_id_name \
        --query value -o tsv)

    client_secret=$(az keyvault secret show \
        --subscription $key_vault_subscription_id \
        --vault-name $key_vault_name \
        --name $client_secret_name \
        --query value -o tsv)

    tenant_id=$(az keyvault secret show \
        --subscription $key_vault_subscription_id \
        --vault-name $key_vault_name \
        --name $tenant_id_name \
        --query value -o tsv)

    az role assignment create \
        --assignee $client_id \
        --role Contributor \
        --scope $(az group show \
            --name $workspace_resource_group \
            --subscription $workspace_subscription_id \
            --query id -o tsv)

    echo -e "\tcreating manager"

    az container create \
        --subscription $aci_subscription_id \
        --resource-group $aci_resource_group \
        --name "manager" \
        --location $aci_location \
        --image "${acr_name}.azurecr.io/$docker_image" \
        --registry-login-server "${acr_name}.azurecr.io" \
        --registry-username $acr_username \
        --registry-password $acr_password \
        --azure-file-volume-mount-path "/mnt/locust" \
        --azure-file-volume-share-name $file_share_name \
        --azure-file-volume-account-name $storage_account_name \
        --azure-file-volume-account-key $storage_key \
        --command-line "locust -f /mnt/locust/locustfile.py --master --expect-workers $num_workers --headless --run-time $run_time --stop-timeout 120 --users $users --spawn-rate $num_workers --tags $tags --logfile /mnt/locust/manager.log --csv manager" \
        --environment-variables \
            SUBSCRIPTION_ID=$workspace_subscription_id \
            RESOURCE_GROUP=$workspace_resource_group \
            LOCATION=$workspace_location \
            WORKSPACE_NAME_PREFIX=$workspace_name_prefix \
            NUM_WORKSPACES=$num_workspaces \
            COMPUTE_NAME=$compute_name \
            CLIENT_ID=$client_id \
            TENANT_ID=$tenant_id \
            WORKER_NUM=0 \
            NUM_WORKERS=$num_workers \
        --secure-environment-variables \
            CLIENT_SECRET=$client_secret \
        --cpu $cpu \
        --memory $memory \
        --ip-address public \
        --ports 5557 \
        --restart-policy Never > /dev/null

    manager_ip=$(az container show \
        --subscription $aci_subscription_id \
        --resource-group $aci_resource_group \
        --name "manager" \
        --query ipAddress.ip -o tsv)

    for i in $(seq 1 $num_workers); do
        echo -e "\tcreating worker $i"

        az container create \
            --subscription $aci_subscription_id \
            --resource-group $aci_resource_group \
            --name "worker$i" \
            --location $aci_location \
            --image "${acr_name}.azurecr.io/$docker_image" \
            --registry-login-server "${acr_name}.azurecr.io" \
            --registry-username $acr_username \
            --registry-password $acr_password \
            --azure-file-volume-mount-path "/mnt/locust" \
            --azure-file-volume-share-name $file_share_name \
            --azure-file-volume-account-name $storage_account_name \
            --azure-file-volume-account-key $storage_key \
            --command-line "locust -f /mnt/locust/locustfile.py --worker --master-host $manager_ip --logfile /mnt/locust/worker$i.log" \
            --environment-variables \
                SUBSCRIPTION_ID=$workspace_subscription_id \
                RESOURCE_GROUP=$workspace_resource_group \
                LOCATION=$workspace_location \
                WORKSPACE_NAME_PREFIX=$workspace_name_prefix \
                NUM_WORKSPACES=$num_workspaces \
                COMPUTE_NAME=$compute_name \
                CLIENT_ID=$client_id \
                TENANT_ID=$tenant_id \
                WORKER_NUM=$i \
                NUM_WORKERS=$num_workers \
            --secure-environment-variables \
                CLIENT_SECRET=$client_secret \
            --cpu $cpu \
            --memory $memory \
            --restart-policy Never \
            --no-wait
    done

    wait_time=0

    while [ $wait_time -lt $aci_wait_time ]; do
        state=$(az container show \
            --subscription $aci_subscription_id \
            --resource-group $aci_resource_group \
            --name worker1 \
            --query provisioningState -o tsv)

        echo -e "\tWorker 1 is in state $state"

        if [ "$state" = "Succeeded" ]; then
            break
        fi

        sleep 1m
        wait_time=$((wait_time+1))
    done

    while [ $wait_time -lt $aci_wait_time ]; do
        state=$(az container show \
            --subscription $aci_subscription_id \
            --resource-group $aci_resource_group \
            --name "worker$num_workers" \
            --query provisioningState -o tsv)

        echo -e "\tWorker $num_workers is in state $state"

        if [ "$state" = "Succeeded" ]; then
            break
        fi

        sleep 1m
        wait_time=$((wait_time+1))
    done

    if [ $wait_time -eq $aci_wait_time ]; then
        echo "Workers not ready in $aci_wait_time minutes - exiting!"
        exit 1
    fi

    echo ""
    echo "***"
    echo "Workers are ready..."

    start_time=$(date +%m%d%H%M)
    echo "Start time is $start_time"

    echo "Waiting for tests to finish ($run_time)..."
    sleep $run_time
    sleep 2m

    echo "*** Load tests finished ***"

    local_logs_dir="$log_dir${start_time}"
    if [ ! -d $local_logs_dir ]; then
        mkdir -p $local_logs_dir;
    fi

    az storage file download-batch \
        --source $file_share_name \
        --destination $local_logs_dir \
        --connection-string $storage_connection

    mkdir -p $local_logs_dir/logs
    mv $local_logs_dir/*.log $local_logs_dir/logs/

    cp .config $local_logs_dir/

    echo "Worker logs downloaded to $local_logs_dir..."

    echo "Deleting workers..."

    az container delete \
        --subscription $aci_subscription_id \
        --resource-group $aci_resource_group \
        --name "manager" \
        --yes > /dev/null

    for i in $(seq 1 $num_workers); do
        az container delete \
            --subscription $aci_subscription_id \
            --resource-group $aci_resource_group \
            --name "worker$i" \
            --yes > /dev/null
    done
fi

echo "Done!"
