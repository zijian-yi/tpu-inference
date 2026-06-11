#!/bin/bash
set -e

NAMESPACE="llm-d-pd-disagg"


# 1. Resolve active pod names
DECODE_POD=$(kubectl get pods -n $NAMESPACE -o name | grep "vllm-decode" | sed 's|pod/||')
PREFILL_POD=$(kubectl get pods -n $NAMESPACE -o name | grep "vllm-prefill" | sed 's|pod/||')
echo "Found Decode Pod: $DECODE_POD"
echo "Found Prefill Pod: $PREFILL_POD"


# List of files to sync. Format: ["local_source_path"]="container_destination_path"
declare -A FILES_TO_SYNC=(
  ["../vllm-mine/vllm/v1/request.py"]="/workspace/vllm/vllm/v1/request.py"
  ["tpu_inference/distributed/tpu_connector.py"]="/workspace/tpu_inference/tpu_inference/distributed/tpu_connector.py"
  ["tpu_inference/distributed/tpu_connector_hma.py"]="/workspace/tpu_inference/tpu_inference/distributed/tpu_connector_hma.py"
  ["../vllm-mine/vllm/entrypoints/openai/api_server.py"]="/workspace/vllm/vllm/entrypoints/openai/api_server.py"
  ["../vllm-mine/vllm/v1/core/sched/scheduler.py"]="/workspace/vllm/vllm/v1/core/sched/scheduler.py"
)

# 2. Copy the modified files
echo "Copying changes..."
for src in "${!FILES_TO_SYNC[@]}"; do
  dst="${FILES_TO_SYNC[$src]}"
  echo " - Copying $src to container $dst"
  kubectl cp "$src" "$DECODE_POD:$dst" -c modelserver -n $NAMESPACE
  kubectl cp "$src" "$PREFILL_POD:$dst" -c modelserver -n $NAMESPACE
done

# 3. Trigger reload by killing python
echo "Triggering hot-reload..."
kubectl exec $DECODE_POD -c modelserver -n $NAMESPACE -- pkill -f python3
kubectl exec $PREFILL_POD -c modelserver -n $NAMESPACE -- pkill -f python3

echo "Done! Changes copied and vLLM reloaded."
