package handler

import (
	"aws-example/llm-gateway/metrics"
	"aws-example/llm-gateway/utils"
	"log"
	"time"

	"github.com/gofiber/fiber/v2"
)

func slowRouteHandler(ctx *fiber.Ctx) error {
	log.Println("Receive request from slow route : ", ctx)

	start := time.Now()
	utils.RandSleep(10)
	duration := time.Since(start)

	metrics.UpdateHttpReqs(metric, "/slow_query", "500", "GET")
	metrics.UpdateHttpRespTime(metric, "/slow_query", "500", "GET", duration.Seconds())

	return ctx.SendString("Hello, Slow Query 👋!\n")
}

func RegisterSlowRouteHandle(router fiber.Router) {
	router.Get("/slow_query", slowRouteHandler)
}
