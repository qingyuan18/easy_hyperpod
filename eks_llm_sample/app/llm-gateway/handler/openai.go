package handler

import (
	"aws-example/llm-gateway/metrics"
	"aws-example/llm-gateway/utils"
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
	openai "github.com/sashabaranov/go-openai"
	"github.com/valyala/fasthttp"
)

type session struct {
	val string
	// stateChannel chan string
	streamChannel chan openai.ChatCompletionStreamResponse
	stateChannel  chan bool
}

type sessionsLock struct {
	mutex    sync.Mutex
	sessions []*session
}

func (sl *sessionsLock) addSession(s *session) {
	sl.mutex.Lock()
	sl.sessions = append(sl.sessions, s)
	sl.mutex.Unlock()
}

func (sl *sessionsLock) removeSession(s *session) {
	sl.mutex.Lock()
	idx := slices.Index(sl.sessions, s)
	if idx != -1 {
		sl.sessions[idx] = nil
		sl.sessions = slices.Delete(sl.sessions, idx, idx+1)
	}
	sl.mutex.Unlock()
}

var (
	currentSessions sessionsLock
	client          *openai.Client
	ctxBackGround   context.Context
	wg              sync.WaitGroup
)

func init() {
	config := openai.ClientConfig{
		BaseURL:            "http://tgw-engine.tgw.svc.cluster.local:5000/v1",
		HTTPClient:         &http.Client{},
		EmptyMessagesLimit: 300,
	}
	// config := openai.DefaultAzureConfig("", "http://localhost:3000/v1")
	client = openai.NewClientWithConfig(config)
	ctxBackGround = context.Background()
}

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type OpenaiPayload struct {
	Messages  []Message `json:"messages"`
	Mode      string    `json:"mode"`
	Character string    `json:"character"`
	Stream    bool      `json:"stream"`
}

func handleChatCompletionRequest(ctx *fiber.Ctx,
	ses session,
	model string,
	maxTokens int,
	messages []openai.ChatCompletionMessage,
	stream bool) {

	defer wg.Done()

	defer close(ses.stateChannel)
	defer close(ses.streamChannel)

	defer func() {
		err := recover()
		if err != nil {
			log.Println("handleChatCompletionRequest exception :", err)
			ses.stateChannel <- true
			// close(ses.stateChannel)
		}
	}()

	start := time.Now()

	req := openai.ChatCompletionRequest{
		Model:     model,
		MaxTokens: maxTokens,
		Messages:  messages,
		Stream:    stream,
	}

	s, err := client.CreateChatCompletionStream(ctxBackGround, req)
	if err != nil {
		log.Printf("ChatCompletionStream error: %v\n", err)
		ses.stateChannel <- true
	}

	defer s.Close()

	firstStreamRecv := true
	for {
		resp, err := s.Recv()
		if firstStreamRecv {
			duration := time.Since(start)
			log.Printf("First token time : %v\n", duration)
			log.Printf("Stream start recv : %v\n", ses)
			firstStreamRecv = false
		}

		if errors.Is(err, io.EOF) {
			log.Printf("Finish stream recv : %v\n", ses)
			ses.stateChannel <- true
			break
		}

		if err != nil {
			log.Printf("\nStream error: %v\n", err)
			ses.stateChannel <- true
			break
		}
		ses.streamChannel <- resp

		// log.Printf("Write content: %v, chan len : %v", resp.Choices[0].Delta.Content, len(ses.streamChannel))
	}

	duration := time.Since(start)
	log.Printf("Total token time : %v\n", duration)

	metrics.UpdateHttpReqs(metric,
		"/openai",
		strconv.Itoa(http.StatusOK),
		http.MethodPost)
	metrics.UpdateHttpRespTime(metric,
		"/openai",
		strconv.Itoa(http.StatusOK),
		http.MethodPost,
		duration.Seconds())
}

func openAIStreamHandler(ctx *fiber.Ctx) error {
	// 1. Setup 'Response'
	ctx.Set("Content-Type", "text/event-stream")
	ctx.Set("Cache-Control", "no-cache")
	ctx.Set("Connection", "keep-alive")
	ctx.Set("Transfer-Encoding", "chunked")

	// 2. Setup 'session'
	reqId := uuid.New().String()
	// streamChan := make(chan openai.ChatCompletionStreamResponse, 100)
	streamChan := make(chan openai.ChatCompletionStreamResponse)
	stateChan := make(chan bool, 1)

	reqSession := session{
		val:           reqId,
		streamChannel: streamChan,
		stateChannel:  stateChan,
	}
	// log.Println(reqSession)

	// 3. Validate 'payload'
	payload := new(OpenaiPayload)

	if err := ctx.BodyParser(payload); err != nil {
		log.Println("Payload err: ", err)
		return err
	}
	currentSessions.addSession(&reqSession)

	log.Println("######## currentSessions - add:", reqSession)
	for i := 0; i < len(currentSessions.sessions); i++ {
		log.Println("session:", currentSessions.sessions[i])
	}
	log.Println("###############################")

	// 4. Handle 'ChatCompletionRequest'
	wg.Add(1)
	messages := []openai.ChatCompletionMessage{
		{
			Role:    openai.ChatMessageRoleUser,
			Content: payload.Messages[0].Content,
		},
	}
	go handleChatCompletionRequest(ctx, reqSession, openai.GPT3Dot5Turbo, 200, messages, true)

	// 5.
	ctx.Context().SetBodyStreamWriter(fasthttp.StreamWriter(func(w *bufio.Writer) {
		keepAliveTickler := time.NewTicker(15 * time.Second)
		keepAliveMsg := ":keepalive\n"

		for loop := true; loop; {
			// time.Sleep(time.Millisecond * 10)
			select {

			case state, not_empty := <-reqSession.stateChannel:
				if state || not_empty {
					log.Printf("Read state content: %v %v, chan len : %v", state, not_empty, len(reqSession.stateChannel))
					log.Printf("Close stream read : %v\n", reqSession)
					currentSessions.removeSession(&reqSession)
					keepAliveTickler.Stop()
					loop = false

					log.Println("######## currentSessions - remove - close stream:")

					for i := 0; i < len(currentSessions.sessions); i++ {
						log.Println("session:", currentSessions.sessions[i])
					}
				}

			case data, not_empty := <-reqSession.streamChannel:
				if not_empty {
					val := data.Choices[0].Delta.Content
					// log.Printf("Read stream content: %v %v, chan len : %v", val, not_empty, len(reqSession.streamChannel))
					fmt.Fprintf(w, "%s\n", val)
					// 应该调用w.Flush(), 但测试发现测试后w.Flush()会Block, 还没找到原因
					// w.Flush()
					// err := w.Flush()
					// if err != nil {
					// 	log.Printf("Error while flushing: %v.\n", err)
					// 	currentSessions.removeSession(&reqSession)
					// 	keepAliveTickler.Stop()
					// 	loop = false
					// }
				}

			case <-keepAliveTickler.C:
				fmt.Println("keepAliveTickler.C")
				fmt.Fprintf(w, "%s", keepAliveMsg)
				err := w.Flush()
				if err != nil {
					log.Printf("Error while flushing: %v.\n", err)
					currentSessions.removeSession(&reqSession)
					keepAliveTickler.Stop()
					loop = false
				}
				// default:
				// 	log.Println("default")
			}

		}

		log.Printf("Exiting stream : %v\n", reqSession)
	}))

	wg.Wait()

	return nil
}

func openAINonStreamHandler(ctx *fiber.Ctx) error {
	log.Println("Receive request from openai route : ", string(ctx.Body()))

	payload := new(OpenaiPayload)

	if err := ctx.BodyParser(payload); err != nil {
		log.Println("Payload err: ", err)
		return err
	}

	start := time.Now()

	resp, err := client.CreateChatCompletion(
		context.Background(),
		openai.ChatCompletionRequest{
			Model: openai.GPT3Dot5Turbo,
			Messages: []openai.ChatCompletionMessage{
				{
					Role:    openai.ChatMessageRoleUser,
					Content: payload.Messages[0].Content,
				},
			},
		},
	)

	duration := time.Since(start)

	if err != nil {
		log.Printf("ChatCompletion error: %v\n", err)

		metrics.UpdateHttpReqs(metric,
			"/openai",
			strconv.Itoa(http.StatusInternalServerError),
			http.MethodPost)
		metrics.UpdateHttpRespTime(metric,
			"/openai",
			strconv.Itoa(http.StatusInternalServerError),
			http.MethodPost,
			duration.Seconds())

		return ctx.Status(http.StatusInternalServerError).JSON(utils.NewError(err))
	}

	metrics.UpdateHttpReqs(metric,
		"/openai",
		strconv.Itoa(http.StatusOK),
		http.MethodPost)
	metrics.UpdateHttpRespTime(metric,
		"/openai",
		strconv.Itoa(http.StatusOK),
		http.MethodPost,
		duration.Seconds())

	log.Println("resp : ", resp.Choices[0].Message.Content)

	return ctx.SendString(resp.Choices[0].Message.Content)
}

func openAIHandler(ctx *fiber.Ctx) error {
	log.Println("Receive request from openai route : ", string(ctx.Body()))

	payload := new(OpenaiPayload)

	if err := ctx.BodyParser(payload); err != nil {
		log.Println("Payload err: ", err)
		return err
	}

	log.Println(payload)

	stream := payload.Stream

	if stream {
		return openAIStreamHandler(ctx)
	} else {
		return openAINonStreamHandler(ctx)
	}
}

func RegisterOpenAIRouteHandle(router fiber.Router) {
	router.Post("/openai", openAIHandler)
}
