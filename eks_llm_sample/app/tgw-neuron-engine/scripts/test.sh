#!/usr/bin/env bash

# 1. Completions interface
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

curl http://tgw-neuron-engine.tgw-neuron.svc.cluster.local:5000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "This is a cake recipe:\n\n1.",
    "max_tokens": 200,
    "temperature": 1,
    "top_p": 0.9,
    "seed": 10,
    "top_k": 1
  }'

curl http://tgw-neuron-engine.yugaozh-flow.com/v1/completions \
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
# 2.1 Non-stream
curl http://127.0.0.1:5000/v1/chat/completions \
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
    "top_k": 1
  }'

# 2.2 Stream
curl http://127.0.0.1:5000/v1/chat/completions \
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
    "top_k": 1,
    "stream": true
  }'

curl http://tgw-neuron-engine.yugaozh-flow.com/v1/chat/completions \
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
    "top_k": 1,
    "stream": true
  }'