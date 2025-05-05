#!/usr/bin/env bash


python3 -m vllm.entrypoints.openai.api_server \
    --model /home/app/vllm-engine/models/Rose-20B-AWQ \
    --trust-remote-code \
    --max-model-len 2048 \
    --pipeline-parallel-size 1 \
    --tensor-parallel-size 1 \
    --enable-prefix-caching \
    --max-parallel-loading-workers 1 \
    --gpu-memory-utilization 0.9 \
    --max-num-batched-tokens 4096 \
    --max-num-seqs 4096 \
    --disable-log-requests \
    --quantization awq