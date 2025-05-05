package handler

import (
	"aws-example/llm-gateway/metrics"
)

var metric *metrics.Metrics

func RegisterHandlerMetric(m *metrics.Metrics) {
	metric = m
}
