#!/bin/bash

# Imports an OVA (already in S3) as an AMI using 'aws ec2 import-image', and tags the resulting AMI with provided tags (if any)

if (( $# < 1 )); then
    echo "Usage import_ova_as_ami.sh vm.ova aws_cli_extra_args"
    exit 1;
fi

OVA="$1"
EXTRA_AWS_CLI_ARGS="$2"

set -u -e

result_json=$(aws ec2 import-image --description "JaiaBot" --disk-containers "Format=ova,UserBucket={S3Bucket=jaiabot-images-test,S3Key=vbox/${OVA}}" ${EXTRA_AWS_CLI_ARGS})

cmd_status=$(echo "$result_json" | jq -r '.Status')

if [[ "$cmd_status" != "active" ]]; then
   echo "Failed to run 'aws ec2 import-image': ${result_json}"
   exit 1;
fi

import_task_id=$(echo "$result_json" | jq -r '.ImportTaskId')

while [[ "$cmd_status" == "active" ]]; do
    result_json=$(aws ec2 describe-import-image-tasks --import-task-ids ${import_task_id} ${EXTRA_AWS_CLI_ARGS})
    cmd_status=$(echo "$result_json" | jq -r '.ImportImageTasks[0].Status')
    echo "$result_json"
    sleep 10
done

if [[ "$cmd_status" != "completed" ]]; then
   echo "Failed to complete import-image: ${result_json}"
   exit 1;
fi

echo "${result_json}" > result.json
echo "Success (full result in result.json)"
