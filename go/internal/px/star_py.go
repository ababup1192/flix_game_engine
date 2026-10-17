package px

// 台本（.px.star）を Python の台本から写す間だけ要る、CPython と同じ結果を出す部品。
// 乱数（random.Random）・round・float の repr・json.dump の並び。
// WhyNot: 写した台本の書き出しを Python の書き出しとバイトで比べて、写し損じが無いと言うため。
// 台本を op へ書き直したら（第 4 段の 4）px.rng と style="python" ごと消す。

import (
	"github.com/ababup1192/flix_game_engine/go/internal/starbox"
	"math"
	"math/big"
	"strconv"
)

// pyRandom は CPython の random.Random（MT19937）と同じ列を出す。
type pyRandom struct {
	mt  [624]uint32
	mti int
}

func (r *pyRandom) initGenrand(s uint32) {
	r.mt[0] = s
	for i := 1; i < 624; i++ {
		r.mt[i] = 1812433253*(r.mt[i-1]^(r.mt[i-1]>>30)) + uint32(i)
	}
	r.mti = 624
}

// newPyRandom は random.Random(seed)（seed は整数）と同じ状態を作る（CPython の init_by_array）。
func newPyRandom(seed *big.Int) *pyRandom {
	n := new(big.Int).Abs(seed)
	var key []uint32
	words := new(big.Int).Set(n)
	mask := big.NewInt(0xffffffff)
	for words.Sign() > 0 {
		key = append(key, uint32(new(big.Int).And(words, mask).Uint64()))
		words.Rsh(words, 32)
	}
	if len(key) == 0 {
		key = []uint32{0}
	}
	r := &pyRandom{}
	r.initGenrand(19650218)
	i, j := 1, 0
	k := max(624, len(key))
	for ; k > 0; k-- {
		r.mt[i] = (r.mt[i] ^ ((r.mt[i-1] ^ (r.mt[i-1] >> 30)) * 1664525)) + key[j] + uint32(j)
		i++
		j++
		if i >= 624 {
			r.mt[0] = r.mt[623]
			i = 1
		}
		if j >= len(key) {
			j = 0
		}
	}
	for k = 623; k > 0; k-- {
		r.mt[i] = (r.mt[i] ^ ((r.mt[i-1] ^ (r.mt[i-1] >> 30)) * 1566083941)) - uint32(i)
		i++
		if i >= 624 {
			r.mt[0] = r.mt[623]
			i = 1
		}
	}
	r.mt[0] = 0x80000000
	return r
}

func (r *pyRandom) uint32() uint32 {
	const upper, lower = 0x80000000, 0x7fffffff
	mag := [2]uint32{0, 0x9908b0df}
	if r.mti >= 624 {
		kk := 0
		for ; kk < 624-397; kk++ {
			y := (r.mt[kk] & upper) | (r.mt[kk+1] & lower)
			r.mt[kk] = r.mt[kk+397] ^ (y >> 1) ^ mag[y&1]
		}
		for ; kk < 623; kk++ {
			y := (r.mt[kk] & upper) | (r.mt[kk+1] & lower)
			r.mt[kk] = r.mt[kk+(397-624)] ^ (y >> 1) ^ mag[y&1]
		}
		y := (r.mt[623] & upper) | (r.mt[0] & lower)
		r.mt[623] = r.mt[396] ^ (y >> 1) ^ mag[y&1]
		r.mti = 0
	}
	y := r.mt[r.mti]
	r.mti++
	y ^= y >> 11
	y ^= (y << 7) & 0x9d2c5680
	y ^= (y << 15) & 0xefc60000
	y ^= y >> 18
	return y
}

// random は 0 以上 1 未満（53 bit）。
func (r *pyRandom) random() float64 {
	a, b := r.uint32()>>5, r.uint32()>>6
	return (float64(float64(a)*67108864.0) + float64(b)) * (1.0 / 9007199254740992.0)
}

// below は 0 以上 n 未満の整数（CPython の _randbelow_with_getrandbits。n は 2^32 まで）。
func (r *pyRandom) below(n int64) int64 {
	k := 0
	for v := n; v > 0; v >>= 1 {
		k++
	}
	for {
		v := int64(r.uint32() >> (32 - k))
		if v < n {
			return v
		}
	}
}

// pyRoundHalfEven は Python の round(x)（偶数丸め）。
func pyRoundHalfEven(x float64) float64 { return math.RoundToEven(x) }

// pyRoundDigits は Python の round(x, nd)（10 進で正しく丸め、ちょうど半分は偶数へ）。
func pyRoundDigits(x float64, nd int) float64 {
	if math.IsInf(x, 0) || math.IsNaN(x) || nd > 300 {
		return x
	}
	s := strconv.FormatFloat(x, 'f', nd, 64) // 'f' は 2 進の値を正確に 10 進にしてから偶数丸めする
	v, _ := strconv.ParseFloat(s, 64)
	if v == 0 {
		return math.Copysign(0, x)
	}
	return v
}

// pyFloatRepr は Python の repr(float)（starbox の物）。
var pyFloatRepr = starbox.PyFloatRepr
