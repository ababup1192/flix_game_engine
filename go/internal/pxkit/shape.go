package pxkit

// 形: 符号付き距離（SDF。負 = 内側）を JSON の木から組む。
//
//	{"disk": [cx, cy, r]}              {"ellipse": [cx, cy, rx, ry]}
//	{"rbox": [cx, cy, hw, hh, r]}      {"capsule": [ax, ay, bx, by, r]}
//	{"poly": [[x, y], ...]}            {"star": [cx, cy, rOut, rIn], "n": 5}
//	{"union": [形, ...]}               {"inter": [形, 形]}
//	{"smoothUnion": [形, 形], "k": 2}  {"rounded": 0.8, "of": 形}
//	{"rotate": 周（1 周 = 1.0）, "about": [x, y], "of": 形}   {"ref": "名前"}（spec の shapes から引く）
//	{"taper": [ax, ay, bx, by, r0, r1]}  先細りの棒（塗りの判定専用）
//
// 語は ShaderDoc（docs/shader-doc.md）にそろえる: 丸は disk・回転は turns。
//
// 画素 (x, y) の中心 (x+0.5, y+0.5) で距離が 0 以下なら塗る。

import (
	"fmt"
	"math"
	"math/big"
)

// SDF は点から形の縁までの符号付き距離。
type SDF func(x, y float64) float64

// hypot は正しく丸めた √(a²+b²)。
// WhyNot: math.Hypot は最後の 1 桁が Python の math.hypot（3.10 以降は正しく丸める）とずれ、
// 縁にちょうど乗った画素の内外が入れ替わって、移した台本の出力がバイトで一致しなくなる。
func hypot(a, b float64) float64 {
	a, b = math.Abs(a), math.Abs(b)
	if a == 0 {
		return b
	}
	if b == 0 {
		return a
	}
	// 速い道: a²+b² を誤差なしの 2 項（s + e）で持ち、h = √s からのずれ c を出す。
	// 正しく丸めた答えは h かその隣。c が丸めの境目（ulp の半分）から十分遠い時だけここで決め、
	// 境目にほぼ乗った時だけ遅い道（160 bit）で確かめる。
	// float64(…) で丸めを明示する: Go は arm64 で a*a + b*b を 1 回の FMA にまとめてよく、まとめられると
	// 「丸めた 2 つの積の和」という前提が崩れる（Python は融合しない）。
	p, q := float64(a*a), float64(b*b)
	s, e := twoSum(p, q)
	e += math.FMA(a, a, -p) + math.FMA(b, b, -q)
	h := math.Sqrt(s)
	u := math.Nextafter(h, math.Inf(1)) - h
	c := (math.FMA(-h, h, s) + e) / (2 * h)
	switch {
	case math.Abs(c) < 0.4999*u:
		return h
	case c > 0.5001*u && c < 1.4999*u:
		return h + u
	case c < -0.5001*u && c > -1.4999*u && math.Nextafter(h, 0) == h-u:
		return h - u // 下の隣（h が 2 の累乗で下の ulp が半分の時は遅い道へ）
	}
	x := new(big.Float).SetPrec(160).SetFloat64(a)
	y := new(big.Float).SetPrec(160).SetFloat64(b)
	x.Mul(x, x)
	y.Mul(y, y)
	x.Add(x, y)
	x.Sqrt(x)
	f, _ := x.Float64()
	return f
}

func twoSum(a, b float64) (float64, float64) {
	s := float64(a + b)
	bb := float64(s - a)
	return s, float64(a-float64(s-bb)) + float64(b-bb)
}

func nums(v any) []float64 {
	arr, _ := v.([]any)
	out := make([]float64, len(arr))
	for i, e := range arr {
		out[i] = num(e, 0)
	}
	return out
}

func points(v any) [][2]float64 {
	arr, _ := v.([]any)
	out := make([][2]float64, 0, len(arr))
	for _, e := range arr {
		p := nums(e)
		if len(p) == 2 {
			out = append(out, [2]float64{p[0], p[1]})
		}
	}
	return out
}

func polySDF(pts [][2]float64) SDF {
	return func(x, y float64) float64 {
		d := math.Inf(1)
		inside := false
		n := len(pts)
		for i := 0; i < n; i++ {
			ax, ay := pts[i][0], pts[i][1]
			bx, by := pts[(i+1)%n][0], pts[(i+1)%n][1]
			ex, ey := bx-ax, by-ay
			wx, wy := x-ax, y-ay
			t := math.Max(0, math.Min(1, dot(wx, wy, ex, ey)/dot(ex, ey, ex, ey)))
			d = math.Min(d, hypot(wx-ex*t, wy-ey*t))
			if (ay > y) != (by > y) {
				xi := ax + float64((y-ay)*ex)/ey
				if x < xi {
					inside = !inside
				}
			}
		}
		if inside {
			return -d
		}
		return d
	}
}

// ShapeOf は JSON の形を SDF にする。refs は spec の shapes（名前つきの形）。
func ShapeOf(v any, refs map[string]any) (SDF, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("形はオブジェクトで書く: %v", v)
	}
	switch {
	case m["ref"] != nil:
		name, _ := m["ref"].(string)
		body, ok := refs[name]
		if !ok {
			return nil, fmt.Errorf("shapes に %q が無い", name)
		}
		return ShapeOf(body, refs)
	case m["disk"] != nil:
		p := nums(m["disk"])
		return func(x, y float64) float64 { return hypot(x-p[0], y-p[1]) - p[2] }, nil
	case m["ellipse"] != nil:
		p := nums(m["ellipse"])
		return func(x, y float64) float64 {
			return (hypot((x-p[0])/p[2], (y-p[1])/p[3]) - 1.0) * math.Min(p[2], p[3])
		}, nil
	case m["rbox"] != nil:
		p := nums(m["rbox"])
		return func(x, y float64) float64 {
			qx := math.Abs(x-p[0]) - p[2] + p[4]
			qy := math.Abs(y-p[1]) - p[3] + p[4]
			return hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - p[4]
		}, nil
	case m["capsule"] != nil:
		p := nums(m["capsule"])
		return func(x, y float64) float64 {
			ex, ey := p[2]-p[0], p[3]-p[1]
			wx, wy := x-p[0], y-p[1]
			t := math.Max(0, math.Min(1, dot(wx, wy, ex, ey)/dot(ex, ey, ex, ey)))
			return hypot(wx-ex*t, wy-ey*t) - p[4]
		}, nil
	case m["taper"] != nil:
		// 先細りの棒（両端が丸い）。r0 → r1 へ太さが変わる。返すのは「距離² − 半径²」で、内外の符号だけが正しい
		// （塗る・塊を作るには足りるが、smoothUnion・rounded には使えない）。
		p := nums(m["taper"])
		return func(x, y float64) float64 {
			vx, vy := p[2]-p[0], p[3]-p[1]
			ll := vx*vx + vy*vy
			if ll == 0 {
				ll = 1
			}
			t := math.Max(0, math.Min(1, ((x-p[0])*vx+(y-p[1])*vy)/ll))
			qx, qy := p[0]+vx*t, p[1]+vy*t
			r := p[4] + (p[5]-p[4])*t
			return (x-qx)*(x-qx) + (y-qy)*(y-qy) - r*r
		}, nil
	case m["poly"] != nil:
		return polySDF(points(m["poly"])), nil
	case m["star"] != nil:
		p := nums(m["star"])
		n := int(num(m["n"], 5))
		rot := num(m["rot"], -math.Pi/2)
		var pts [][2]float64
		for i := 0; i < n*2; i++ {
			r := p[2]
			if i%2 == 1 {
				r = p[3]
			}
			a := rot + float64(i)*math.Pi/float64(n)
			pts = append(pts, [2]float64{p[0] + float64(r*math.Cos(a)), p[1] + float64(r*math.Sin(a))})
		}
		return polySDF(pts), nil
	case m["union"] != nil:
		fs, err := shapeList(m["union"], refs)
		if err != nil {
			return nil, err
		}
		return func(x, y float64) float64 {
			d := math.Inf(1)
			for _, f := range fs {
				d = math.Min(d, f(x, y))
			}
			return d
		}, nil
	case m["inter"] != nil:
		fs, err := shapeList(m["inter"], refs)
		if err != nil {
			return nil, err
		}
		return func(x, y float64) float64 {
			d := math.Inf(-1)
			for _, f := range fs {
				d = math.Max(d, f(x, y))
			}
			return d
		}, nil
	case m["smoothUnion"] != nil:
		fs, err := shapeList(m["smoothUnion"], refs)
		if err != nil || len(fs) != 2 {
			return nil, fmt.Errorf("smoothUnion は形 2 つ: %v", err)
		}
		k := num(m["k"], 1)
		return func(x, y float64) float64 {
			da, db := fs[0](x, y), fs[1](x, y)
			h := math.Max(k-math.Abs(da-db), 0) / k
			return math.Min(da, db) - float64(float64(h*h)*k)*0.25
		}, nil
	case m["rounded"] != nil:
		f, err := ShapeOf(m["of"], refs)
		if err != nil {
			return nil, err
		}
		r := num(m["rounded"], 0)
		return func(x, y float64) float64 { return f(x, y) - r }, nil
	case m["rotate"] != nil:
		f, err := ShapeOf(m["of"], refs)
		if err != nil {
			return nil, err
		}
		about := nums(m["about"])
		// 形を turns だけ回す = 点を逆向きに回して元の形に問い合わせる
		a := -num(m["rotate"], 0) * 2 * math.Pi
		ca, sa := math.Cos(a), math.Sin(a)
		return func(x, y float64) float64 {
			dx, dy := float64(x-about[0]), float64(y-about[1])
			return f(about[0]+float64(dx*ca)-float64(dy*sa), about[1]+float64(dx*sa)+float64(dy*ca))
		}, nil
	}
	return nil, fmt.Errorf("知らない形: %v", keysOf(m))
}

func shapeList(v any, refs map[string]any) ([]SDF, error) {
	arr, _ := v.([]any)
	out := make([]SDF, 0, len(arr))
	for _, e := range arr {
		f, err := ShapeOf(e, refs)
		if err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, nil
}

// dot は a·b。float64(…) で 1 つずつ丸め、Go が積と和を FMA にまとめるのを止める
// （Python は融合しないので、まとめられると画素の内外が入れ替わることがある）。
func dot(ax, ay, bx, by float64) float64 { return float64(ax*bx) + float64(ay*by) }
