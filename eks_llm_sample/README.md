**# llm-on-eks**



# 1. Setup Infrastruture

```shell
cd infra
./setup.sh
```

  

# 2. Setup Application

```shell
cd app
./setup.sh
```



##  2.1 Test llm-gateway

```shell
export PROXY_IP=llm-gateway.yugaozh-flow.com

for i in `seq 60`; do curl -sv -H 'apikey: aws-example' $PROXY_IP/api/v1/ 2>&1 | grep -E "(Status|< HTTP)"; done
for i in `seq 60`; do curl -sv -H 'apikey: aws-example' $PROXY_IP/api/v1/slow_query 2>&1 | grep -E "(Status|< HTTP)"; done
```



### 2.1.1 Metrics

```sql
http_requests_total
rate(http_server_request_duration_seconds_sum[5m]) / rate(http_server_request_duration_seconds_count[5m])
```



### 2.1.2 Logs