package utils

import (
	"fmt"
	"math/rand"
	"time"
)

func PrintUtils() {
	fmt.Println("Print utils for test!")
}

func RandFloat(min, max float64) float64 {
	res := min + rand.Float64()*(max-min)
	return res
}

func RandFloats(min, max float64, n int) []float64 {
	res := make([]float64, n)
	for i := range res {
		res[i] = min + rand.Float64()*(max-min)
	}
	return res
}

func RandSleep(seconds int) {
	r := rand.Intn(seconds)
	// time.Sleep(time.Duration(r) * time.Microsecond)
	time.Sleep(time.Duration(r) * time.Second)
}
