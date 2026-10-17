package px

// 色の段（ランプ）を選ぶ・影の形を 1 段重ねる・明度差を測る op。
//
// ramp_pick の考え方（明るい段は黄 60° へ・暗い段は青 240° へ色相を寄せる hue shift）は
// Pixelorama の Shading tool（scripts/.../Shading.gd、MIT License、Copyright (c) Orama Interactive and contributors）
// から取った。コードは写していない（選び方の点数は bin/pxkit/tone.py の下書きから）。
// 明るさは Oklab の L（人の目の明るさに近い）で比べ、色相は HSV で回す。

import (
	"fmt"
	"math"
	"sort"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

const (
	warmHue = 60.0  // 明るい段が寄る黄（HSV の色相・度）
	coolHue = 240.0 // 暗い段が寄る青
)

// hsvHue は #rrggbb の HSV の色相（度）。灰色（最大と最小の差が 0.04 未満）は ok = false。
func hsvHue(hex string) (float64, bool) {
	c, ok := pxlib.RGBAOfValue(hex)
	if !ok {
		return 0, false
	}
	r, g, b := float64(c[0])/255, float64(c[1])/255, float64(c[2])/255
	mx, mn := math.Max(r, math.Max(g, b)), math.Min(r, math.Min(g, b))
	if mx-mn < 0.04 {
		return 0, false
	}
	d := mx - mn
	var h float64
	switch mx {
	case r:
		h = math.Mod((g-b)/d, 6)
		if h < 0 {
			h += 6
		}
	case g:
		h = (b-r)/d + 2
	default:
		h = (r-g)/d + 4
	}
	return h * 60, true
}

// hueToward は色相 h を target へ近い回りで最大 deg 度回す。
func hueToward(h, target, deg float64) float64 {
	d := math.Mod(target-h+540, 360) - 180
	return math.Mod(h+math.Max(-deg, math.Min(deg, d))+360, 360)
}

// rampPickOpts は ramp_pick の強さ（どれも仮置き）。
type rampPickOpts struct {
	N, At               int
	Step, Shift, MinGap float64
}

// rampPick は base を at の段に置いた暗 → 明 n 段の色キーを pal（色キー → #rrggbb）から選ぶ。
// 狙いの L = L0 + k·step。色相は暗い段なら青へ・明るい段なら黄へ |k|·shift 度回す。
// 点数 4(L−狙い)² + 4(C−C0)² + (色相の差/180)²·min(1, c/0.1)（c = min(C0, C)。0.04 未満は色相を見ない）。
// 前の段から L が minGap 以上離れ、同じ色は 2 度使わない。候補が無ければ誤り。
func rampPick(pal map[string]string, base string, o rampPickOpts) ([]string, error) {
	hex, ok := pal[base]
	if !ok {
		return nil, fmt.Errorf("%s が色の候補に無い", base)
	}
	type cand struct {
		name   string
		lab    pxlib.Oklab
		c      float64
		hue    float64
		hasHue bool
	}
	names := make([]string, 0, len(pal))
	for k := range pal {
		names = append(names, k)
	}
	sort.Strings(names)
	var cands []cand
	labOf := map[string]pxlib.Oklab{}
	for _, k := range names {
		lab, ok := pxlib.OklabOfHex(pal[k])
		if !ok {
			continue
		}
		h, hh := hsvHue(pal[k])
		cands = append(cands, cand{k, lab, math.Hypot(lab[1], lab[2]), h, hh})
		labOf[k] = lab
	}
	l0 := labOf[base]
	c0 := math.Hypot(l0[1], l0[2])
	h0, hasH0 := hsvHue(hex)
	out := make([]string, o.N)
	out[o.At] = base
	used := map[string]bool{base: true}
	pick := func(k int, prevL float64, darker bool) (string, error) {
		wantL := l0[0] + float64(k)*o.Step
		best, bestS := "", math.Inf(1)
		for _, cd := range cands {
			L := cd.lab[0]
			if used[cd.name] || (darker && L > prevL-o.MinGap) || (!darker && L < prevL+o.MinGap) {
				continue
			}
			s := (L-wantL)*(L-wantL)*4 + (cd.c-c0)*(cd.c-c0)*4
			switch {
			case hasH0 && cd.hasHue:
				target := warmHue
				if darker {
					target = coolHue
				}
				want := hueToward(h0, target, o.Shift*math.Abs(float64(k)))
				dh := math.Abs(math.Mod(cd.hue-want+540, 360)-180) / 180
				if cc := math.Min(c0, cd.c); cc >= 0.04 {
					s += dh * dh * math.Min(1, cc/0.1) // 灰に近いほど色相は効かない
				}
			case hasH0 != cd.hasHue:
				s += 0.02 // 灰色と色つきは混ぜにくい
			}
			if s < bestS {
				best, bestS = cd.name, s
			}
		}
		if best == "" {
			side := "明るい"
			if darker {
				side = "暗い"
			}
			return "", fmt.Errorf("%s の%s側に %d 段目の色が無い（n か step を下げる）", base, side, abs(k))
		}
		used[best] = true
		return best, nil
	}
	for i := o.At - 1; i >= 0; i-- {
		n, err := pick(i-o.At, labOf[out[i+1]][0], true)
		if err != nil {
			return nil, err
		}
		out[i] = n
	}
	for i := o.At + 1; i < o.N; i++ {
		n, err := pick(i-o.At, labOf[out[i-1]][0], false)
		if err != nil {
			return nil, err
		}
		out[i] = n
	}
	return out, nil
}

// candidates は色を選ぶ op の候補（機種の決まりに色の集合があればそれ、無ければ色票の全部）。
func (c *ctx) candidates() map[string]string {
	if c.style != nil && len(c.style.Colors) > 0 {
		return c.style.Colors
	}
	out := map[string]string{}
	for k, h := range c.hexOf {
		if pxlib.IsHexColor(h) {
			out[string(k)] = h
		}
	}
	return out
}

// measure は contrast が測った 1 件。
type measure struct {
	Part, Against string
	D, Min        float64
	At            pxlib.Pt
}

// meanL は塊の画素の L の平均（透明と色票に無い色は数えない）。
func (c *ctx) meanL(m pxlib.Mask) (float64, pxlib.Pt, bool) {
	sum, n := 0.0, 0
	var at pxlib.Pt
	for _, p := range m.Points() {
		l, ok := pxlib.Lightness(c.hexOf[c.G.At(p.X, p.Y)])
		if !ok {
			continue
		}
		if n == 0 {
			at = p
		}
		sum += l
		n++
	}
	if n == 0 {
		return 0, at, false
	}
	return sum / float64(n), at, true
}

func init() {
	register(&opDef{
		Name: "ramp_pick", Example: `{"ramp_pick": {"base": "c2", "n": 3, "shift": 0}}`,
		Summary:   "地の色 base から暗 → 明 n 段のランプを色票（style があればその色）から選び、この部品のランプにする（hue shift つき）",
		Technique: "hue shift のランプ（Pixelorama の Shading tool の Hue Shifting）", Finish: "色の門・ランプの単調さ（ramp-order）",
		Params: []param{
			{Name: "base", Type: tString, Required: true, Summary: "地の段に置く色キー"},
			{Name: "n", Type: tInt, Default: 4.0, Summary: "段の数"},
			{Name: "at", Type: tInt, Default: -1.0, Summary: "base を置く段（-1 で n-2 = [墨, 影, 地, 光] の地）"},
			{Name: "step", Type: tNumber, Default: 0.13, Summary: "段ごとの明るさ（Oklab の L）の差の狙い。金属は 0.2 ほどに上げる"},
			{Name: "shift", Type: tNumber, Default: 30.0, Summary: "段ごとに色相を寄せる度数（0 で hue shift を切る）"},
			{Name: "min_gap", Type: tNumber, Default: 0.05, Summary: "隣の段との L の差の最小"},
		},
		Checks: []checkRef{{Check: checkRampOrder}, {Check: checkGroundContrast}},
		Apply: func(c *ctx, a opArgs) error {
			n := a.int("n")
			at := a.int("at")
			if at < 0 {
				at = n - 2
			}
			if n < 2 || at < 0 || at >= n {
				return fmt.Errorf("n は 2 以上・at は 0〜n-1")
			}
			names, err := rampPick(c.candidates(), a.str("base"), rampPickOpts{N: n, At: at, Step: a.num("step"), Shift: a.num("shift"), MinGap: a.num("min_gap")})
			if err != nil {
				return err
			}
			ramp := make([]pxlib.Key, len(names))
			for i, k := range names {
				ramp[i] = pxlib.Key(k)
			}
			c.Part.Ramp = ramp
			if c.picked == nil {
				c.picked = map[string][]pxlib.Key{}
			}
			c.picked[c.Part.Part.ID] = ramp
			return nil
		},
	})
	register(&opDef{
		Name: "shade_mask", Example: `{"shade_mask": {"of": "base", "offset": [1, 1]}}`,
		Summary:   "別の部品 of の塊を光と反対へ offset ずらした形で、今の部品に塗ってある色を by 段ずらす（手前の物が落とす影）",
		Technique: "1 段ずつ塗る（Aseprite の Shading ink）・影の形を重ねる", Finish: "—",
		Params: []param{
			{Name: "of", Type: tString, Required: true, Summary: "影を落とす部品の id（この部品より前の列）"},
			{Name: "by", Type: tInt, Default: -1.0, Summary: "ずらす段数（負で暗く）"},
			{Name: "offset", Type: tPoint, Summary: "影のずれ [dx, dy]（省くと光と反対へ 1px）"},
		},
		Apply: func(c *ctx, a opArgs) error {
			src, ok := c.parts[a.str("of")]
			if !ok {
				return fmt.Errorf("部品 %q が無い", a.str("of"))
			}
			ramp := c.Ramp()
			if len(ramp) == 0 {
				return fmt.Errorf("部品にランプが無い")
			}
			sx, sy := c.LightSign()
			d := pxlib.Pt{X: -sx, Y: -sy}
			if a.has("offset") {
				d = a.point("offset")
			}
			from := src.Region()
			own := c.Region()
			for _, p := range from.Points() {
				x, y := p.X+d.X, p.Y+d.Y
				if !own.At(x, y) || from.At(x, y) {
					continue
				}
				k := c.G.At(x, y)
				if to := shadeStep(ramp, k, a.int("by")); to != k {
					c.PutAbs(x, y, to)
				}
			}
			return nil
		},
	})
	register(&opDef{
		Name: "contrast", Example: `{"contrast": {"against": "base"}}`,
		Summary:   "今の部品と相手（部品 against か地の色）の明るさ（Oklab の L）の平均の差を測るだけ（描かない）",
		Technique: "背景の奥行き（遠いほど明度差が小さい）・主役と背景を分ける", Finish: "lint value-sep",
		Params: []param{
			{Name: "against", Type: tString, Summary: "相手の部品 id（省くと light.ground の地の色）"},
			{Name: "min", Type: tNumber, Default: 0.0, Summary: "差の下限（0 で bin/lint-rules/px.json の valueSepMin）"},
		},
		Checks: []checkRef{{Check: checkValueSep}},
		Apply: func(c *ctx, a opArgs) error {
			la, at, ok := c.meanL(c.Region().Union(c.Part.written))
			if !ok {
				return fmt.Errorf("測る画素が無い（contrast は塗った後に置く）")
			}
			var lb float64
			name := a.str("against")
			if name != "" {
				p, ok := c.parts[name]
				if !ok {
					return fmt.Errorf("部品 %q が無い", name)
				}
				if lb, _, ok = c.meanL(p.Region().Union(p.written)); !ok {
					return fmt.Errorf("部品 %q に測る画素が無い", name)
				}
			} else {
				g := groundHex(c.Spec.Light.Ground, map[string]string{})
				if h, ok := c.hexOf[pxlib.Key(c.Spec.Light.Ground)]; ok {
					g = h
				}
				var ok bool
				if lb, ok = pxlib.Lightness(g); !ok {
					return fmt.Errorf("相手が無い（against か light.ground を書く）")
				}
				name = "地"
			}
			c.measures = append(c.measures, measure{Part: c.Part.Part.ID, Against: name, D: math.Abs(la - lb), Min: a.num("min"), At: at})
			return nil
		},
	})
}
