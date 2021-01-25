"""
Create workspaces for load test.

Workspaces are named using workspace prefix and location e.g. aml-load-eastus2euap-00.

For each workspace:
1. provision AML compute with given VM size, min and max nodes.
2. upload `./testdata` to default datastore.
3. register `testdata.txt` as a dataset named `sample_dataset`.

Usage:
setup.py --subscription-id <str> --resource-group <str> --num-workspaces <int>
    [--location <str>] [--workspace-prefix <str>]
    [--compute-name <str>] [--vm-size <str>] [--min-nodes <int>] --max-nodes <int>

Options:

    --subscription-id <str>                 Subscription id to create workspaces
    --resource-group <str>                  Existing resource group for creating workspaces
    --location <str>                        Location for workspaces [default: eastus2euap]
    --num-workspaces <int>                  Number of workspaces to create
    --workspace-prefix <str>                Prefix to use for workspace name [default: aml-load]
    --compute-name <str>                    Name for the compute [default: cpucluster]
    --vm-size <str>                         VM to use for compute [default: STANDARD_D1_v2]
    --min-nodes <int>                       Set minimum nodes for compute [default: 0]
    --max-nodes <int>                       Set maximum nodes for compute

"""

from docopt import docopt
from concurrent.futures import ProcessPoolExecutor

from azureml.core import Workspace, Dataset
from azureml.core.compute import ComputeTarget, AmlCompute
from azureml.core.compute_target import ComputeTargetException
from azureml.exceptions import WorkspaceException
from azureml.core.datastore import Datastore


args = docopt(__doc__)

subscription_id = args['--subscription-id']
resource_group = args['--resource-group']
location = args['--location']
workspace_prefix = args['--workspace-prefix']
num_workspaces = int(args['--num-workspaces'])
compute_name = args['--compute-name']
vm_size = args['--vm-size']
min_nodes = int(args['--min-nodes'])
max_nodes = int(args['--max-nodes'])


def setup(num):
    workspace_name = '%s-%s-%02d' % (workspace_prefix, location, num)

    try:
        ws = Workspace.get(
            name=workspace_name,
            subscription_id=subscription_id,
            resource_group=resource_group)
        print('Found existing workspace %s' % workspace_name)
    except WorkspaceException:
        print('Creating new workspace %s...' % workspace_name)

        ws = Workspace.create(
            name=workspace_name,
            subscription_id=subscription_id,
            resource_group=resource_group,
            location=location)

    try:
        compute_target = AmlCompute(ws, compute_name)
        print('Found existing compute %s' % compute_name)

        compute_target.update(min_nodes=min_nodes, max_nodes=max_nodes)
    except ComputeTargetException:
        print('Creating new compute target %s...' % compute_name)

        compute_config = AmlCompute.provisioning_configuration(vm_size=vm_size, min_nodes=min_nodes, max_nodes=max_nodes)
        compute_target = ComputeTarget.create(ws, compute_name, compute_config)
        compute_target.wait_for_completion(show_output=True, timeout_in_minutes=20)

    ds = ws.get_default_datastore()
    ds.upload("testdata")

    dataset_name = 'sample_dataset'

    if dataset_name not in ws.datasets:
        data = Dataset.File.from_files(path=[(ds, 'testdata.txt')])

        data.register(
            workspace = ws,
            name = dataset_name,
            description = 'Sample data for load test')

        print('Dataset successfully registered')
    else:
        print('Dataset already exists')


if __name__ == '__main__':
    with ProcessPoolExecutor() as pool:
        for i in range(num_workspaces):
            pool.submit(setup, i)
