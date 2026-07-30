# Copyright 2025 Google LLC
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

ARG BASE_IMAGE="python:3.12-slim-bookworm"
# The latest main will be used if arg unspecified
ARG VLLM_COMMIT_HASH=""

FROM $BASE_IMAGE

ARG IS_TEST="false"
ARG BM_INFRA="false"

# Update pip
RUN pip install --upgrade pip

# Install some basic utilities
RUN apt-get update && apt-get install -y \
    git \
    libopenmpi-dev \
    libomp-dev \
    procps \
    curl \
    netcat-openbsd \
    rclone \
    wget \
    bc \
    ca-certificates \
    unzip \
    build-essential \
    cmake \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Conditionally install google-cloud-cli for benchmarking infrastructure
RUN if [ "$BM_INFRA" = "true" ]; then \
        apt-get update && apt-get install -y gnupg curl \
        && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list \
        && curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
        && apt-get update && apt-get install -y google-cloud-cli \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Build vLLM
WORKDIR /workspace/vllm
ARG VLLM_REPO=https://github.com/zijian-yi/vllm.git
ARG VLLM_COMMIT_HASH="40a77bf154c050bb05bc7fa11bfa8d0a6b1d1dc6"

RUN git clone $VLLM_REPO . && \
    if [ -n "$VLLM_COMMIT_HASH" ]; then \
        git checkout $VLLM_COMMIT_HASH; \
    fi

RUN pip install --extra-index-url https://download.pytorch.org/whl/cpu -r requirements/tpu.txt --retries 3
RUN pip install setuptools-rust>=1.9.0
RUN VLLM_TARGET_DEVICE="tpu" pip install --no-build-isolation -e .

# Install test dependencies
RUN python3 -m pip install -e tests/vllm_test_utils
RUN python3 -m pip install \
    git+https://github.com/thuml/depyf.git \
    pytest-asyncio \
    "lm-eval[api,math]==0.4.12" \
    pytest-cov \
    tblib

# Install tpu_inference
WORKDIR /workspace/tpu_inference
# Install requirements first and cache so we don't need to re-install on code change.
COPY requirements.txt .
RUN pip install --extra-index-url https://download.pytorch.org/whl/cpu -r requirements.txt --retries 3
COPY requirements_benchmarking.txt .
# These are needed for the E2E benchmarking tests (i.e. tests/e2e/benchmarking/mlperf.sh)
RUN pip install -r requirements_benchmarking.txt --retries 3
# Install test requirements
COPY requirements_test.txt .
RUN if [ "$IS_TEST" = "true" ]; then \
        pip install -r requirements_test.txt --retries 3; \
    fi
COPY . .
RUN pip install -e .

# Set environment variables to avoid disk space warnings/failures in Bazel
ENV BAZEL_CACHE_DIR="${HOME}/.bazel_cache"
ENV BAZEL_OUTPUT_BASE=/tmp/bazel_output

# Restrict Bazel to 16 parallel jobs and 30GB RAM to prevent gcc OOM kill
RUN echo "build --jobs=16 --local_ram_resources=30720" > ~/.bazelrc

ARG RAIDEN_REPO=https://github.com/zijian-yi/tpu-raiden
ARG RAIDEN_COMMIT_HASH="0017e33df0261b87dc6391a11a60c49d912f45a7"

# Checkout a runnable version and build tpu-raiden for JAX only
RUN git clone $RAIDEN_REPO /workspace/tpu-raiden \
    && cd /workspace/tpu-raiden \
    && git checkout $RAIDEN_COMMIT_HASH \
    && ./build.sh jax

ENV PYTHONPATH="/workspace/tpu-raiden:${PYTHONPATH}"

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD []
