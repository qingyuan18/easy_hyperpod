package handler

import (
	"aws-example/llm-gateway/metrics"
	"aws-example/llm-gateway/utils"
	"log"

	"github.com/gofiber/fiber/v2"
)

func rootRouteHandler(ctx *fiber.Ctx) error {
	log.Println("Receive request from root route : ", ctx)

	metrics.UpdateHttpReqs(metric, "/", "200", "GET")
	metrics.UpdateSysLoad(metric, "ai", utils.RandFloat(1, 2))

	return ctx.SendString("Hello, World 👋!\n")
}

func RegisterRootRouteHandle(router fiber.Router) {
	router.Get("/", rootRouteHandler)
}
