package px

// 宣言そのものの検査（decl.*）と逃げ道を塞ぐ検査（checkset-design §2・§4・§9）と、発光の作法（§9.5・依頼主の決定 案 C）。
// どれも advice（0.42.0）。宣言を直す候補は fix.try の疑似の op（set kind・set material）で返す。

import (
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flixlint/go/checkres"
)

const (
	checkDecl  checkName = "decl" // 宣言の検査（規則は kind-missing など）
	checkGlow  checkName = "glow" // 発光の作法（emissive の部品）
	checkExUse checkName = "exempt-overuse"
)

func init() {
	for _, c := range []*checkDef{
		{Name: checkDecl, Summary: "decl: 宣言（kind・material・fidelity・lint-sprite の規則名）の書き忘れ・食い違い", Level: levelAdvice,
			Fix: "fix.try の set kind・set material を pxsrc に書く（kind の定義は bin/fge px kinds）"},
		{Name: checkGlow, Summary: "glow: emissive の部品の発光の作法（芯は最明色で小さく・まわりより明るい）", Level: levelAdvice,
			Fix: "芯は最明色の 1px〜小さく・輪は芯から 1〜2.5px に光の色の 25% の網（Bayer 4×4）を 1 段・照り返しは床に横長 3〜4 行（夜は輪 1 段）"},
		{Name: checkExUse, Summary: "exempt-overuse: op の Exempt で外した画素がコマあたり exemptPerFrameMax を超える", Level: levelAdvice,
			Fix: "Exempt の op を作法の形（角・縁）だけに使う。外した画素が検査に当たるなら形を直す"},
	} {
		c.Run = func(*pxlib.Grid, *checkCtx) []violation { return nil } // spec と sprite を見るので build が直に回す
		registerCheck(c)
	}
}

func declViolation(rule string, got float64, want checkres.Want, msg string) violation {
	v := newViolation(checkDecl, levelAdvice, got, want, msg)
	v.Rule, v.Scope = rule, checkres.ScopeSpec
	return v
}

// kindDecl は kind の書き忘れ・推せない・推した物との食い違い。
func kindDecl(sp *spriteSpec, spec *specDoc, rk resolvedKind) []violation {
	var out []violation
	inferred, why, known := inferKind(sp, spec)
	switch {
	case rk.By == "inferred":
		v := declViolation("kind-missing", 0, checkres.WantEqual(1),
			fmt.Sprintf("kind が無い（推した kind %s・根拠 %s）。spec の sprite %s に \"kind\": \"%s\"", rk.Kind, rk.Reason, sp.Name, rk.Kind)).
			fix("pxsrc の sprite に \"kind\" を書く（定義は bin/fge px kinds）", checkres.Try{Op: "set kind", Arg: sp.Name, Try: string(rk.Kind)})
		out = append(out, v)
		if !known {
			out = append(out, declViolation("kind-unknown", 0, checkres.WantEqual(1),
				fmt.Sprintf("%s の kind を推せない（prop で回した）。bin/fge px kinds の定義から選んで書く", sp.Name)).
				fix("", checkres.Try{Op: "set kind", Arg: sp.Name, Try: string(kindProp)}))
		}
	case known && inferred != sp.Kind && sp.KindWhy == "":
		out = append(out, declViolation("kind-mismatch", 0, checkres.WantEqual(1),
			fmt.Sprintf("%s: 宣言 kind %s・推した kind %s（根拠 %s）。合っているなら \"kind_why\" に理由を書く", sp.Name, sp.Kind, inferred, why)).
			fix("", checkres.Try{Op: "set kind", Arg: sp.Name, Now: string(sp.Kind), Try: string(inferred)}))
	}
	for i := range out {
		out[i].Sprite = sp.Name
	}
	return out
}

// materialDecl は character・prop・background の大きな部品の material の書き忘れ（材質が無い物は "none" を書く）。
func materialDecl(sp *spriteSpec, rk resolvedKind, parts []*part, g *pxlib.Grid, minPx int) []violation {
	if rk.Kind != kindCharacter && rk.Kind != kindProp && rk.Kind != kindBackground || g == nil {
		return nil
	}
	area := map[string]int{}
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			if g.At(x, y) != pxlib.Clear {
				area[g.SrcAt(x, y).Part]++
			}
		}
	}
	var out []violation
	for _, p := range parts {
		if p.Material != "" || area[p.ID] <= minPx {
			continue
		}
		v := declViolation("material-missing", 0, checkres.WantEqual(1),
			fmt.Sprintf("%s.%s（%d 画素）に material が無い。材質が無い物は \"material\": \"none\"", sp.Name, p.ID, area[p.ID])).
			fix("部品に \"material\" を書く（metal・stone・wood・cloth… か none）", checkres.Try{Op: "set material", Arg: sp.Name + "." + p.ID, Try: "none"})
		v.Sprite = sp.Name
		out = append(out, v)
	}
	return out
}

// fidelityDecl は fidelity の不明・機種の方が細かい（門の画風から外れる）。
func fidelityDecl(f fidelityOf, slot string) []violation {
	switch {
	case !f.Known:
		return []violation{declViolation("fidelity-unknown", 0, checkres.WantEqual(1),
			fmt.Sprintf("%s の塗りの細かさ fidelity が門にも機種にも無い（全域の検査と kind の束で回した）", slot)).
			fix("色の門の画風に \"fidelity\"（0 low-bit 〜 1 hi-bit）を書く。free の冊は files に \"fidelity\"")}
	case f.Over != nil:
		return []violation{declViolation("fidelity-over", *f.Over, checkres.WantAtMost(f.Value),
			fmt.Sprintf("機種の fidelity %.2f が門の画風 %s の %.2f より細かい（門の画風から外れる）", *f.Over, f.Look, f.Value)).
			fix("機種（spec の style）を門の画風より粗い物にする")}
	}
	return nil
}

// lintSpriteDecl は sprite.json の lint-sprite の対象外に書いた知らない規則名（0.42.0 は advice・置き換えの案つき）。
func lintSpriteDecl(doc map[string]any, known map[string]bool) []violation {
	var out []violation
	check := func(where string, v any) {
		s, _ := v.(string)
		i, j := strings.Index(s, "("), strings.Index(s, ")")
		if !strings.Contains(s, "対象外") || i < 0 || j < i {
			return
		}
		for _, name := range strings.FieldsFunc(s[i+1:j], func(r rune) bool { return r == ',' || r == '、' || r == ' ' }) {
			if known[name] {
				continue
			}
			hint := "bin/fge sprite の規則名（orphan・connect・jaggy・banding・corner・silhouette・palette・structure）に直す"
			switch name {
			case "icon":
				hint = "対象外(icon) をやめて sprite に \"kind\": \"icon\" を書く"
			case "colors":
				hint = "colors は palette（色数の目安）"
			}
			v := declViolation("lint-sprite-unknown", 0, checkres.WantEqual(1), fmt.Sprintf("%s の lint-sprite に知らない規則名 %q（効いていない）", where, name)).fix(hint)
			out = append(out, v)
		}
	}
	check("(Doc)", doc["lint-sprite"])
	sprites, _ := doc["sprites"].(map[string]any)
	names := make([]string, 0, len(sprites))
	for n := range sprites {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		if so, ok := sprites[n].(map[string]any); ok {
			check(n, so["lint-sprite"])
		}
	}
	return out
}

// glowViolations は emissive の部品の発光の作法（依頼主の決定 案 C）: 芯（部品の最明色）はコマの glowCoreMaxShare 以下・
// 部品の平均の明るさはまわり（emissive の外）より emissiveMinGap 以上明るい（暗い emissive は light-dir を逃げる道になる）。
func glowViolations(g *pxlib.Grid, c *checkCtx) []violation {
	if len(c.Emissive) == 0 {
		return nil
	}
	op := g.Opaque()
	total := op.Count()
	if total == 0 {
		return nil
	}
	type acc struct {
		sum  float64
		n    int
		top  pxlib.Key
		topL float64
		cnt  map[pxlib.Key]int
		at   pxlib.Pt
	}
	parts := map[string]*acc{}
	other, on := 0.0, 0
	for _, p := range op.Points() {
		k := g.At(p.X, p.Y)
		l, ok := pxlib.Lightness(c.HexOf[k])
		if !ok {
			continue
		}
		id := g.SrcAt(p.X, p.Y).Part
		if !c.Emissive[id] {
			other += l
			on++
			continue
		}
		a := parts[id]
		if a == nil {
			a = &acc{cnt: map[pxlib.Key]int{}, topL: -1, at: p}
			parts[id] = a
		}
		a.sum += l
		a.n++
		a.cnt[k]++
		if l > a.topL {
			a.top, a.topL = k, l
		}
	}
	var out []violation
	ids := make([]string, 0, len(parts))
	for id := range parts {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		a := parts[id]
		share := float64(a.cnt[a.top]) / float64(total)
		if share > c.Rules.GlowCoreMaxShare {
			v := newViolation(checkGlow, levelAdvice, share, checkres.WantAtMost(c.Rules.GlowCoreMaxShare),
				fmt.Sprintf("emissive の部品 %s の芯（最明色 %s）がコマの %.1f%%（芯は 1px〜小さく。輪は 25%% の網 1 段・照り返しは床に横長 3〜4 行）", id, a.top, share*100)).
				sub("core").at(a.at)
			out = append(out, v)
		}
		if on > 0 {
			gap := a.sum/float64(a.n) - other/float64(on)
			if gap < c.Rules.EmissiveMinGap {
				v := newViolation(checkGlow, levelAdvice, gap, checkres.WantAtLeast(c.Rules.EmissiveMinGap),
					fmt.Sprintf("emissive の部品 %s の平均の明るさがまわりより %.3f しか高くない（光らない物に emissive を付けると light-dir・pillow を外れる）", id, gap)).
					sub("dim").at(a.at).fix("光る物でなければ emissive を外す。光る物ならランプの上の段で塗る")
				out = append(out, v)
			}
		}
	}
	return out
}

// exemptOveruse は op ごとの Exempt で外した画素がコマあたり exemptPerFrameMax を超えた物（外しの使い過ぎ）。
func exemptOveruse(counts map[[2]string]int, frames, limit int) []violation {
	if frames == 0 {
		return nil
	}
	per := map[string]int{}
	for k, n := range counts {
		if k[0] != "demoted" {
			per[k[1]] += n
		}
	}
	ops := make([]string, 0, len(per))
	for op := range per {
		ops = append(ops, op)
	}
	sort.Strings(ops)
	var out []violation
	for _, op := range ops {
		avg := float64(per[op]) / float64(frames)
		if avg > float64(limit) {
			v := newViolation(checkExUse, levelAdvice, math.Round(avg*10)/10, checkres.WantAtMost(float64(limit)),
				fmt.Sprintf("%s の Exempt で外した画素がコマあたり %.1f（%d まで。作法の形の外まで外していないか）", op, avg, limit))
			v.Scope = checkres.ScopeSpec
			out = append(out, v)
		}
	}
	return out
}
