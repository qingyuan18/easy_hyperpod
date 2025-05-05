#!/usr/bin/env bash

# 1. Non-Stream test
# 1.1 Localhost
curl localhost:8080/v1/chat/completions \
    -X POST \
    -d '{
  "model": "tgi",
  "messages": [
    {
      "role": "system",
      "content": "You are a helpful assistant."
    },
    {
      "role": "user",
      "content": "What is deep learning?"
    }
  ],
  "stream": false,
  "max_tokens": 20
}' \
    -H 'Content-Type: application/json'


# 1.2 k8s service
curl tgi-engine.tgi.svc.cluster.local:8080/v1/chat/completions \
    -X POST \
    -d '{
  "model": "tgi",
  "messages": [
    {
      "role": "system",
      "content": "You are a helpful assistant."
    },
    {
      "role": "user",
      "content": "What is deep learning?"
    }
  ],
  "stream": false,
  "max_tokens": 20
}' \
    -H 'Content-Type: application/json'

# 1.3 Domain name + Istio
curl http://tgi-engine.yugaozh-flow.com/v1/chat/completions \
    -X POST \
    -d '{
  "model": "tgi",
  "messages": [
    {
      "role": "system",
      "content": "You are a helpful assistant."
    },
    {
      "role": "user",
      "content": "What is deep learning?"
    }
  ],
  "stream": false,
  "max_tokens": 20
}' \
    -H 'Content-Type: application/json'

# 1.4 Domain name + Kong
curl http://tgi-engine-kong.yugaozh-flow.com/v1/chat/completions \
    -X POST \
    -d '{
  "model": "tgi",
  "messages": [
    {
      "role": "system",
      "content": "You are a helpful assistant."
    },
    {
      "role": "user",
      "content": "What is deep learning?"
    }
  ],
  "stream": false,
  "max_tokens": 20
}' \
    -H 'Content-Type: application/json'


# 1.5 Domain name + Kong + 'UUID' header
curl -v http://tgi-engine-kong.yugaozh-flow.com/v1/chat/completions \
    -X POST \
    -d '{
  "model": "tgi",
  "messages": [
    {
      "role": "user",
      "content": "Introduce yourself!!!"
    }
  ],
  "stream": false,
  "max_tokens": 1024
}' \
    -H 'Content-Type:  application/json' -H 'uuid: 1111'