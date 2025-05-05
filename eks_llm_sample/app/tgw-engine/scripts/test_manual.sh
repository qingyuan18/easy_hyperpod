#!/usr/bin/env bash

# 1. Completions interface
# 1.1 Localhost
curl http://127.0.0.1:5000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "This is a cake recipe:\n\n1.",
    "max_tokens": 200,
    "temperature": 1,
    "top_p": 0.9,
    "seed": 10,
    "top_k": 1
  }'


# 2. K8S service
curl http://tgw-engine.tgw.svc.cluster.local:5000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "This is a cake recipe:\n\n1.",
    "max_tokens": 200,
    "temperature": 1,
    "top_p": 0.9,
    "seed": 10,
    "top_k": 1
  }'

# 1.3 Domain name + Istio
curl http://tgw-engine.yugaozh-flow.com/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "This is a cake recipe:\n\n1.",
    "max_tokens": 200,
    "temperature": 1,
    "top_p": 0.9,
    "seed": 10,
    "top_k": 1
  }'

# 1.4 Domain name + Kong
curl http://tgw-engine-kong.yugaozh-flow.com/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "This is a cake recipe:\n\n1.",
    "max_tokens": 200,
    "temperature": 1,
    "top_p": 0.9,
    "seed": 10,
    "top_k": 1
  }'

# 2. Chat completions interface
curl http://tgw-engine.yugaozh-flow.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {
        "role": "user",
        "content": "Hello!"
      }
    ],
    "mode": "instruct",
    "instruction_template": "Alpaca"
  }'

curl http://tgw-engine.yugaozh-flow.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [
      {
        "role": "user",
        "content": "Hello!"
      }
    ],
    "mode": "instruct",
    "instruction_template": "Alpaca",
    "stream": true
  }'