#!/usr/bin/env bash

curl http://llm-gateway.yugaozh-flow.com/api/v1/openai    -H "Content-Type: application/json" -d '{
    "messages": [
        {
            "role": "user",
            "content": "Hello"
        }
    ],
    "mode": "instruct",
    "character": "Alpaca",
    "stream": false
}'

curl http://llm-gateway.yugaozh-flow.com/api/v1/openai    -H "Content-Type: application/json" -d '{
    "messages": [
        {
            "role": "user",
            "content": "Hello"
        }
    ],
    "mode": "instruct",
    "character": "Alpaca",
    "stream": true
}'