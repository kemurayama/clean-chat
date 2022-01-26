# Copyright 2022 Google LLC All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Load Config
include ./config

.PHONY: help gcloud deploy-all terraform-init terraform-apply

help:
	@echo ""
	@echo "Enable GCP APIs"
	@echo "    make enable-gcp-apis"
	@echo ""
	@echo "Initialize Terraform"
	@echo "    make terraform-init"
	@echo ""
	@echo "Terraform Apply"
	@echo "    make terraform-apply"
	@echo ""
	@echo "Deploy realtime Scoring Engine"
	@echo "    make deploy-scoring-engine"
	@echo ""
	@echo "Deploy realtime Scoring Engine in Interactive Mode (testing/debugging)"
	@echo "    make deploy-scoring-engine-interactive"
	@echo ""
	@echo "Deploy API Endpoints"
	@echo "    make deploy-endpoints"
	@echo ""
	@echo "Delete Services"
	@echo "    make destroy-all"
	@echo ""

deploy-all: terraform-init terraform-apply deploy-scoring-engine deploy-endpoints

# APIs should be enabled as part of the Terraform deployment. 
# This make target can be used as an alternative way to enable 
# all required GCP APIs if needed.
enable-gcp-apis:
	gcloud services enable \
	storage.googleapis.com \
	containerregistry.googleapis.com \
	artifactregistry.googleapis.com \
	cloudbuild.googleapis.com \
	cloudfunctions.googleapis.com \
	container.googleapis.com \
	run.googleapis.com \
	dataflow.googleapis.com \
	speech.googleapis.com \
	pubsub.googleapis.com

terraform-init:
	$(info GCP_PROJECT_ID is [${TF_VAR_GCP_PROJECT_ID}])
	terraform init

terraform-apply:
	$(info GCP_PROJECT_ID is [${TF_VAR_GCP_PROJECT_ID}])
	terraform apply

destroy-all: destroy-backend-api destroy-scoring-engine destroy-terraform

destroy-backend-api:
	$(info GCP_PROJECT_ID is [${TF_VAR_GCP_PROJECT_ID}])
	@echo "Shutting down and deleting the Backend API Service"
	gcloud run services delete ${TF_VAR_APP_CLOUD_RUN_NAME} --region ${TF_VAR_APP_CLOUD_RUN_REGION} --no-async

destroy-scoring-engine:
	$(info GCP_PROJECT_ID is [${TF_VAR_GCP_PROJECT_ID}])
	./components/scoring_engine/cancel-dataflow-job.sh

destroy-terraform:
	$(info GCP_PROJECT_ID is [${TF_VAR_GCP_PROJECT_ID}])
	@echo "Shutting down and deleting all Terraform deployed services"
	terraform destroy

deploy-scoring-engine:
	@echo "Deploying Antidote Scoring Engine."
	@echo "This may take a few minutes."
	@echo "You can go here to see the running job: https://console.cloud.google.com/dataflow/jobs"
	nohup ./components/scoring_engine/deploy-scoring-engine.sh &

deploy-scoring-engine-interactive:
	@echo "Deploying Antidote Scoring Engine (in interactive mode)"
	./components/scoring_engine/deploy-scoring-engine-interactive.sh

deploy-endpoints:
	@echo "Deploying API backend app"
	./components/api/backend_python/deploy_cloud_run_for_backend.sh

# Antidote Model Sidecar - Local Training

train-basic: 
	@echo "Enterining Local Training"
	@echo "Select Model Type BERT or cohere: "; \
    read MODEL; \
	@python3 ./components/scoring_engine/main.py \
		--gcp_project {GCP_PROJECT_ID} \
		--gcs_location {GCP_BUCKET} \
		--model_type MODEL


# Antidote Model Sidecar - TFX Training in Cloud

create-pipeline-cluster:
	export PIPELINE_CLUSTER_NAME=${TF_VAR_ML_CLUSTER}
	export PIPELINE_VERSION=1.7.1
	export ZONE=${TF_VAR_GCP_REGION}
	export MACHINE_TYPE=${TF_VAR_ML_MACHINE_TYPE}
	export SCOPES=${TF_VAR_ML_SCOPES}

	gcloud container clusters create $CLUSTER_NAME \
     	--zone ${ZONE} \
     	--machine-type ${MACHINE_TYPE} \
     	--scopes ${SCOPES}

	# Deploy Kubeflow on Cluster 

	export PIPELINE_VERSION=1.7.1
	kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=${PIPELINE_VERSION}"
	kubectl wait --for condition=established --timeout=60s crd/applications.app.k8s.io
	kubectl apply -k "github.com/kubeflow/pipelines/manifests/kustomize/env/dev?ref=${PIPELINE_VERSION}"

	# Get Pipeline Endpoint
	gcloud container clusters get-credentials toxicity-pipelines --zone us-central1-a --project ${TF_VAR_GCP_PROJECT_ID}
	export KUBEFLOW_ENDPOINT = kubectl describe configmap inverse-proxy-config -n kubeflow | grep googleusercontent.com

install-skaffold:
	curl -Lo skaffold https://storage.googleapis.com/skaffold/releases/latest/skaffold-linux-amd64 \ 
	sudo install skaffold /usr/local/bin/

tfx-create-pipeline:
	tfx pipeline create \
		--pipeline-path=kubeflow_dag_runner.py \
		--endpoint=${KUBEFLOW_ENDPOINT} \
		--build-image

tfx-update-pipeline:
	tfx pipeline update \
		--pipeline-path=kubeflow_dag_runner.py \
		--endpoint=${KUBEFLOW_ENDPOINT}

tfx-run:
	tfx run create \
		--pipeline-name=${TF_VAR_ML_PIPELINE_NAME} \
		--endpoint=${KUBEFLOW_ENDPOINT}
tfx-list: 
	tfx pipeline list \
	--engine=kubeflow \
	--endpoint=${KUBEFLOW_ENDPOINT}


# Antidote Model Sidecar - Model Deployment 

build-model-serving:
	@echo "Building Tensorflow Serving Container"
	docker pull tensorflow/serving
	docker run -d --name serving_base tensorflow/serving
	@echo "Attaching Model"
	docker cp ../components/model_pipeline/antidote_serving serving_base:/models/antidote_serving
	docker commit --change "ENV MODEL_NAME antidote_serving" serving_base $USER/antidote_serving
	docker tag antidote_serving gcr.io/tensorflow-serving-229609/antidote_serving:v0.1.0
	docker push gcr.io/tensorflow-serving-229609/antidote_serving:v0.1.0
	@echo "Model Container Pushed to Container Registry"

create-serving-cluster:
	@echo "Creating Serving Cluster for Toxicity Model"
	gcloud container clusters create ANTIDOTE_SERVING_CLUSTER \
		--num-nodes 5 \
		--service-account ${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com \
		--preemptible
		--enable-autoscaling \
  		--min-nodes=1 \
  		--max-nodes=3 \
  		--num-nodes=1 
	gcloud config set container/cluster ANTIDOTE_SERVING_CLUSTER
	gcloud container clusters get-credentials 
	@echo "Serving Cluster Created"

deploy-image:
	@echo "Deploying Image to K8s Cluster"
	kubectl set image deployment/antidote-model-deployment image=gcr.io/tensorflow-serving-229609/antidote_serving:v0.1.0
	kubectl create -f antidote_k8s.yaml

serve-latest-model: 
	@echo "Pushing Latest Model to Production"
	# TODO: Update Parameters, Port, model name
	docker run -p 8501:8501 -e MODEL_BASE_PATH=gs://$BUCKET_NAME -e MODEL_NAME=antidote_serving -t tensorflow/serving
