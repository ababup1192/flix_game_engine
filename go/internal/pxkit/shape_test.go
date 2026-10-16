package pxkit

import (
	"math/big"
	"math/rand"
	"testing"
)

// 速い道の hypot が、160 bit で計算して丸めた値と一致する（Python の math.hypot と同じ答え）。
func TestHypotMatchesCorrectlyRounded(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for i := 0; i < 200000; i++ {
		a, b := rng.Float64()*64-32, rng.Float64()*64-32
		if i%4 == 0 { // 格子の座標に近い値（画素の中心 - 形の中心）
			a, b = float64(rng.Intn(64))+0.5-16.3, float64(rng.Intn(64))+0.5-7.7
		}
		x := new(big.Float).SetPrec(160).SetFloat64(a)
		y := new(big.Float).SetPrec(160).SetFloat64(b)
		x.Mul(x, x)
		y.Mul(y, y)
		want, _ := x.Add(x, y).Sqrt(x).Float64()
		if got := hypot(a, b); got != want {
			t.Fatalf("hypot(%v, %v) = %v, want %v", a, b, got, want)
		}
	}
}
