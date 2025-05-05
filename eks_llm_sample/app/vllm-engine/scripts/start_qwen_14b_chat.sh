#!/usr/bin/env bash

python3 -m vllm.entrypoints.openai.api_server \
    --model /home/app/vllm-engine/models/Qwen1.5-14B-Chat \
    --trust-remote-code \
    --dtype float16 \
    --pipeline-parallel-size 1 \
    --tensor-parallel-size 4 \
    --gpu-memory-utilization 0.9 \
    --max-model-len 32768 \
    --max-num-batched-tokens 32768 \
    --max-num-seqs 256 \
    --disable-custom-all-reduce \
    --enable-prefix-caching \
    --disable-log-requests \
    --served-model-name qwen
