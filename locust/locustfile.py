from locust import User, task, tag, between

import os
import time
import logging

from azureml.core import Workspace, Experiment
from azureml.core.authentication import ServicePrincipalAuthentication
from azureml.core.compute import AmlCompute
from azureml.pipeline.core import Pipeline
from azureml.pipeline.steps import PythonScriptStep


subscription_id = os.getenv('SUBSCRIPTION_ID')
resource_group = os.getenv('RESOURCE_GROUP')
location = os.getenv('LOCATION')

workspace_name_prefix = os.getenv('WORKSPACE_NAME_PREFIX')
num_workspaces = int(os.getenv('NUM_WORKSPACES'))

compute_name = os.getenv('COMPUTE_NAME')

client_id = os.getenv('CLIENT_ID')
client_secret = os.getenv('CLIENT_SECRET')
tenant_id = os.getenv('TENANT_ID')

worker_num=int(os.getenv('WORKER_NUM'))
num_workers=int(os.getenv('NUM_WORKERS'))


def pick_a_workspace():
    workspace_name = '%s-%s-%02d' % (workspace_name_prefix, location, worker_num % num_workspaces)
    logging.info('Using workpace %s...' % workspace_name)

    auth = ServicePrincipalAuthentication(
        service_principal_id=client_id,
        service_principal_password=client_secret,
        tenant_id=tenant_id)

    ws = Workspace.get(
        name=workspace_name,
        subscription_id=subscription_id,
        resource_group=resource_group,
        auth=auth)

    logging.info('Found existing workspace %s' % workspace_name)

    return ws


class AmlUser(User):
    # number of seconds to wait between tasks
    wait_time = between(180, 300)

    def on_start(self):
        logging.info('worker on_start..')
        self.ws = pick_a_workspace()

    def on_stop(self):
        logging.info('worker on_stop..')

    @tag('test')
    @task
    def test(self):
        start_time = time.time()
        try:
            step = PythonScriptStep(
                name="sample",
                script_name="script.py",
                compute_target=compute_name,
                source_directory='./scripts',
                allow_reuse=False)

            pipeline = Pipeline(self.ws, steps=[step])

            exp = Experiment(self.ws, 'load-test')
            run = exp.submit(pipeline)

            logging.info('Submitted pipeline run %s in workspace %s' % (run.id, self.ws.name))

            total_time = int((time.time() - start_time) * 1000)
            self.environment.events.request_success.fire(request_type="submit", name=self.ws.name, response_time=total_time, response_length=0)
        except Exception as e:
            logging.error(e)
            total_time = int((time.time() - start_time) * 1000)
            self.environment.events.request_failure.fire(request_type="submit", name=self.ws.name, response_time=total_time, response_length=0, exception=e)
