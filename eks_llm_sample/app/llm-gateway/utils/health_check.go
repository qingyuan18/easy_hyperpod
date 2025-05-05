package utils

import (
	"fmt"

	"github.com/gofiber/fiber/v2"
)

func SetupHealthCheck(app *fiber.App) {

	fmt.Println("Setup health check interface.")

	setupStartupProbe(app)
	setupLivenessProbe(app)
	setupReadinessProbe(app)

}

func setupStartupProbe(app *fiber.App) {
	app.Get("/api/startup", func(c *fiber.Ctx) error {
		return c.SendString("Startup 👋!\n")
	})
}

func setupLivenessProbe(app *fiber.App) {
	app.Get("/api/liveness", func(c *fiber.Ctx) error {
		return c.SendString("Liveness 👋!\n")
	})
}

func setupReadinessProbe(app *fiber.App) {
	app.Get("/api/readiness", func(c *fiber.Ctx) error {
		return c.SendString("Readiness 👋!\n")
	})
}
