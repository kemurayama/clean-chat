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

echo "Cancelling Dataflow Job in 3 seconds"
sleep 3

DATAFLOW_JOB_ID=$(gcloud dataflow jobs list --region ${TF_VAR_DATAFLOW_REGION} --filter "name=scoring-engine" --filter "state=Running" --format "value(JOB_ID)")

if [[ $DATAFLOW_JOB_ID != "" ]]
then
    echo "Cancelling job ID ${DATAFLOW_JOB_ID}"
    gcloud dataflow jobs cancel --region ${TF_VAR_DATAFLOW_REGION} ${DATAFLOW_JOB_ID}
fi