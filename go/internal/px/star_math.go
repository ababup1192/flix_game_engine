package px

// 台本の math: 結果を正しく丸めた値（真の値に一番近い float64）で返す。
// sin・cos・tan・exp・log・pow・atan2 は 128 bit の big.Float で計算してから 1 回だけ丸める（hypot は shape.go の物）。
// WhyNot: Go の math（Starlark の lib/math）は 1 ulp ずれることがあり、arm64 では a*b+c が FMA に
// まとまって amd64 と結果が変わる。正しく丸めた値なら OS・CPU・言語（CPython と libm）に依らず 1 つに決まる。

import (
	"fmt"
	"math"
	"math/big"

	"go.starlark.net/starlark"
	"go.starlark.net/starlarkstruct"
)

const mathPrec = 128

// degToRad・radToDeg は CPython と同じく float64 の π から 1 回の割り算で作る。
var piF64 = math.Pi
var degToRad, radToDeg = piF64 / 180, 180 / piF64

// piBig・ln2Big は 200 桁から作った定数（引数を小さくするときに使う）。
var (
	piBig  = mustBig("3.14159265358979323846264338327950288419716939937510582097494459230781640628620899862803482534211706798214808651328230664709384460955058223172535940812848111745028410270193852110555964462294895493038196")
	ln2Big = mustBig("0.69314718055994530941723212145817656807550013436025525412068000949339362196969471560586332699641868754200148102057068573368552023575813055703267075163507596193072757082837143519030703862389167347112335")
)

func mustBig(s string) *big.Float {
	f, _, err := big.ParseFloat(s, 10, 640, big.ToNearestEven)
	if err != nil {
		panic(err)
	}
	return f
}

// recip[k] は 1/k（256 bit）。級数の割り算を掛け算にする（割り算は掛け算の数倍重い）。
var recip = func() []*big.Float {
	r := make([]*big.Float, 4096)
	for k := 1; k < len(r); k++ {
		r[k] = newF(256).Quo(newF(256).SetInt64(1), newF(256).SetInt64(int64(k)))
	}
	return r
}()

// mulRecip は z に 1/k を掛ける（k が表の外なら割る）。
func mulRecip(z *big.Float, k int64) *big.Float {
	if k > 0 && k < int64(len(recip)) {
		return z.Mul(z, recip[k])
	}
	return z.Quo(z, newF(z.Prec()).SetInt64(k))
}

func newF(p uint) *big.Float { return new(big.Float).SetPrec(p) }

func bf(x float64, p uint) *big.Float { return newF(p).SetFloat64(x) }

func bfInt(n int64, p uint) *big.Float { return newF(p).SetInt64(n) }

// tiny は |z| < 2^-p か（級数を止める所。Abs と Cmp の作り直しを避ける）。
func tiny(z *big.Float, p uint) bool { return z.Sign() == 0 || z.MantExp(nil) < -int(p) }

func toF64(z *big.Float) float64 {
	f, _ := z.Float64()
	return f
}

// sinCosBig は sin(x)・cos(x) を p bit で返す。
func sinCosBig(x float64, p uint) (*big.Float, *big.Float) {
	wp := p + 64
	X := bf(x, wp)
	half := newF(wp).Quo(newF(wp).Set(piBig), bfInt(2, wp))
	q := newF(wp).Quo(X, half)
	// k = q を一番近い整数へ
	qf, _ := q.Float64()
	k := math.RoundToEven(qf)
	r := newF(wp).Sub(X, newF(wp).Mul(bf(k, wp), half)) // |r| ≤ π/4（くらい）
	s, c := taylorSinCos(r, wp)
	switch int64(math.Mod(math.Mod(k, 4)+4, 4)) {
	case 0:
		return s, c
	case 1:
		return c, s.Neg(s)
	case 2:
		return s.Neg(s), c.Neg(c)
	default:
		return c.Neg(c), s
	}
}

func taylorSinCos(r *big.Float, p uint) (*big.Float, *big.Float) {
	r2 := newF(p).Mul(r, r)
	r2.Neg(r2)
	s := newF(p).Set(r)
	term := newF(p).Set(r)
	for n := int64(1); !tiny(term, p); n++ {
		term.Mul(term, r2)
		mulRecip(mulRecip(term, 2*n), 2*n+1)
		s.Add(s, term)
	}
	c := bfInt(1, p)
	term = bfInt(1, p)
	for n := int64(1); !tiny(term, p); n++ {
		term.Mul(term, r2)
		mulRecip(mulRecip(term, 2*n-1), 2*n)
		c.Add(c, term)
	}
	return s, c
}

// expBig は e^x を p bit で返す（x は big）。
func expBig(X *big.Float, p uint) *big.Float {
	wp := p + 32
	xf, _ := X.Float64()
	k := math.RoundToEven(xf / math.Ln2)
	r := newF(wp).Sub(X, newF(wp).Mul(bf(k, wp), ln2Big))
	// さらに 2^8 で割ってから 8 回 2 乗する
	r.SetMantExp(r, -8)
	sum := bfInt(1, wp)
	term := bfInt(1, wp)
	for n := int64(1); !tiny(term, wp); n++ {
		term.Mul(term, r)
		mulRecip(term, n)
		sum.Add(sum, term)
	}
	for i := 0; i < 8; i++ {
		sum.Mul(sum, sum)
	}
	return sum.SetMantExp(sum, int(k))
}

// logBig は ln(x)（x > 0）を p bit で返す。
func logBig(X *big.Float, p uint) *big.Float {
	wp := p + 32
	m := newF(wp)
	e := X.MantExp(m) // X = m × 2^e、m は [0.5, 1)
	if m.Cmp(big.NewFloat(math.Sqrt2/2)) < 0 {
		m.SetMantExp(m, 1)
		e--
	}
	// ln(m) = 2 atanh(z)、z = (m-1)/(m+1)
	one := bfInt(1, wp)
	z := newF(wp).Quo(newF(wp).Sub(m, one), newF(wp).Add(m, one))
	z2 := newF(wp).Mul(z, z)
	sum := newF(wp).Set(z)
	pw := newF(wp).Set(z)
	term := newF(wp).Set(z)
	for n := int64(1); !tiny(term, wp); n++ {
		pw.Mul(pw, z2)
		mulRecip(term.Set(pw), 2*n+1)
		sum.Add(sum, term)
	}
	sum.SetMantExp(sum, 1)
	return sum.Add(sum, newF(wp).Mul(bfInt(int64(e), wp), ln2Big))
}

// atanBig は atan(t)（t ≥ 0）を p bit で返す。
func atanBig(T *big.Float, p uint) *big.Float {
	wp := p + 32
	one := bfInt(1, wp)
	t := newF(wp).Set(T)
	invert := t.Cmp(one) > 0
	if invert {
		t.Quo(one, t)
	}
	// atan(t) = 2 atan(t / (1 + sqrt(1 + t²))) を 2 回（t ≤ tan(π/16)）
	sq := newF(wp)
	for i := 0; i < 2; i++ {
		sq.Mul(t, t)
		sq.Sqrt(sq.Add(sq, one))
		t.Quo(t, sq.Add(sq, one))
	}
	t2 := newF(wp).Mul(t, t)
	sum := newF(wp).Set(t)
	pw, tmp := newF(wp).Set(t), newF(wp)
	term := newF(wp).Set(t)
	t2.Neg(t2)
	for n := int64(1); !tiny(term, wp); n++ {
		tmp.Mul(pw, t2) // 別の入れ物へ掛ける（同じ入れ物だと毎回作り直す）
		pw, tmp = tmp, pw
		term.Mul(pw, recip[2*n+1])
		tmp.Add(sum, term)
		sum, tmp = tmp, sum
	}
	sum.SetMantExp(sum, 2)
	if invert {
		half := newF(wp).Quo(newF(wp).Set(piBig), bfInt(2, wp))
		sum = half.Sub(half, sum)
	}
	return sum
}

func crSin(x float64) float64 {
	if x == 0 || math.IsInf(x, 0) || math.IsNaN(x) {
		return math.Sin(x)
	}
	s, _ := sinCosBig(x, mathPrec)
	return toF64(s)
}

func crCos(x float64) float64 {
	if math.IsInf(x, 0) || math.IsNaN(x) {
		return math.NaN()
	}
	_, c := sinCosBig(x, mathPrec)
	return toF64(c)
}

func crTan(x float64) float64 {
	if x == 0 || math.IsInf(x, 0) || math.IsNaN(x) {
		return math.Tan(x)
	}
	s, c := sinCosBig(x, mathPrec)
	return toF64(s.Quo(s, c))
}

func crExp(x float64) (float64, error) {
	switch {
	case math.IsNaN(x):
		return x, nil
	case x > 709.79:
		return 0, fmt.Errorf("exp: 大きすぎる（%v）", x)
	case x < -745.2:
		return 0, nil
	case x == 0:
		return 1, nil
	}
	return toF64(expBig(bf(x, mathPrec+32), mathPrec)), nil
}

func crLog(x float64) (float64, error) {
	if !(x > 0) {
		return 0, fmt.Errorf("log: 0 より大きい数を渡す（%v）", x)
	}
	if x == 1 {
		return 0, nil
	}
	if math.IsInf(x, 1) {
		return x, nil
	}
	return toF64(logBig(bf(x, mathPrec), mathPrec)), nil
}

func crPow(x, y float64) (float64, error) {
	switch {
	case y == 0 || x == 1:
		return 1, nil
	case math.IsNaN(x) || math.IsNaN(y):
		return math.NaN(), nil
	case x == 0:
		if y < 0 {
			return 0, fmt.Errorf("pow: 0 の負の乗")
		}
		return math.Pow(x, y), nil
	case math.IsInf(x, 0) || math.IsInf(y, 0):
		return math.Pow(x, y), nil
	}
	if y == math.Trunc(y) && math.Abs(y) <= 64 {
		// 整数の乗は正確に掛けてから丸める
		n := int(math.Abs(y))
		z := newF(uint(53*n + 64)).SetFloat64(x)
		acc := newF(uint(53*n + 64)).SetInt64(1)
		for i := 0; i < n; i++ {
			acc.Mul(acc, z)
		}
		if y < 0 {
			acc = newF(mathPrec+32).Quo(bfInt(1, mathPrec+32), acc)
		}
		f, acc2 := acc.Float64()
		if math.IsInf(f, 0) && acc2 != big.Exact {
			return 0, fmt.Errorf("pow: 大きすぎる")
		}
		return f, nil
	}
	if x < 0 {
		return 0, fmt.Errorf("pow: 負の数の整数でない乗（%v ** %v）", x, y)
	}
	const wp = mathPrec + 64
	l := logBig(bf(x, wp), wp)
	l.Mul(l, bf(y, wp))
	lf, _ := l.Float64()
	if lf > 709.79 {
		return 0, fmt.Errorf("pow: 大きすぎる")
	}
	if lf < -745.2 {
		return 0, nil
	}
	return toF64(expBig(l, mathPrec)), nil
}

func crAtan2(y, x float64) float64 {
	if math.IsNaN(x) || math.IsNaN(y) || math.IsInf(x, 0) || math.IsInf(y, 0) || y == 0 || x == 0 {
		return math.Atan2(y, x) // 端の場合は C99 の決まり（Go も同じ表）
	}
	const wp = mathPrec + 32
	t := newF(wp).Quo(bf(math.Abs(y), wp), bf(math.Abs(x), wp))
	a := atanBig(t, wp)
	if x < 0 {
		a = newF(wp).Sub(newF(wp).Set(piBig), a)
	}
	if y < 0 {
		a.Neg(a)
	}
	return toF64(a)
}

func crHypot(x, y float64) float64 {
	if math.IsInf(x, 0) || math.IsInf(y, 0) {
		return math.Inf(1)
	}
	if math.IsNaN(x) || math.IsNaN(y) {
		return math.NaN()
	}
	return hypot(x, y) // shape.go の正しく丸める hypot（速い道つき）
}

// ---------------------------------------------------------------- Starlark の math

func starNum(name string, v starlark.Value) (float64, error) {
	f, ok := starlark.AsFloat(v)
	if !ok {
		return 0, fmt.Errorf("%s: 数を渡す（got %s）", name, v.Type())
	}
	return f, nil
}

func unaryMath(name string, fn func(float64) (float64, error)) *starlark.Builtin {
	return starlark.NewBuiltin(name, func(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
		var x starlark.Value
		if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 1, &x); err != nil {
			return nil, err
		}
		f, err := starNum(b.Name(), x)
		if err != nil {
			return nil, err
		}
		r, err := fn(f)
		if err != nil {
			return nil, err
		}
		return starlark.Float(r), nil
	})
}

func binaryMath(name string, fn func(float64, float64) (float64, error)) *starlark.Builtin {
	return starlark.NewBuiltin(name, func(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
		var x, y starlark.Value
		if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 2, &x, &y); err != nil {
			return nil, err
		}
		fx, err := starNum(b.Name(), x)
		if err != nil {
			return nil, err
		}
		fy, err := starNum(b.Name(), y)
		if err != nil {
			return nil, err
		}
		r, err := fn(fx, fy)
		if err != nil {
			return nil, err
		}
		return starlark.Float(r), nil
	})
}

func roundingMath(name string, fn func(float64) float64) *starlark.Builtin {
	return starlark.NewBuiltin(name, func(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
		var x starlark.Value
		if err := starlark.UnpackPositionalArgs(b.Name(), args, kwargs, 1, &x); err != nil {
			return nil, err
		}
		if i, ok := x.(starlark.Int); ok {
			return i, nil
		}
		f, err := starNum(b.Name(), x)
		if err != nil {
			return nil, err
		}
		return starlark.NumberToInt(starlark.Float(fn(f)))
	})
}

func ok1(fn func(float64) float64) func(float64) (float64, error) {
	return func(x float64) (float64, error) { return fn(x), nil }
}

// memo1・memo2 は 1 回の台本の中で同じ引数の答えを覚える（光の帯は同じ atan2 を角度の数だけ呼ぶ）。
// 答えは引数だけで決まるので、覚えても結果は変わらない。
const memoMax = 1 << 20

func memo1(fn func(float64) (float64, error)) func(float64) (float64, error) {
	m := map[uint64]float64{} // 鍵はビット列（-0 と 0 を分ける）
	return func(x float64) (float64, error) {
		k := math.Float64bits(x)
		if r, ok := m[k]; ok {
			return r, nil
		}
		r, err := fn(x)
		if err == nil && len(m) < memoMax {
			m[k] = r
		}
		return r, err
	}
}

func memo2(fn func(float64, float64) (float64, error)) func(float64, float64) (float64, error) {
	m := map[[2]uint64]float64{}
	return func(x, y float64) (float64, error) {
		k := [2]uint64{math.Float64bits(x), math.Float64bits(y)}
		if r, ok := m[k]; ok {
			return r, nil
		}
		r, err := fn(x, y)
		if err == nil && len(m) < memoMax {
			m[k] = r
		}
		return r, err
	}
}

// newStarMath は台本の math（名前と意味は Python の math に合わせる）。台本 1 本ごとに作る（覚えた答えを持つため）。
func newStarMath() *starlarkstruct.Module {
	return &starlarkstruct.Module{Name: "math", Members: starlark.StringDict{
		"pi":    starlark.Float(math.Pi),
		"e":     starlark.Float(math.E),
		"floor": roundingMath("floor", math.Floor),
		"ceil":  roundingMath("ceil", math.Ceil),
		"sqrt": unaryMath("sqrt", func(x float64) (float64, error) { // IEEE の sqrt は正しく丸める
			if x < 0 {
				return 0, fmt.Errorf("sqrt: 負の数（%v）", x)
			}
			return math.Sqrt(x), nil
		}),
		"fabs":    unaryMath("fabs", ok1(math.Abs)),
		"sin":     unaryMath("sin", memo1(ok1(crSin))),
		"cos":     unaryMath("cos", memo1(ok1(crCos))),
		"tan":     unaryMath("tan", memo1(ok1(crTan))),
		"exp":     unaryMath("exp", memo1(crExp)),
		"log":     unaryMath("log", memo1(crLog)),
		"pow":     binaryMath("pow", memo2(crPow)),
		"atan2":   binaryMath("atan2", memo2(func(y, x float64) (float64, error) { return crAtan2(y, x), nil })),
		"hypot":   binaryMath("hypot", memo2(func(x, y float64) (float64, error) { return crHypot(x, y), nil })),
		"radians": unaryMath("radians", ok1(func(x float64) float64 { return x * degToRad })), // CPython と同じ掛け方
		"degrees": unaryMath("degrees", ok1(func(x float64) float64 { return x * radToDeg })),
	}}
}
