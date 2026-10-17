package px

// 形: 符号付き距離（負 = 内側）を JSON の木から組む。形の種類は shapeKinds の登録表だけに書き、
// 読み込みの検査・docs/pxsrc.schema.json・docs/px-ops.md はそこから作る。
// 画素 (x, y) の中心 (x+0.5, y+0.5) で距離が 0 以下なら塗る。語は ShaderDoc（docs/shader-doc.md）にそろえる。
//
// 積はどれも float64(…) で包む: Go は arm64 で a*b + c を 1 回の FMA にまとめてよく、まとめられると
// 移す元（Python）と丸めが変わって、縁にちょうど乗った画素の内外が入れ替わる。

import (
	"fmt"
	"math"
	"math/big"
	"sort"
)

// sdf は点から形の縁までの符号付き距離。
type sdf func(x, y float64) float64

// shapeIn は検査を通った形の引数。
type shapeIn struct {
	nums []float64    // 名前の鍵の数の並び（tNums）か数 1 つ（tNumber）
	vecs [][2]float64 // 点の並び（tVecs）
	rows []string     // 文字の行（tRows）
	kids []sdf        // 子の形（tShapes・of）
	opt  map[string]float64
	pair map[string][2]float64
	at   [2]int
	ref  string
}

// shapeKind は形の種類 1 つ。
type shapeKind struct {
	Name    string
	Summary string
	Main    param   // 名前の鍵の値
	Extra   []param // ほかに書ける鍵
	Make    func(in shapeIn) sdf
}

var shapeKinds = map[string]*shapeKind{}

func registerShape(k *shapeKind) { shapeKinds[k.Name] = k }

func allShapes() []*shapeKind {
	out := make([]*shapeKind, 0, len(shapeKinds))
	for _, k := range shapeKinds {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func init() {
	pOf := param{Name: "of", Type: tShape, Required: true, Summary: "元の形"}
	registerShape(&shapeKind{Name: "disk", Summary: "丸",
		Main: param{Type: tNums, Len: 3, Summary: "[cx, cy, r]"},
		Make: func(in shapeIn) sdf {
			p := in.nums
			return func(x, y float64) float64 { return hypot(x-p[0], y-p[1]) - p[2] }
		}})
	registerShape(&shapeKind{Name: "ellipse", Summary: "楕円",
		Main: param{Type: tNums, Len: 4, Summary: "[cx, cy, rx, ry]"},
		Make: func(in shapeIn) sdf {
			p := in.nums
			return func(x, y float64) float64 {
				return float64((hypot((x-p[0])/p[2], (y-p[1])/p[3]) - 1.0) * math.Min(p[2], p[3]))
			}
		}})
	registerShape(&shapeKind{Name: "rect", Summary: "画素に揃った矩形（x..x+w-1・y..y+h-1 の画素）",
		Main: param{Type: tNums, Len: 4, Summary: "[x, y, w, h]"},
		Make: func(in shapeIn) sdf {
			p := in.nums
			cx, cy, hw, hh := p[0]+p[2]/2, p[1]+p[3]/2, p[2]/2, p[3]/2
			return func(x, y float64) float64 {
				qx, qy := math.Abs(x-cx)-hw, math.Abs(y-cy)-hh
				return hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0)
			}
		}})
	registerShape(&shapeKind{Name: "rbox", Summary: "角丸の矩形（中心と半分の幅）",
		Main: param{Type: tNums, Len: 5, Summary: "[cx, cy, hw, hh, r]"},
		Make: func(in shapeIn) sdf {
			p := in.nums
			return func(x, y float64) float64 {
				qx := math.Abs(x-p[0]) - p[2] + p[4]
				qy := math.Abs(y-p[1]) - p[3] + p[4]
				return hypot(math.Max(qx, 0), math.Max(qy, 0)) + math.Min(math.Max(qx, qy), 0) - p[4]
			}
		}})
	registerShape(&shapeKind{Name: "capsule", Summary: "両端の丸い棒",
		Main: param{Type: tNums, Len: 5, Summary: "[ax, ay, bx, by, r]"},
		Make: func(in shapeIn) sdf {
			p := in.nums
			seg := segDist(p[0], p[1], p[2], p[3])
			return func(x, y float64) float64 { return seg(x, y) - p[4] }
		}})
	registerShape(&shapeKind{Name: "taper", Summary: "先細りの棒（塗りの判定専用。smoothUnion・rounded には使えない）",
		Main: param{Type: tNums, Len: 6, Summary: "[ax, ay, bx, by, r0, r1]"},
		Make: func(in shapeIn) sdf {
			p := in.nums
			// 返すのは「距離² − 半径²」で、内外の符号だけが正しい
			return func(x, y float64) float64 {
				vx, vy := p[2]-p[0], p[3]-p[1]
				ll := float64(vx*vx) + float64(vy*vy)
				if ll == 0 {
					ll = 1
				}
				t := math.Max(0, math.Min(1, (float64((x-p[0])*vx)+float64((y-p[1])*vy))/ll))
				qx, qy := p[0]+float64(vx*t), p[1]+float64(vy*t)
				r := p[4] + float64((p[5]-p[4])*t)
				return float64((x-qx)*(x-qx)) + float64((y-qy)*(y-qy)) - float64(r*r)
			}
		}})
	registerShape(&shapeKind{Name: "poly", Summary: "多角形（点を順に結ぶ）",
		Main: param{Type: tVecs, Min: 3, Summary: "[[x, y], ...]（3 点以上）"},
		Make: func(in shapeIn) sdf { return polySDF(in.vecs) }})
	registerShape(&shapeKind{Name: "path", Summary: "折れ線に太さを付けた物（角と端は丸い）",
		Main:  param{Type: tVecs, Min: 2, Summary: "[[x, y], ...]（2 点以上）"},
		Extra: []param{{Name: "width", Type: tNumber, Default: 1.0, Summary: "太さ", Lo: bound(0.1), Hi: bound(64)}},
		Make: func(in shapeIn) sdf {
			var segs []func(x, y float64) float64
			for i := 0; i+1 < len(in.vecs); i++ {
				a, b := in.vecs[i], in.vecs[i+1]
				segs = append(segs, segDist(a[0], a[1], b[0], b[1]))
			}
			half := in.opt["width"] / 2
			return func(x, y float64) float64 {
				d := math.Inf(1)
				for _, s := range segs {
					d = math.Min(d, s(x, y))
				}
				return d - half
			}
		}})
	registerShape(&shapeKind{Name: "star", Summary: "星（外と内の半径を交互に結ぶ多角形）",
		Main: param{Type: tNums, Len: 4, Summary: "[cx, cy, rOut, rIn]"},
		Extra: []param{
			{Name: "n", Type: tInt, Default: 5.0, Summary: "角の数", Lo: bound(3), Hi: bound(64)},
			{Name: "rot", Type: tNumber, Default: -math.Pi / 2, Summary: "最初の角の向き（ラジアン。既定は真上）"},
		},
		Make: func(in shapeIn) sdf {
			p, n, rot := in.nums, int(in.opt["n"]), in.opt["rot"]
			var pts [][2]float64
			for i := 0; i < n*2; i++ {
				r := p[2]
				if i%2 == 1 {
					r = p[3]
				}
				a := rot + float64(float64(i)*math.Pi)/float64(n)
				pts = append(pts, [2]float64{p[0] + float64(r*math.Cos(a)), p[1] + float64(r*math.Sin(a))})
			}
			return polySDF(pts)
		}})
	registerShape(&shapeKind{Name: "mask", Summary: "rows で画素を直に指す（'.' と ' ' が外）",
		Main:  param{Type: tRows, Min: 1, Summary: "文字の行"},
		Extra: []param{{Name: "at", Type: tPoint, Default: []any{0.0, 0.0}, Summary: "左上の位置 [x, y]"}},
		Make: func(in shapeIn) sdf {
			rows := make([][]rune, len(in.rows))
			for i, r := range in.rows {
				rows[i] = []rune(r)
			}
			ax, ay := float64(in.at[0]), float64(in.at[1])
			return func(x, y float64) float64 {
				ix, iy := int(math.Floor(x-ax)), int(math.Floor(y-ay))
				if iy >= 0 && iy < len(rows) && ix >= 0 && ix < len(rows[iy]) && rows[iy][ix] != '.' && rows[iy][ix] != ' ' {
					return -1
				}
				return 1
			}
		}})
	registerShape(&shapeKind{Name: "union", Summary: "和（どれかの中）",
		Main: param{Type: tShapes, Min: 2, Summary: "[形, 形, ...]（2 つ以上）"},
		Make: func(in shapeIn) sdf {
			return func(x, y float64) float64 {
				d := math.Inf(1)
				for _, f := range in.kids {
					d = math.Min(d, f(x, y))
				}
				return d
			}
		}})
	registerShape(&shapeKind{Name: "inter", Summary: "積（全部の中）",
		Main: param{Type: tShapes, Min: 2, Summary: "[形, 形, ...]（2 つ以上）"},
		Make: func(in shapeIn) sdf {
			return func(x, y float64) float64 {
				d := math.Inf(-1)
				for _, f := range in.kids {
					d = math.Max(d, f(x, y))
				}
				return d
			}
		}})
	registerShape(&shapeKind{Name: "smoothUnion", Summary: "なめらかにつないだ和",
		Main:  param{Type: tShapes, Min: 2, Max: 2, Summary: "[形, 形]"},
		Extra: []param{{Name: "k", Type: tNumber, Default: 1.0, Summary: "つなぎの幅（0 より大きい）"}},
		Make: func(in shapeIn) sdf {
			k, a, b := in.opt["k"], in.kids[0], in.kids[1]
			return func(x, y float64) float64 {
				da, db := a(x, y), b(x, y)
				h := math.Max(k-math.Abs(da-db), 0) / k
				return math.Min(da, db) - float64(float64(h*h)*k)*0.25
			}
		}})
	registerShape(&shapeKind{Name: "rounded", Summary: "形を太らせて角を丸める",
		Main:  param{Type: tNumber, Summary: "太らせる量"},
		Extra: []param{pOf},
		Make: func(in shapeIn) sdf {
			f, r := in.kids[0], in.nums[0]
			return func(x, y float64) float64 { return f(x, y) - r }
		}})
	registerShape(&shapeKind{Name: "rotate", Summary: "形を回す（1 周 = 1.0）",
		Main: param{Type: tNumber, Summary: "回す量（周。正は時計回り）"},
		Extra: []param{
			{Name: "about", Type: tPair, Required: true, Summary: "回す中心 [x, y]"},
			pOf,
		},
		Make: func(in shapeIn) sdf {
			f, about := in.kids[0], in.pair["about"]
			// 形を turns だけ回す = 点を逆向きに回して元の形に問い合わせる
			a := float64(-in.nums[0]*2) * math.Pi
			ca, sa := math.Cos(a), math.Sin(a)
			return func(x, y float64) float64 {
				dx, dy := x-about[0], y-about[1]
				return f(about[0]+float64(dx*ca)-float64(dy*sa), about[1]+float64(dx*sa)+float64(dy*ca))
			}
		}})
	registerShape(&shapeKind{Name: "ref", Summary: "shapes の名前つきの形を引く",
		Main: param{Type: tString, Summary: "shapes の名前"}})
}

// maxShapeDepth は ref の輪を止める深さ。
const maxShapeDepth = 32

// shapeOf は JSON の形（Plain の値）を検査して距離の関数にする。where は誤りに付ける場所。
func shapeOf(v any, refs map[string]any, where string) (sdf, error) {
	return compileShape(v, refs, where, 0)
}

func compileShape(v any, refs map[string]any, where string, depth int) (sdf, error) {
	if depth > maxShapeDepth {
		return nil, fmt.Errorf("%s: 形の入れ子が深すぎる（ref が輪になっていないか）", where)
	}
	if name, isStr := v.(string); isStr {
		v = map[string]any{"ref": name} // "shield" は {"ref": "shield"} の短い書き方
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("%s: 形はオブジェクトか shapes の名前で書く（{\"disk\": [cx, cy, r]}・\"shield\" など）", where)
	}
	var kind *shapeKind
	for _, k := range keysOf(m) {
		if sk := shapeKinds[k]; sk != nil {
			if kind != nil {
				return nil, fmt.Errorf("%s: 形の種類が 2 つある（%s と %s）", where, kind.Name, k)
			}
			kind = sk
		}
	}
	if kind == nil {
		return nil, fmt.Errorf("%s: 知らない形 %v（書ける形: %s）", where, keysOf(m), shapeNames())
	}
	where = where + "." + kind.Name
	extra := map[string]bool{}
	for _, p := range kind.Extra {
		extra[p.Name] = true
	}
	for _, k := range keysOf(m) {
		if k != kind.Name && !extra[k] {
			return nil, fmt.Errorf("%s: 知らない鍵 %q（%s に書けるのは %s）", where, k, kind.Name, extraNames(kind))
		}
	}
	in := shapeIn{opt: map[string]float64{}, pair: map[string][2]float64{}}
	if err := checkType(kind.Main, m[kind.Name]); err != nil {
		return nil, fmt.Errorf("%s: %s で書く（%v）", where, kind.Main.Summary, err)
	}
	switch kind.Main.Type {
	case tNums:
		in.nums = nums(m[kind.Name])
	case tNumber:
		in.nums = []float64{m[kind.Name].(float64)}
	case tVecs:
		in.vecs = vecs(m[kind.Name])
	case tRows:
		in.rows = strs(m[kind.Name])
	case tString:
		in.ref = m[kind.Name].(string)
	case tShapes:
		for i, e := range m[kind.Name].([]any) {
			f, err := compileShape(e, refs, fmt.Sprintf("%s[%d]", where, i), depth+1)
			if err != nil {
				return nil, err
			}
			in.kids = append(in.kids, f)
		}
	}
	for _, p := range kind.Extra {
		val, has := m[p.Name]
		if !has {
			if p.Required {
				return nil, fmt.Errorf("%s: %s が無い（%s）", where, p.Name, p.Summary)
			}
			val = p.Default
		} else if err := checkType(p, val); err != nil {
			return nil, fmt.Errorf("%s.%s: %v", where, p.Name, err)
		}
		switch p.Type {
		case tShape:
			f, err := compileShape(val, refs, where+"."+p.Name, depth+1)
			if err != nil {
				return nil, err
			}
			in.kids = append(in.kids, f)
		case tNumber, tInt:
			in.opt[p.Name] = val.(float64)
		case tPair:
			p2 := nums(val)
			in.pair[p.Name] = [2]float64{p2[0], p2[1]}
		case tPoint:
			p2 := nums(val)
			in.at = [2]int{int(p2[0]), int(p2[1])}
		}
	}
	switch kind.Name {
	case "ref":
		body, ok := refs[in.ref]
		if !ok {
			return nil, fmt.Errorf("%s: shapes に %q が無い", where, in.ref)
		}
		return compileShape(body, refs, "shapes."+in.ref, depth+1)
	case "smoothUnion":
		if in.opt["k"] <= 0 {
			return nil, fmt.Errorf("%s.k: 0 より大きい数で書く", where)
		}
	case "ellipse":
		if in.nums[2] == 0 || in.nums[3] == 0 {
			return nil, fmt.Errorf("%s: rx と ry は 0 にしない", where)
		}
	case "star":
		if in.opt["n"] < 2 {
			return nil, fmt.Errorf("%s.n: 2 以上で書く", where)
		}
	}
	return kind.Make(in), nil
}

func shapeNames() string {
	var names []string
	for _, k := range allShapes() {
		names = append(names, k.Name)
	}
	return joinNames(names)
}

func extraNames(k *shapeKind) string {
	names := []string{k.Name}
	for _, p := range k.Extra {
		names = append(names, p.Name)
	}
	return joinNames(names)
}

// segDist は線分 (ax, ay)-(bx, by) までの距離。
func segDist(ax, ay, bx, by float64) func(x, y float64) float64 {
	ex, ey := bx-ax, by-ay
	ll := dot(ex, ey, ex, ey)
	return func(x, y float64) float64 {
		wx, wy := x-ax, y-ay
		t := math.Max(0, math.Min(1, dot(wx, wy, ex, ey)/ll))
		return hypot(wx-float64(ex*t), wy-float64(ey*t))
	}
}

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
	p, q := float64(a*a), float64(b*b)
	s, e := twoSum(p, q)
	e += math.FMA(a, a, -p) + math.FMA(b, b, -q)
	h := math.Sqrt(s)
	u := math.Nextafter(h, math.Inf(1)) - h
	c := (math.FMA(-h, h, s) + e) / float64(2*h)
	switch {
	case math.Abs(c) < float64(0.4999*u):
		return h
	case c > float64(0.5001*u) && c < float64(1.4999*u):
		return h + u
	case c < float64(-0.5001*u) && c > float64(-1.4999*u) && math.Nextafter(h, 0) == h-u:
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

func polySDF(pts [][2]float64) sdf {
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
			d = math.Min(d, hypot(wx-float64(ex*t), wy-float64(ey*t)))
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

// dot は a·b。積を 1 つずつ丸め、Go が積と和を FMA にまとめるのを止める。
func dot(ax, ay, bx, by float64) float64 { return float64(ax*bx) + float64(ay*by) }

func nums(v any) []float64 {
	arr, _ := v.([]any)
	out := make([]float64, len(arr))
	for i, e := range arr {
		out[i], _ = e.(float64)
	}
	return out
}

func vecs(v any) [][2]float64 {
	arr, _ := v.([]any)
	out := make([][2]float64, 0, len(arr))
	for _, e := range arr {
		if p := nums(e); len(p) == 2 {
			out = append(out, [2]float64{p[0], p[1]})
		}
	}
	return out
}

func strs(v any) []string {
	arr, _ := v.([]any)
	out := make([]string, 0, len(arr))
	for _, e := range arr {
		s, _ := e.(string)
		out = append(out, s)
	}
	return out
}

func keysOf(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
