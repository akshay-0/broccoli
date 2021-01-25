# broccoli

This tool should be able to do everything that's needed to run a load test for AML. It creates workspaces, compute clusters, provisions all the resources required for testing, runs a distributed load test using a cluster of Azure Container Instances, and downloads stats and logs when the test finishes.

It's simple, really.

In most cases, only file you'll need to edit is the `.config` file. This is where you specify your subscription id and resource group. It also allows you to tweak many other aspects of the load test. The file has generous comments about what each of the configs is used for and should be self-explanatory.

When config file is ready, simply run `./broccoli.sh -adfkrsw` to provision all the resources and run a distributed load test.

## Quick start

* Prerequisites

    - linux/wsl
    - azure cli
    - jq

* Update config file

Create a resource group and update [.config](.config) file to specify subscription id and resource group name.

You may also want to change the number of workspaces (num_workspaces), max compute nodes per cluster (max_nodes), number of worker instances (num_workers), and how long to run the test (run_time).

* Write test

Edit [locustfile](/locust/locustfile) and update `test` method according to your scenario. For illustration, the current test is setup to submit a single step pipeline every ~4 minutes.

Locust documentation is [here](https://docs.locust.io/en/stable/).

* Run

Run `./broccoli.sh -adfkrsw` to provision all the resources and run distributed load test.

See next section for all options.

## Options

Run `./broccoli.sh -h` to see what each of the options does and adapt to your scenario.

    -a create Acr
    -d build and publish Docker image to container registry
    -f upload locust Files to file share
    -k create Key vault and client app
    -r Run load test
    -s create Storage account
    -w create Workspaces and computes

Sample usage:

- `./broccoli.sh -adfkrsw`  

Provision all the resources and run load test (useful for first run)

- `./broccoli.sh -fr`  

Upload latest test files and run load test, assumes workspaces and other resources are already provisioned (useful for subsequent runs)

- `./broccoli.sh -w`  

Create workspaces and computes but do not run any test

## Under the hood

There are many things happening under the hood and while understanding everything is not critical for running the tests, it may be useful to place different pieces together.

* Create AML workspaces and computes

We start by creating workspaces that will be the target of this load test. Each workspace contains an AML compute cluster, and a simple text file is registered as a dataset named `sample_dataset` in each workspace.

Number of workspaces, number of compute nodes and VM sizes can be configured in `.config` file.

* Create docker image

Next we build a docker image containing [locust](https://locust.io/) and azureml-sdk - this allows us to use azureml sdk in our locust script. 

This image is published to an Azure Container Registry (ACR). Dockerfile used to build the image is available [here](/docker/).

* Upload locust files

The [directory](/locust/) containing locust script and other files required to run the load test is uploaded to a file share. This file share is later mounted on the containers, making the files in this local directory available to all containers.

* Create service principal

Since tests running in remote container instances cannot use your credentials, a service principal is used instead. If not already available, a new service principal is created and stored in the key vault for reuse.

This service principal is also given contributor access to the workspace resource group. Locust script uses this service principal to authenticate and access AML workspaces.

* Create container instances

Next we create a cluster of Azure Container Instances.

These containers are provisioned to run docker image that was previously built and published to ACR, making locust and azureml-sdk available to run on containers. 

These containers also have access to all files in the `./locust` directory on account of files being uploaded to a remote file share and mounting the file share on the containers. 

Once ready, these containers start running locust tests based on configuration available in `.config` file.

* Download logs

When the load test is complete, logs from all containers are downloaded and copied to a local directory, along with the config and locust files for posterity.

* Tidy up

Finally, the container instances are deleted. Rest of the resources like AML workspaces, container registry etc are not deleted as they can be reused for subsequent runs.
