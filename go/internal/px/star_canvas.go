package px

// 台本の低い所の部品（原理は入れない）: px.canvas（画素の格子）・px.band（位置ごとの帯の番号）・px.shape_light（形ごとの光の帯）。
// vs-a（原理を台本で組んだ組）が毎回自前で書いた所だけを道具にする。帯をどう引くか・段をどうずらすかは台本が決める。

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"go.starlark.net/starlark"
)

// ---------------------------------------------------------------- px.canvas

// starCanvas は画素の格子。1 画素は (ランプ名, 段) か色キー 1 つか None。
type starCanvas struct {
	w, h   int
	ramps  map[string][]string // ランプ名 → 色キー（暗 → 明）
	px     []starlark.Value    // None・(ramp, i)・"色キー"
	frozen bool
}

var _ starlark.HasAttrs = (*starCanvas)(nil)

func (c *starCanvas) String() string       { return fmt.Sprintf("canvas(%d, %d)", c.w, c.h) }
func (c *starCanvas) Type() string         { return "canvas" }
func (c *starCanvas) Freeze()              { c.frozen = true }
func (c *starCanvas) Truth() starlark.Bool { return true }
func (c *starCanvas) Hash() (uint32, error) {
	return 0, fmt.Errorf("canvas は辞書の鍵にできない")
}
func (c *starCanvas) AttrNames() []string {
	return []string{"count", "each", "get", "h", "put", "shift", "to_op", "w"}
}

func (c *starCanvas) Attr(name string) (starlark.Value, error) {
	switch name {
	case "w":
		return starlark.MakeInt(c.w), nil
	case "h":
		return starlark.MakeInt(c.h), nil
	case "put":
		return starlark.NewBuiltin("canvas.put", c.put), nil
	case "get":
		return starlark.NewBuiltin("canvas.get", c.get), nil
	case "shift":
		return starlark.NewBuiltin("canvas.shift", c.shift), nil
	case "each":
		return starlark.NewBuiltin("canvas.each", c.each), nil
	case "count":
		return starlark.NewBuiltin("canvas.count", c.count), nil
	case "to_op":
		return starlark.NewBuiltin("canvas.to_op", c.toOp), nil
	}
	return nil, nil
}

func (c *starCanvas) in(x, y int) bool { return x >= 0 && y >= 0 && x < c.w && y < c.h }

// starNewCanvas は px.canvas(w, h, ramps={}) 。ramps は px.palette が返すランプ（名前 → 色キーの列）。
func starNewCanvas(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var w, h int
	var ramps *starlark.Dict
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "w", &w, "h", &h, "ramps?", &ramps); err != nil {
		return nil, err
	}
	if w < 1 || h < 1 || w*h > 512*512 {
		return nil, fmt.Errorf("%s: 大きさは 1〜512 四方", b.Name())
	}
	c := &starCanvas{w: w, h: h, ramps: map[string][]string{}, px: make([]starlark.Value, w*h)}
	for i := range c.px {
		c.px[i] = starlark.None
	}
	if ramps != nil {
		for _, kv := range ramps.Items() {
			name, ok := starlark.AsString(kv[0])
			if !ok {
				return nil, fmt.Errorf("%s: ramps の鍵は名前（文字列）", b.Name())
			}
			list, ok := kv[1].(*starlark.List)
			if !ok {
				return nil, fmt.Errorf("%s: ramps[%q] は色キーの列", b.Name(), name)
			}
			for i := 0; i < list.Len(); i++ {
				k, ok := starlark.AsString(list.Index(i))
				if !ok {
					return nil, fmt.Errorf("%s: ramps[%q] は色キーの列", b.Name(), name)
				}
				c.ramps[name] = append(c.ramps[name], k)
			}
		}
	}
	return c, nil
}

// put(x, y, ramp, i) で段・put(x, y, "色キー") で色 1 つ・put(x, y, None) で消す。格子の外は黙って捨てる。段は端で止める。
func (c *starCanvas) put(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	if c.frozen {
		return nil, fmt.Errorf("%s: 凍った canvas には置けない", b.Name())
	}
	var x, y int
	var v starlark.Value
	var step starlark.Value = starlark.None
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "x", &x, "y", &y, "value", &v, "i?", &step); err != nil {
		return nil, err
	}
	if !c.in(x, y) {
		return starlark.None, nil
	}
	if step != starlark.None {
		name, ok := starlark.AsString(v)
		if !ok {
			return nil, fmt.Errorf("%s: put(x, y, ランプ名, 段) のランプ名は文字列", b.Name())
		}
		n, err := starlark.AsInt32(step)
		if err != nil {
			return nil, fmt.Errorf("%s: 段は整数", b.Name())
		}
		r, ok := c.ramps[name]
		if !ok {
			return nil, fmt.Errorf("%s: ランプ %q が px.canvas(ramps=…) に無い", b.Name(), name)
		}
		n = min(max(n, 0), len(r)-1)
		c.px[y*c.w+x] = starlark.Tuple{starlark.String(name), starlark.MakeInt(n)}
		return starlark.None, nil
	}
	switch v.(type) {
	case starlark.String, starlark.NoneType:
		c.px[y*c.w+x] = v
	default:
		return nil, fmt.Errorf("%s: 置ける物は (ランプ名, 段)・色キー・None", b.Name())
	}
	return starlark.None, nil
}

// get(x, y) は置いた物（(ランプ名, 段)・色キー・None。格子の外は None）。
func (c *starCanvas) get(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var x, y int
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "x", &x, "y", &y); err != nil {
		return nil, err
	}
	if !c.in(x, y) {
		return starlark.None, nil
	}
	return c.px[y*c.w+x], nil
}

// shift(x, y, by) は置いた段を同じランプの中で by 段ずらす（端で止める。色キー 1 つと None はそのまま）。
func (c *starCanvas) shift(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var x, y, by int
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "x", &x, "y", &y, "by", &by); err != nil {
		return nil, err
	}
	if !c.in(x, y) {
		return starlark.None, nil
	}
	if t, ok := c.px[y*c.w+x].(starlark.Tuple); ok {
		name, _ := starlark.AsString(t[0])
		n, _ := starlark.AsInt32(t[1])
		r := c.ramps[name]
		c.px[y*c.w+x] = starlark.Tuple{t[0], starlark.MakeInt(min(max(n+by, 0), len(r)-1))}
	}
	return starlark.None, nil
}

// each() は置いた画素の (x, y, 値) の列（上の行から）。
func (c *starCanvas) each(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	if err := starlark.UnpackArgs(b.Name(), args, kwargs); err != nil {
		return nil, err
	}
	var out []starlark.Value
	for i, v := range c.px {
		if v != starlark.None {
			out = append(out, starlark.Tuple{starlark.MakeInt(i % c.w), starlark.MakeInt(i / c.w), v})
		}
	}
	return starlark.NewList(out), nil
}

func (c *starCanvas) count(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	if err := starlark.UnpackArgs(b.Name(), args, kwargs); err != nil {
		return nil, err
	}
	n := 0
	for _, v := range c.px {
		if v != starlark.None {
			n++
		}
	}
	return starlark.MakeInt(n), nil
}

// canvasChars は書き出しの文字（ASCII の表示できる字から。'.' は透明）。
const canvasChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#$%&*+=?@^~!:;<>"

// to_op(at=[0,0]) は格子を pixels の op 1 つにする（色の名前は (ランプ名, 段) → ramps の色キー）。
func (c *starCanvas) toOp(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var at starlark.Value = starlark.None
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "at?", &at); err != nil {
		return nil, err
	}
	keyOf := func(v starlark.Value) string {
		switch t := v.(type) {
		case starlark.String:
			return string(t)
		case starlark.Tuple:
			name, _ := starlark.AsString(t[0])
			n, _ := starlark.AsInt32(t[1])
			return c.ramps[name][n]
		}
		return ""
	}
	chars := map[string]string{}
	var order []string
	rows := make([]starlark.Value, c.h)
	for y := 0; y < c.h; y++ {
		var row strings.Builder
		for x := 0; x < c.w; x++ {
			k := keyOf(c.px[y*c.w+x])
			if k == "" {
				row.WriteByte('.')
				continue
			}
			ch, ok := chars[k]
			if !ok {
				if len(chars) >= len(canvasChars) {
					return nil, fmt.Errorf("%s: 色が %d を超えた（1 枚の格子の色キーはここまで）", b.Name(), len(canvasChars))
				}
				ch = string(canvasChars[len(chars)])
				chars[k] = ch
				order = append(order, k)
			}
			row.WriteString(ch)
		}
		rows[y] = starlark.String(row.String())
	}
	sort.Strings(order)
	colors := starlark.NewDict(len(chars))
	for _, k := range order {
		if err := colors.SetKey(starlark.String(chars[k]), starlark.String(k)); err != nil {
			return nil, err
		}
	}
	a := starlark.NewDict(3)
	_ = a.SetKey(starlark.String("rows"), starlark.NewList(rows))
	_ = a.SetKey(starlark.String("colors"), colors)
	if at != starlark.None {
		_ = a.SetKey(starlark.String("at"), at)
	}
	out := starlark.NewDict(1)
	_ = out.SetKey(starlark.String("pixels"), a)
	return out, nil
}

// ---------------------------------------------------------------- px.band

// starBand は px.band(kind, …): 位置ごとの帯の番号（0 〜 count−1）を返す関数を作る。原理（帯をどこへ引くか）は台本が決める。
//
//	px.band("linear", origin=[x, y], dir=[dx, dy], width=w, count=n)   dir の向きへ width ごとに番号が 1 つ上がる
//	px.band("radial", center=[x, y], width=w, count=n)                  中心から width ごとに番号が 1 つ下がる（中心が一番上）
func starBand(_ *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var kind string
	var origin, dir, center *starlark.List
	var width starlark.Value = starlark.MakeInt(4)
	count := 3
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "kind", &kind, "origin?", &origin, "dir?", &dir, "center?", &center,
		"width?", &width, "count?", &count); err != nil {
		return nil, err
	}
	wd, ok := starlark.AsFloat(width)
	if !ok || wd <= 0 || count < 1 {
		return nil, fmt.Errorf("%s: width は正の数・count は 1 以上", b.Name())
	}
	pair := func(l *starlark.List, name string, def [2]float64) ([2]float64, error) {
		if l == nil {
			return def, nil
		}
		if l.Len() != 2 {
			return def, fmt.Errorf("%s: %s は [x, y]", b.Name(), name)
		}
		x, ok1 := starlark.AsFloat(l.Index(0))
		y, ok2 := starlark.AsFloat(l.Index(1))
		if !ok1 || !ok2 {
			return def, fmt.Errorf("%s: %s は [x, y] の数", b.Name(), name)
		}
		return [2]float64{x, y}, nil
	}
	var f func(x, y float64) float64
	switch kind {
	case "linear":
		o, err := pair(origin, "origin", [2]float64{0, 0})
		if err != nil {
			return nil, err
		}
		d, err := pair(dir, "dir", [2]float64{0, 1})
		if err != nil {
			return nil, err
		}
		l := math.Hypot(d[0], d[1])
		if l == 0 {
			return nil, fmt.Errorf("%s: dir が 0", b.Name())
		}
		f = func(x, y float64) float64 { return ((x-o[0])*d[0] + (y-o[1])*d[1]) / l / wd }
	case "radial":
		ce, err := pair(center, "center", [2]float64{0, 0})
		if err != nil {
			return nil, err
		}
		f = func(x, y float64) float64 { return float64(count-1) - math.Hypot(x-ce[0], y-ce[1])/wd }
	default:
		return nil, fmt.Errorf("%s: kind は linear か radial", b.Name())
	}
	return starlark.NewBuiltin("px.band.at", func(_ *starlark.Thread, fb *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
		var x, y starlark.Value
		if err := starlark.UnpackArgs(fb.Name(), args, kwargs, "x", &x, "y", &y); err != nil {
			return nil, err
		}
		fx, ok1 := starlark.AsFloat(x)
		fy, ok2 := starlark.AsFloat(y)
		if !ok1 || !ok2 {
			return nil, fmt.Errorf("%s: x・y は数", fb.Name())
		}
		n := int(math.Floor(f(fx, fy)))
		return starlark.MakeInt(min(max(n, 0), count-1)), nil
	}), nil
}

// ---------------------------------------------------------------- px.shape_light

// starShapeLight は px.shape_light(shapes, field, light=[-1, -1]): 形（[x, y, w, h] の矩形）ごとに、
// 中心での帯の番号 band と、光の側の縁の画素 edge と、その縁の 1 つ外での帯の番号 edge_band を返す
// （「光の範囲は形 1 個ずつ上げ、境の縁だけ次の段」を組むための材料。どう塗るかは台本が決める）。
func starShapeLight(th *starlark.Thread, b *starlark.Builtin, args starlark.Tuple, kwargs []starlark.Tuple) (starlark.Value, error) {
	var shapes *starlark.List
	var field starlark.Callable
	var light *starlark.List
	if err := starlark.UnpackArgs(b.Name(), args, kwargs, "shapes", &shapes, "field", &field, "light?", &light); err != nil {
		return nil, err
	}
	lx, ly := -1.0, -1.0
	if light != nil && light.Len() == 2 {
		lx, _ = starlark.AsFloat(light.Index(0))
		ly, _ = starlark.AsFloat(light.Index(1))
	}
	sx, sy := signOf(lx), signOf(ly)
	call := func(x, y float64) (int, error) {
		v, err := starlark.Call(th, field, starlark.Tuple{starlark.Float(x), starlark.Float(y)}, nil)
		if err != nil {
			return 0, err
		}
		n, err := starlark.AsInt32(v)
		if err != nil {
			return 0, fmt.Errorf("%s: field は整数を返す関数（px.band など）", b.Name())
		}
		return n, nil
	}
	var out []starlark.Value
	for i := 0; i < shapes.Len(); i++ {
		r, ok := shapes.Index(i).(*starlark.List)
		if !ok || r.Len() != 4 {
			return nil, fmt.Errorf("%s: shapes[%d] は [x, y, w, h]", b.Name(), i)
		}
		var v [4]int
		for k := range v {
			n, err := starlark.AsInt32(r.Index(k))
			if err != nil {
				return nil, fmt.Errorf("%s: shapes[%d] は整数の [x, y, w, h]", b.Name(), i)
			}
			v[k] = n
		}
		x, y, w, h := v[0], v[1], v[2], v[3]
		band, err := call(float64(x)+float64(w-1)/2, float64(y)+float64(h-1)/2)
		if err != nil {
			return nil, err
		}
		var edge []starlark.Value
		for yy := y; yy < y+h; yy++ {
			for xx := x; xx < x+w; xx++ {
				onX := sx < 0 && xx == x || sx > 0 && xx == x+w-1
				onY := sy < 0 && yy == y || sy > 0 && yy == y+h-1
				if onX || onY {
					edge = append(edge, starlark.Tuple{starlark.MakeInt(xx), starlark.MakeInt(yy)})
				}
			}
		}
		// 縁の 1 つ外（光の側）の帯の番号: 形の中心から光の向きへ形の半分 + 1 だけ出た所
		ex := float64(x) + float64(w-1)/2 + float64(sx)*(float64(w)/2+1)
		ey := float64(y) + float64(h-1)/2 + float64(sy)*(float64(h)/2+1)
		eb, err := call(ex, ey)
		if err != nil {
			return nil, err
		}
		d := starlark.NewDict(3)
		_ = d.SetKey(starlark.String("band"), starlark.MakeInt(band))
		_ = d.SetKey(starlark.String("edge"), starlark.NewList(edge))
		_ = d.SetKey(starlark.String("edge_band"), starlark.MakeInt(eb))
		out = append(out, d)
	}
	return starlark.NewList(out), nil
}
