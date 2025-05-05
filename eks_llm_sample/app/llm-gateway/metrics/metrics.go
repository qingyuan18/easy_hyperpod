package metrics

import (
	"log"
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type Metrics struct {
	httpReqs     *prometheus.CounterVec
	sysLoad      *prometheus.GaugeVec
	httpRespTime *prometheus.HistogramVec
}

func SetupMetrics() *Metrics {

	// Create a non-global registry.
	reg := prometheus.NewRegistry()

	// Initialize type 'metrics'
	m := &Metrics{}

	httpReqs := setupHttpReqs(reg)
	sysLoad := setupSysLoad(reg)
	httpRespTime := setupHttpRespTime(reg)

	m.httpReqs = httpReqs
	m.sysLoad = sysLoad
	m.httpRespTime = httpRespTime

	// Expose metrics and custom registry via an HTTP server
	// using the HandleFor function. "/metrics" is the usual endpoint for that.
	http.Handle("/metrics", promhttp.HandlerFor(reg, promhttp.HandlerOpts{Registry: reg}))

	go func() {
		http.ListenAndServe(":8080", nil)
	}()

	log.Println("Listen and serve prometheus on port 8080!")

	return m
}

func setupHttpReqs(reg prometheus.Registerer) *prometheus.CounterVec {
	httpReqs := prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "How many HTTP requests processed, partitioned by route, status code and HTTP method.",
		},
		[]string{"route", "code", "method"},
	)
	reg.MustRegister(httpReqs)

	return httpReqs
}

func UpdateHttpReqs(m *Metrics, route string, code string, method string) {
	m.httpReqs.WithLabelValues(route, code, method).Inc()
}

func setupSysLoad(reg prometheus.Registerer) *prometheus.GaugeVec {
	sysLoad := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "sysload_load",
		Help: "Current system load, partitioned by module.",
	},
		[]string{"module"},
	)
	reg.MustRegister(sysLoad)

	return sysLoad
}

func UpdateSysLoad(m *Metrics, module string, val float64) {
	m.sysLoad.WithLabelValues(module).Set(val)
}

func setupHttpRespTime(reg prometheus.Registerer) *prometheus.HistogramVec {
	buckets := []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5, 10, 50, 100}

	httpRespTime := prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_server_request_duration_seconds",
		Help:    "Histogram of response time for handler in seconds",
		Buckets: buckets,
	}, []string{"route", "method", "status_code"})

	reg.MustRegister(httpRespTime)

	return httpRespTime
}

func UpdateHttpRespTime(m *Metrics, route string, code string, method string, val float64) {
	m.httpRespTime.WithLabelValues(route, code, method).Observe(val)
}
