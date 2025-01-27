// Copyright 2022 Google LLC All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

terraform {
  required_providers {
    google = {
      source = "google"
      version = "~> 3.84"
    }
    google-beta = {
      source = "google-beta"
      version = "~> 3.84"
    }
  }
}

/******************************************************

Enable Google Cloud Services

*******************************************************/

variable "gcp_service_list" {
  description ="The list of apis necessary for the project"
  type = list(string)
  default = [
    "cloudfunctions.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "containerregistry.googleapis.com",
    "run.googleapis.com",
    "container.googleapis.com",
    "dataflow.googleapis.com",
    "speech.googleapis.com",
    "pubsub.googleapis.com",
    "artifactregistry.googleapis.com",
  ]
}

resource "google_project_service" "gcp_services" {
  for_each = toset(var.gcp_service_list)
  project = "${var.GCP_PROJECT_ID}"
  service = each.key
  disable_dependent_services = true
}

/******************************************************

Google Cloud Storage Resources

*******************************************************/

resource "google_storage_bucket" "text-dropzone" {
  name          = "${var.GCS_BUCKET_TEXT_DROPZONE}"
  location      = "US"
  storage_class = "STANDARD"
  force_destroy = true
}

resource "google_storage_bucket" "audio-dropzone-short" {
  name          = "${var.GCS_BUCKET_AUDIO_DROPZONE_SHORT}"
  location      = "US"
  storage_class = "STANDARD"
  force_destroy = true
}

resource "google_storage_bucket" "audio-dropzone-long" {
  name          = "${var.GCS_BUCKET_AUDIO_DROPZONE_LONG}"
  location      = "US"
  storage_class = "STANDARD"
  force_destroy = true
}

resource "google_storage_bucket" "audio-stt-results" {
  name          = "${var.GCS_BUCKET_AUDIO_STT_RESULTS}"
  location      = "US"
  storage_class = "STANDARD"
  force_destroy = true
}

resource "google_storage_bucket" "gcs-for-cloud-functions" {
  name          = "${var.GCS_BUCKET_CLOUD_FUNCTIONS}"
  location      = "US"
  storage_class = "STANDARD"
  force_destroy = true
}

resource "google_storage_bucket" "kubeflow-pipeline-root" {
  name          = "${var.ML_PIPELINE_ROOT}"
  location      = "US"
  storage_class = "STANDARD"
  force_destroy = true
}

resource "google_storage_bucket" "dataflow-bucket" {
  name          = "${var.GCS_BUCKET_DATAFLOW}"
  location      = "US"
  storage_class = "STANDARD"
  force_destroy = true
}

resource "google_storage_bucket_object" "dataflow-staging-setup" {
  name   = "staging/setup.txt"
  content = "Used for setup"
  bucket = google_storage_bucket.dataflow-bucket.name
}

resource "google_storage_bucket_object" "dataflow-tmp-setup" {
  name   = "tmp/setup.txt"
  content = "Used for setup"
  bucket = google_storage_bucket.dataflow-bucket.name
}

/******************************************************

Google PubSub Resources

*******************************************************/

resource "google_pubsub_topic" "text-input" {
  name = "${var.PUBSUB_TOPIC_TEXT_INPUT}"
  depends_on = [
    google_project_service.gcp_services["pubsub.googleapis.com"]
  ]
}

resource "google_pubsub_topic" "text-scored" {
  name = "${var.PUBSUB_TOPIC_TEXT_SCORED}"
  depends_on = [
    google_project_service.gcp_services["pubsub.googleapis.com"]
  ]
}

resource "google_pubsub_topic" "toxic-topic" {
  name = "${var.PUBSUB_TOPIC_TOXIC}"
  depends_on = [
    google_project_service.gcp_services["pubsub.googleapis.com"]
  ]
}

resource "google_pubsub_subscription" "text-scored-sub-push" {
  name  = "${var.PUBSUB_TOPIC_TEXT_SCORED}-sub"
  topic = google_pubsub_topic.text-scored.name

  ack_deadline_seconds = 20

  push_config {
    push_endpoint = "${var.PUBSUB_TOPIC_TEXT_SCORED_PUSH_ENDPOINT}"

    attributes = {
      x-goog-version = "v1"
    }
  }
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "120s"
  }
  depends_on = [
    google_project_service.gcp_services["pubsub.googleapis.com"]
  ]
}

resource "google_pubsub_subscription" "text-scored-sub-pull" {
  name  = "${var.PUBSUB_TOPIC_TEXT_SCORED}-sub-pull"
  topic = google_pubsub_topic.text-scored.name

  ack_deadline_seconds = 20

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "120s"
  }
  depends_on = [
    google_project_service.gcp_services["pubsub.googleapis.com"]
  ]
}

resource "google_pubsub_subscription" "toxic-topic-sub" {
  name  = "${var.PUBSUB_TOPIC_TOXIC}-sub"
  topic = google_pubsub_topic.toxic-topic.name

  message_retention_duration = "1200s"
  retain_acked_messages      = true
  ack_deadline_seconds       = 10
  enable_message_ordering    = false

  expiration_policy {
    ttl = "300000s"
  }
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "120s"
  }
  depends_on = [
    google_project_service.gcp_services["pubsub.googleapis.com"]
  ]
}

/******************************************************

Google Cloud BigQuery Resources

*******************************************************/

resource "google_bigquery_dataset" "bigquery_dataset" {
  dataset_id    = "${var.BIGQUERY_DATASET}"
  friendly_name = "${var.BIGQUERY_DATASET}"
  description   = "Clean Chat Dataset"
  location      = "${var.BIGQUERY_LOCATION}"
  project       = "${var.GCP_PROJECT_ID}"
}

resource "google_bigquery_table" "bigquery_table_scored" {
  dataset_id = google_bigquery_dataset.bigquery_dataset.dataset_id
  table_id   = "${var.BIGQUERY_TABLE}"
  schema     = file("./schema/bigquery_schema_scored_chats.json")
}

/******************************************************

Google Cloud Functions Resources

*******************************************************/

data "archive_file" "cf-speech-to-text-short-zip" {
 type        = "zip"
 source_dir  = "./components/cloud_functions/speech_to_text_short"
 output_path = "./components/cloud_functions/speech_to_text_short.zip"
}

data "archive_file" "cf-speech-to-text-long-zip" {
 type        = "zip"
 source_dir  = "./components/cloud_functions/speech_to_text_long"
 output_path = "./components/cloud_functions/speech_to_text_long.zip"
}

data "archive_file" "cf-speech-to-text-long-postprocessing-zip" {
 type        = "zip"
 source_dir  = "./components/cloud_functions/speech_to_text_long_postprocessing"
 output_path = "./components/cloud_functions/speech_to_text_long_postprocessing.zip"
}

data "archive_file" "cf-send-to-pubsub-zip" {
 type        = "zip"
 source_dir  = "./components/cloud_functions/send_to_pubsub"
 output_path = "./components/cloud_functions/send_to_pubsub.zip"
}

# Upload zipped cloud functions to Google Cloud Storage
resource "google_storage_bucket_object" "cf-speech-to-text-short-zip" {
 name   = "speech_to_text_short.zip"
 bucket = "${google_storage_bucket.gcs-for-cloud-functions.name}"
 source = "./components/cloud_functions/speech_to_text_short.zip"
}

resource "google_storage_bucket_object" "cf-speech-to-text-long-zip" {
 name   = "speech_to_text_long.zip"
 bucket = "${google_storage_bucket.gcs-for-cloud-functions.name}"
 source = "./components/cloud_functions/speech_to_text_long.zip"
}

resource "google_storage_bucket_object" "cf-speech-to-text-long-postprocessing-zip" {
 name   = "speech_to_text_long_postprocessing.zip"
 bucket = "${google_storage_bucket.gcs-for-cloud-functions.name}"
 source = "./components/cloud_functions/speech_to_text_long_postprocessing.zip"
}

resource "google_storage_bucket_object" "cf-send-to-pubsub-zip" {
 name   = "send_to_pubsub.zip"
 bucket = "${google_storage_bucket.gcs-for-cloud-functions.name}"
 source = "./components/cloud_functions/send_to_pubsub.zip"
}

resource "google_cloudfunctions_function" "cf-speech-to-text-short" {
  name                  = "${var.SOLUTION_NAME}-speech-to-text-short"
  description           = "${var.SOLUTION_NAME} Speech-to-Text Short"
  source_archive_bucket = "${google_storage_bucket_object.cf-speech-to-text-short-zip.bucket}"
  source_archive_object = "${google_storage_bucket_object.cf-speech-to-text-short-zip.name}"
  runtime               = "python39"
  available_memory_mb   = 512
  max_instances         = 3
  timeout               = 120
  region                = "${var.GCP_REGION}"
  entry_point           = "main"
  
  environment_variables = {
    gcs_results_bucket = google_storage_bucket.text-dropzone.name
    gcp_project_id = "${var.GCP_PROJECT_ID}"
    enable_alternative_languages = "true"
  }

  event_trigger {
      event_type = "google.storage.object.finalize"
      resource   = google_storage_bucket.audio-dropzone-short.name
  }
  
  depends_on = [
    time_sleep.wait_x_seconds,
    google_project_service.gcp_services["cloudfunctions.googleapis.com"],
  ]

  timeouts {
    create = "10m"
    delete = "5m"
  }
}

resource "google_cloudfunctions_function" "cf-speech-to-text-long" {
  name                  = "${var.SOLUTION_NAME}-speech-to-text-long"
  description           = "${var.SOLUTION_NAME} Speech-to-Text Long"
  source_archive_bucket = "${google_storage_bucket_object.cf-speech-to-text-long-zip.bucket}"
  source_archive_object = "${google_storage_bucket_object.cf-speech-to-text-long-zip.name}"
  runtime               = "python39"
  available_memory_mb   = 512
  max_instances         = 50
  timeout               = 120
  region                = "${var.GCP_REGION}"
  entry_point           = "main"
  
  environment_variables = {
    gcs_results_stt = google_storage_bucket.audio-stt-results.name
  }
  
  event_trigger {
      event_type = "google.storage.object.finalize"
      resource   = google_storage_bucket.audio-dropzone-long.name
  }
  
  depends_on = [
    time_sleep.wait_x_seconds,
    google_project_service.gcp_services["cloudfunctions.googleapis.com"],
  ]
  
  timeouts {
    create = "10m"
    delete = "5m"
  }
}

resource "google_cloudfunctions_function" "cf-speech-to-text-long-postprocessing" {
  name                  = "${var.SOLUTION_NAME}-speech-to-text-long-postprocessing"
  description           = "${var.SOLUTION_NAME} Speech-to-Text long postprocessing"
  source_archive_bucket = "${google_storage_bucket_object.cf-speech-to-text-long-postprocessing-zip.bucket}"
  source_archive_object = "${google_storage_bucket_object.cf-speech-to-text-long-postprocessing-zip.name}"
  runtime               = "python39"
  available_memory_mb   = 512
  max_instances         = 50
  timeout               = 120
  region                = "${var.GCP_REGION}"
  entry_point           = "main"
  
  environment_variables = {
    gcs_results_bucket = google_storage_bucket.text-dropzone.name
    gcs_audio_long_bucket = google_storage_bucket.audio-dropzone-long.name
  }

  event_trigger {
      event_type = "google.storage.object.finalize"
      resource   = google_storage_bucket.audio-stt-results.name
  }

  depends_on = [
    time_sleep.wait_x_seconds,
    google_project_service.gcp_services["cloudfunctions.googleapis.com"],
  ]

  timeouts {
    create = "10m"
    delete = "5m"
  }
}

resource "google_cloudfunctions_function" "cf-send-to-pubsub" {
  name                  = "${var.SOLUTION_NAME}-send-to-pubsub"
  description           = "${var.SOLUTION_NAME} send text to PubSub"
  source_archive_bucket = "${google_storage_bucket_object.cf-send-to-pubsub-zip.bucket}"
  source_archive_object = "${google_storage_bucket_object.cf-send-to-pubsub-zip.name}"
  runtime               = "python39"
  available_memory_mb   = 256
  max_instances         = 3
  timeout               = 120
  region                = "${var.GCP_REGION}"
  entry_point           = "main"
  
  environment_variables = {
    gcp_project_id = "${var.GCP_PROJECT_ID}"
    pubsub_topic = google_pubsub_topic.text-input.name
  }

  event_trigger {
      event_type = "google.storage.object.finalize"
      resource   = google_storage_bucket.text-dropzone.name
  }

  depends_on = [
    time_sleep.wait_x_seconds,
    google_project_service.gcp_services["cloudfunctions.googleapis.com"],
  ]

  timeouts {
    create = "10m"
    delete = "5m"
  }
}

/******************************************************

IAM Roles and Permissions - Dataflow

*******************************************************/

# Add Cloud Storage Object Admin to Dataflow Service Account
resource "google_project_iam_member" "iam_for_dataflow_storage" {
  project = "${var.GCP_PROJECT_ID}"
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${var.GCP_PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
}
# Add Dataflow Admin permissions to Dataflow Service Account
resource "google_project_iam_member" "iam_for_dataflow_admin" {
  project = "${var.GCP_PROJECT_ID}"
  role    = "roles/dataflow.admin"
  member  = "serviceAccount:${var.GCP_PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
}
# Add Dataflow Worker permissions to Dataflow Service Account
resource "google_project_iam_member" "iam_for_dataflow_worker" {
  project = "${var.GCP_PROJECT_ID}"
  role    = "roles/dataflow.worker"
  member  = "serviceAccount:${var.GCP_PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
}
# Add PubSub Editor to Dataflow Service Account
resource "google_project_iam_member" "iam_for_dataflow_pubsub" {
  project = "${var.GCP_PROJECT_ID}"
  role    = "roles/pubsub.editor"
  member  = "serviceAccount:${var.GCP_PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
}

/******************************************************

IAM Roles and Permissions - Backend API Service

*******************************************************/

# Create Service Account for Backend API Service
resource "google_service_account" "sa" {
  account_id   = "${var.APP_CLOUD_RUN_NAME}-sa"
  display_name = "Service account for ${var.SOLUTION_NAME} backend API service"
}

data "google_iam_policy" "admin" {
  binding {
    role = "roles/iam.serviceAccountUser"
    members = [
      "serviceAccount:${google_service_account.sa.email}",
    ]
  }
}

resource "google_service_account_iam_policy" "admin-account-iam" {
  service_account_id = google_service_account.sa.name
  policy_data        = data.google_iam_policy.admin.policy_data
}

# Update Service Account with PubSub role
resource "google_project_iam_member" "iam_for_backend_api_pubsub" {
  project = "${var.GCP_PROJECT_ID}"
  role    = "roles/pubsub.editor"
  member  = "serviceAccount:${google_service_account.sa.email}"
  depends_on = [
    google_service_account.sa
  ]
}

# Update Service Account with Cloud Storage role
resource "google_project_iam_member" "iam_for_backend_api_gcs" {
  project = "${var.GCP_PROJECT_ID}"
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.sa.email}"
  depends_on = [
    google_service_account.sa
  ]
}

/******************************************************

Sleep Resource

*******************************************************/

resource "null_resource" "previous" {}
resource "time_sleep" "wait_x_seconds" {
  depends_on = [null_resource.previous]
  create_duration = "120s"
}
