package handler

import (
	"aws-example/llm-gateway/metrics"

	"github.com/gofiber/fiber/v2"
)

func Register(app *fiber.App, metric *metrics.Metrics) {
	// 1. Register metrics handler
	RegisterHandlerMetric(metric)

	// 2. Register route handler
	api := app.Group("/api")

	v1 := api.Group("v1")

	RegisterRootRouteHandle(v1)
	RegisterSlowRouteHandle(v1)
	RegisterOpenAIRouteHandle(v1)
}
