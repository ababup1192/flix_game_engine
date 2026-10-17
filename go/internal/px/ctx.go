package px

// 1 コマを描く間の状態（Ctx）と、部品の列を順に描く流れ。
//
// 部品ごとに op を順に当てる。書いた画素には「どの部品の何番目の op か」（OpRef）が残り、
// 検査の違反はそこから原因を引く。部品の塊（Region）は、形があれば形、無ければ
// 塊を作る op（glyph・bevel_box・fill）が描いた範囲、それも無ければ書いた画素。

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// partState は描いている途中の部品。
type partState struct {
	Part    *part
	Ramp    []pxlib.Key
	shape   pxlib.Mask // 形の塊（形が無ければ nil）
	region  pxlib.Mask // 塊を作る op が描いた範囲
	written pxlib.Mask // 書いた画素
}

// Region は部品の塊。
func (p *partState) Region() pxlib.Mask {
	switch {
	case p.shape != nil:
		return p.shape
	case p.region != nil:
		return p.region
	}
	return p.written
}

// ctx は 1 コマを描く間の状態。
type ctx struct {
	G      *pxlib.Grid
	Spec   *specDoc
	Sprite *spriteSpec
	Frame  string
	Part   *partState

	parts  map[string]*partState
	order  []*part
	ref    pxlib.OpRef
	ox, oy int // use の at で足すずらし（部品の at も含む）
	depth  int
	hasKey func(pxlib.Key) bool
	keyOf  map[string]pxlib.Key // legend の文字 → 色キー（stamp を legend の文字で打つとき）
	shade  *shadeSet
}

// drawFrame は部品の列と post を描いた格子を返す。after は部品を描き終えるたびに呼ばれる（部品の範囲の検査）。
func drawFrame(c *ctx, parts []*part, post []opCall, after func(*partState, []checkRef) error) error {
	c.parts = map[string]*partState{}
	c.order = parts
	for _, p := range parts {
		ps := &partState{Part: p, Ramp: c.Spec.Ramps[p.Ramp], written: pxlib.NewMask(c.G.W, c.G.H)}
		if p.Shape != nil {
			f, err := shapeOf(p.Shape, c.Spec.Shapes, p.Where+".shape")
			if err != nil {
				return err
			}
			ps.shape = pxlib.MaskOf(c.G.W, c.G.H, shiftSDF(f, p.At.X, p.At.Y))
		}
		c.parts[p.ID] = ps
	}
	for _, p := range parts {
		c.Part = c.parts[p.ID]
		c.ox, c.oy = p.At.X, p.At.Y
		var checks []checkRef
		for i, call := range p.Ops {
			c.ref = pxlib.OpRef{Part: p.ID, Index: i, Op: call.Name}
			if err := c.apply(call); err != nil {
				return err
			}
			op, _ := lookupOp(call.Name)
			checks = append(checks, op.Checks...)
		}
		if after != nil {
			if err := after(c.Part, checks); err != nil {
				return err
			}
		}
	}
	c.Part = &partState{Part: &part{ID: "post"}, written: pxlib.NewMask(c.G.W, c.G.H)}
	c.ox, c.oy = 0, 0
	for i, call := range post {
		c.Part.region = c.G.Opaque()
		c.ref = pxlib.OpRef{Part: "post", Index: i, Op: call.Name}
		if err := c.apply(call); err != nil {
			return err
		}
	}
	return nil
}

// apply は op を 1 つ当てる。誤りには op の場所（例 body.ops[1] shade_step）を付ける。
func (c *ctx) apply(call opCall) error {
	op, ok := lookupOp(call.Name)
	if !ok {
		return fmt.Errorf("%s: 知らない op", call.Where)
	}
	if op.Whole && (c.ox != 0 || c.oy != 0) {
		return fmt.Errorf("%s: 格子全体に描く op なので、部品の at・use の at でずらせない", call.Where)
	}
	if err := op.Apply(c, call.Args); err != nil {
		return fmt.Errorf("%s: %w", call.Where, err)
	}
	return nil
}

// Ref は今の op の場所。
func (c *ctx) Ref() pxlib.OpRef { return c.ref }

// clipMask は clip の部品が描いてよい範囲（親の塊）。clip でなければ nil。
func (c *ctx) clipMask() pxlib.Mask {
	if !c.Part.Part.Clip {
		return nil
	}
	return c.parts[c.Part.Part.On].Region()
}

// OnRegion は親（on）の塊。親が無ければ nil。
func (c *ctx) OnRegion() pxlib.Mask {
	if c.Part.Part.On == "" {
		return nil
	}
	return c.parts[c.Part.Part.On].Region()
}

// PutAbs は格子の座標そのままで 1 画素を書く（clip の範囲の外は書かない）。
func (c *ctx) PutAbs(x, y int, k pxlib.Key) {
	if !c.G.In(x, y) {
		return
	}
	if m := c.clipMask(); m != nil && !m.At(x, y) {
		return
	}
	c.G.Put(x, y, k, c.ref)
	c.Part.written[y][x] = true
}

// Put は部品の at と use の at でずらして 1 画素を書く。
func (c *ctx) Put(x, y int, k pxlib.Key) { c.PutAbs(x+c.ox, y+c.oy, k) }

// FillAbs は塊を 1 色で塗る。
func (c *ctx) FillAbs(m pxlib.Mask, k pxlib.Key) {
	for _, p := range m.Points() {
		c.PutAbs(p.X, p.Y, k)
	}
}

// AddRegion は塊を作る op が描いた範囲を部品の塊に足す。
func (c *ctx) AddRegion(m pxlib.Mask) {
	if c.Part.region == nil {
		c.Part.region = pxlib.NewMask(c.G.W, c.G.H)
	}
	c.Part.region = c.Part.region.Union(m)
}

// Region は今の部品の塊。
func (c *ctx) Region() pxlib.Mask { return c.Part.Region() }

// MaskOf は形を（at でずらして）塊にする。
func (c *ctx) MaskOf(shape any) (pxlib.Mask, error) {
	f, err := shapeOf(shape, c.Spec.Shapes, "shape")
	if err != nil {
		return nil, err
	}
	return pxlib.MaskOf(c.G.W, c.G.H, shiftSDF(f, c.ox, c.oy)), nil
}

// ShapeOrRegion は引数 shape があればその塊、無ければ部品の塊。
func (c *ctx) ShapeOrRegion(a opArgs) (pxlib.Mask, error) {
	if a.has("shape") {
		return c.MaskOf(a.shape("shape"))
	}
	return c.Region(), nil
}

func shiftSDF(f sdf, dx, dy int) sdf {
	if dx == 0 && dy == 0 {
		return f
	}
	fx, fy := float64(dx), float64(dy)
	return func(x, y float64) float64 { return f(x-fx, y-fy) }
}

// Ramp は今の部品のランプ（暗 → 明）。
func (c *ctx) Ramp() []pxlib.Key { return c.Part.Ramp }

// RampAt はランプの i 段目。段が足りなければ誤り。
func (c *ctx) RampAt(i int) (pxlib.Key, error) {
	r := c.Ramp()
	if i < 0 || i >= len(r) {
		if len(r) == 0 {
			return "", fmt.Errorf("部品にランプが無い（部品かスプライトに \"ramp\" を書く）")
		}
		return "", fmt.Errorf("ランプの %d 段目が無い（ランプ %q は %d 段）", i, c.Part.Part.Ramp, len(r))
	}
	return r[i], nil
}

// NeedRamp は暗 → 明の n 段以上のランプが要る op の前提。
func (c *ctx) NeedRamp(n int) error {
	if len(c.Ramp()) < n {
		return fmt.Errorf("暗 → 明の %d 段のランプが要る（今は %d 段。部品かスプライトに \"ramp\" を書く）", n, len(c.Ramp()))
	}
	return nil
}

// Gloss はつやの色（light.gloss）。
func (c *ctx) Gloss() (pxlib.Key, error) {
	if c.Spec.Light.Gloss == "" {
		return "", fmt.Errorf("つやの色が無い（light.gloss に色キーを書く）")
	}
	return c.Spec.Light.Gloss, nil
}

// Color は色の参照を色キーにする: ink・shade・mid・light（ランプの 0〜3 段）・ramp[i]・gloss・""（透明）・色キー。
func (c *ctx) Color(ref colorRef) (pxlib.Key, error) {
	name := string(ref)
	switch name {
	case "":
		return pxlib.Clear, nil
	case "ink":
		return c.RampAt(0)
	case "shade":
		return c.RampAt(1)
	case "mid":
		return c.RampAt(2)
	case "light":
		return c.RampAt(3)
	case "gloss":
		return c.Gloss()
	}
	if strings.HasPrefix(name, "ramp[") && strings.HasSuffix(name, "]") {
		i, err := strconv.Atoi(name[5 : len(name)-1])
		if err != nil {
			return "", fmt.Errorf("色 %q は ramp[段の番号] で書く", name)
		}
		if i < 0 {
			i += len(c.Ramp()) // ramp[-1] は一番明るい段
		}
		return c.RampAt(i)
	}
	k := pxlib.Key(name)
	if c.hasKey != nil && !c.hasKey(k) {
		return "", fmt.Errorf("色キー %q が legend にも色票にも無い", name)
	}
	return k, nil
}

// LightSign は光の来る向きの符号（左上なら (-1, -1)）。
func (c *ctx) LightSign() (int, int) {
	sign := func(v float64) int {
		switch {
		case v < 0:
			return -1
		case v > 0:
			return 1
		}
		return 0
	}
	return sign(c.Spec.Light.Dir[0]), sign(c.Spec.Light.Dir[1])
}
