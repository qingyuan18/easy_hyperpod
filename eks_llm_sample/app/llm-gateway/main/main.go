package main

import (
	"aws-example/llm-gateway/handler"
	"aws-example/llm-gateway/metrics"
	"aws-example/llm-gateway/router"
	"aws-example/llm-gateway/utils"
	"fmt"
	"log"
	"time"
)

var metric *metrics.Metrics = metrics.SetupMetrics()

func init() {
	log.Println("Init func!")
}

func testChan() {
	c1 := make(chan string, 100)

	go func() {
		time.Sleep(time.Second * 5)
		c1 <- "one"
		close(c1)
	}()

	for {
		time.Sleep(time.Second * 1)
		fmt.Println(len(c1))
		select {

		case v, ok := <-c1:
			fmt.Println(len(c1))
			fmt.Printf("%T, %v\n", v, v)
			fmt.Printf("%T, %v\n", ok, ok)
		default:
			fmt.Println("default")
		}
	}
}

func main() {

	// testChan()

	// 1. Generate 'router/fiber application'
	app := router.New()

	// 2. Register multiple handler for service handling
	handler.Register(app, metric)

	// 3. Register health check handle
	utils.SetupHealthCheck(app)

	// 4. Start listen the port
	app.Listen(":3000")
}
