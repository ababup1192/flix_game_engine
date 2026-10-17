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
	shape   pxlib.Mask  // 形の塊（形が無ければ nil）
	region  pxlib.Mask  // 塊を作る op が描いた範囲
	written pxlib.Mask  // 書いた画素
	before  *pxlib.Grid // この部品を描く前の格子（動かす op が下の画素を戻すのに使う）
	rest    pxlib.Mask  // 動かす前の塊（子の clip と on はここを見る。動かしていなければ nil）
	follow  []pixelMove // この部品に当てた動き（自分の動きの op・rotate と、親から受けた動き）。子は同じ動きを受ける
	isPost  bool        // post（描き終えた絵の全体が対象）
}

// pixelMove は部品の画素を動かす 1 手（sway・bob・squash・rotate）。子の部品にも同じ手を当てる。
type pixelMove func(map[pxlib.Pt]pxlib.Key) map[pxlib.Pt]pxlib.Key

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

// restRegion は動かす前の塊（子が clip と on で見る所）。
func (p *partState) restRegion() pxlib.Mask {
	if p.rest != nil {
		return p.rest
	}
	return p.Region()
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

	FrameIndex, FrameCount int                    // コマの番号と数（動きの op が使う）
	Seed                   int                    // 変種の seed（variants。無ければ 0）
	hexOf                  map[pxlib.Key]string   // 色キー → #rrggbb
	style                  *pxStyle               // 機種の決まり（無ければ nil）
	picked                 map[string][]pxlib.Key // ramp_pick が選んだランプ（部品 id → 段）
	measures               []measure              // contrast が測った明度差
	tile                   bool                   // tile_preview がある（3×3 の見本と継ぎ目の検査）
	wrap                   bool                   // 端を回して描いた（scatter_clusters の wrap か tile_preview。orphan は 3×3 で見る）
}

// edgeOps は塊の縁を見て描く op。部品が動く時は、動いた後の塊に当てる（動かしてから縁取る）。
var edgeOps = map[string]bool{"sel_out": true, "rim_light": true, "aa_corners": true, "outline": true, "pixel_perfect": true, "ground_shadow": true}

// opStep は部品の ops の 1 手（並べ替えても違反の場所は書いた順の番号で出す）。
type opStep struct {
	call  opCall
	index int
}

// 並べ替えの印（opStep.index に入れる）。
const (
	stepFollow = -1 // 親の動きを受ける
	stepRotate = -2 // 部品の rotate
)

// partSteps は部品の ops を描く順に並べる。部品が動かない時は書いた順（rotate は最後）。動く時（動きの op を持つ・
// rotate がある・親が動いた）は「塗りと模様 → 動き → rotate → 親の動き → 縁」: 模様も形と一緒に動き、縁は動いた後の塊に付く。
func partSteps(ops []opCall, rotate, parentMoves bool) []opStep {
	moves := parentMoves || rotate
	for _, call := range ops {
		if animOps[call.Name] && call.Name != "palette_cycle" && call.Name != "wave_shift" {
			moves = true
		}
	}
	var paint, motion, edge []opStep
	for i, call := range ops {
		switch {
		case !moves:
			paint = append(paint, opStep{call, i})
		case animOps[call.Name] && call.Name != "palette_cycle" && call.Name != "wave_shift":
			motion = append(motion, opStep{call, i})
		case edgeOps[call.Name]:
			edge = append(edge, opStep{call, i})
		default:
			paint = append(paint, opStep{call, i})
		}
	}
	out := append(paint, motion...)
	if rotate {
		out = append(out, opStep{index: stepRotate})
	}
	if parentMoves {
		out = append(out, opStep{index: stepFollow})
	}
	return append(out, edge...)
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
		c.Part.before = c.G.Clone()
		c.ox, c.oy = p.At.X, p.At.Y
		var parent *partState
		if p.On != "" {
			parent = c.parts[p.On]
		}
		parentMoves := parent != nil && len(parent.follow) > 0
		var checks []checkRef
		for _, st := range partSteps(p.Ops, p.Rotate != 0, parentMoves) {
			if st.index == stepRotate {
				c.ref = pxlib.OpRef{Part: p.ID, Index: len(p.Ops), Op: "rotate"}
				c.rotatePart(p.Rotate, p.Pivot)
				checks = append(checks, checkRef{Check: checkSprite, Rule: "orphan"})
				continue
			}
			if st.index == stepFollow {
				c.ref = pxlib.OpRef{Part: p.ID, Index: len(p.Ops), Op: "follow:" + p.On}
				c.followParent(parent)
				checks = append(checks, checkRef{Check: checkSprite, Rule: "orphan"})
				continue
			}
			c.ref = pxlib.OpRef{Part: p.ID, Index: st.index, Op: st.call.Name}
			if err := c.apply(st.call); err != nil {
				return err
			}
			op, _ := lookupOp(st.call.Name)
			checks = append(checks, op.Checks...)
		}
		if after != nil {
			if err := after(c.Part, checks); err != nil {
				return err
			}
		}
	}
	c.Part = &partState{Part: &part{ID: "post"}, written: pxlib.NewMask(c.G.W, c.G.H), isPost: true}
	c.ox, c.oy = 0, 0
	var postChecks []checkRef
	for i, call := range post {
		c.Part.region = c.G.Opaque()
		c.Part.shape = nil
		c.Part.before = c.G.Clone()
		c.ref = pxlib.OpRef{Part: "post", Index: i, Op: call.Name}
		if err := c.apply(call); err != nil {
			return err
		}
		op, _ := lookupOp(call.Name)
		postChecks = append(postChecks, op.Checks...)
	}
	if after != nil && len(postChecks) > 0 {
		c.Part.region = c.G.Opaque()
		c.Part.shape = nil
		return after(c.Part, postChecks)
	}
	return nil
}

// moveBy は今の部品の画素を mv で動かし、塊も動いた先に替える（動かす前の塊は rest に残す）。
// mv は子の部品にも同じように当てるので follow に積む。
func (c *ctx) moveBy(mv pixelMove) {
	ps := c.Part
	if ps.rest == nil && !ps.isPost {
		ps.rest = ps.Region()
	}
	c.dropPixels(mv(c.liftPart()))
	if ps.isPost {
		return
	}
	moved := pxlib.NewMask(c.G.W, c.G.H)
	for _, p := range ps.written.Points() {
		moved[p.Y][p.X] = true
	}
	if ps.shape != nil {
		ps.shape = moved
	} else {
		ps.region = moved
	}
	ps.follow = append(ps.follow, mv)
}

// followParent は親の部品が受けた動きを、今の部品にも同じ順で当てる。
func (c *ctx) followParent(parent *partState) {
	ps := c.Part
	if ps.rest == nil {
		ps.rest = ps.Region()
	}
	src := c.liftPart()
	for _, mv := range parent.follow {
		src = mv(src)
	}
	c.dropPixels(src)
	moved := pxlib.NewMask(c.G.W, c.G.H)
	for _, p := range ps.written.Points() {
		moved[p.Y][p.X] = true
	}
	if ps.shape != nil {
		ps.shape = moved
	} else {
		ps.region = moved
	}
	ps.follow = append(ps.follow, parent.follow...)
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

// under は今の部品が描く前にその画素にあった色（部品が描いていない画素か post なら透明）。
// 線から画素を抜く op が、地の上の線に穴を開けないために使う。
func (c *ctx) under(p pxlib.Pt) pxlib.Key {
	ps := c.Part
	if ps.isPost || ps.before == nil || !ps.written.At(p.X, p.Y) {
		return pxlib.Clear
	}
	return ps.before.At(p.X, p.Y)
}

// allRamps は今の部品のランプ・ramp_pick が選んだランプ（部品 id の順）・spec のランプ全部（色からランプを引く時の順）。
func (c *ctx) allRamps() [][]pxlib.Key {
	var out [][]pxlib.Key
	if r := c.Ramp(); len(r) > 0 {
		out = append(out, r)
	}
	if c.Sprite != nil {
		if r := c.Spec.Ramps[c.Sprite.Ramp]; len(r) > 0 {
			out = append(out, r)
		}
	}
	for _, id := range sortedKeys(c.picked) {
		out = append(out, c.picked[id])
	}
	for _, n := range sortedKeys(c.Spec.Ramps) {
		out = append(out, c.Spec.Ramps[n])
	}
	return out
}

// Ref は今の op の場所。
func (c *ctx) Ref() pxlib.OpRef { return c.ref }

// clipMask は clip の部品が描いてよい範囲（親の塊）。clip でなければ nil。
func (c *ctx) clipMask() pxlib.Mask {
	if !c.Part.Part.Clip {
		return nil
	}
	return c.parts[c.Part.Part.On].restRegion()
}

// OnRegion は親（on）の塊。親が無ければ nil。
func (c *ctx) OnRegion() pxlib.Mask {
	if c.Part.Part.On == "" {
		return nil
	}
	return c.parts[c.Part.Part.On].restRegion()
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
// ink などはランプの段が先（ランプが無い部品でだけ同じ名前の色キーを指す。重なる色キーは台本の advice が知らせる）。
func (c *ctx) Color(ref colorRef) (pxlib.Key, error) {
	name := string(ref)
	switch name {
	case "":
		return pxlib.Clear, nil
	case "ink", "shade", "mid", "light":
		i := map[string]int{"ink": 0, "shade": 1, "mid": 2, "light": 3}[name]
		if i >= len(c.Ramp()) && c.hasKey != nil && c.hasKey(pxlib.Key(name)) {
			return pxlib.Key(name), nil // ランプが無い（足りない）部品では、同じ名前の色キーを直に指す
		}
		return c.RampAt(i)
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
