#!/usr/bin/env bash

# 1. Non-Stream test
curl http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "/home/app/vllm-engine/models/Llama-2-13B-chat-AWQ",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Who won the world series in 2020?"}
        ]
    }'


curl http://vllm-engine-llama2-13b-chat-awq.vllm.svc.cluster.local:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "/home/app/vllm-engine/models/Llama-2-13B-chat-AWQ",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Who won the world series in 2020?"}
        ]
    }'


curl http://vllm-engine-llama2-13b-chat-awq.yugaozh-flow.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "/home/app/vllm-engine/models/Llama-2-13B-chat-AWQ",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Who won the world series in 2020?"}
        ]
    }'

curl http://vllm-engine-rose-20b-awq.yugaozh-flow.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "/home/app/vllm-engine/models/Rose-20B-AWQ",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Who won the world series in 2020?"}
        ]
    }'

# 2. Stream test
curl http://vllm-engine-llama2-13b-chat-awq.yugaozh-flow.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "/home/app/vllm-engine/models/Llama-2-13B-chat-AWQ",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Who won the world series in 2020?"}
        ],
        "stream": true,
        "max_tokens": 1024
    }'

curl http://localhost:8000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
        "model": "/home/app/vllm-engine/models/Qwen1.5-14B-Chat",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Who won the world series in 2020?"}
        ]
    }'

curl http://k8s-istiosys-istioing-ae3a322d61-42a29373e1894c3f.elb.us-east-1.amazonaws.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Host: vllm-engine-qwen-14b-chat.yugaozh-flow.com" \
    -d '{
        "model": "qwen",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Who won the world series in 2020?"}
        ]
    }'

curl http://vllm-engine-qwen-14b-chat.yugaozh-flow.com/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Host: vllm-engine-qwen-14b-chat.yugaozh-flow.com" \
    -d '{
        "model": "qwen",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Who won the world series in 2020?"}
        ]
    }'
   