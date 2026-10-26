package px

// 直し方の数の候補（fix.try）: 違反の原因の op（か同じスプライトの部品）の引数を、今の値から試す値へ。
// 試した後の got が見込める物だけ expect を書く（見込めない物は書かない）。build だけが付ける（px check は spec を持たない）。

import (
	"math"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flixlint/go/checkres"
)

// argNow は op の引数の今の値（書いていなければ op の既定）。
func argNow(call opCall, name string) any {
	if v, ok := call.Args.v[name]; ok {
		return v
	}
	if call.Args.op != nil {
		for _, p := range call.Args.op.Params {
			if p.Name == name {
				return p.Default
			}
		}
	}
	return nil
}

func numOf(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int:
		return float64(n), true
	}
	return 0, false
}

// opAt は違反の原因の op の呼び出し（部品 id と番号で引く。無ければ ok=false）。
func opAt(parts []*part, v violation) (opCall, string, bool) {
	for _, p := range parts {
		if p.ID == v.Op.Part && v.Op.Index >= 0 && v.Op.Index < len(p.Ops) {
			return p.Ops[v.Op.Index], p.ID, true
		}
	}
	return opCall{}, "", false
}

// opsNamed は部品の中の名前が name の op（部品 id.ops[番号] の字面と呼び出し）。
func opsNamed(parts []*part, name string) (refs []string, calls []opCall) {
	for _, p := range parts {
		for i, c := range p.Ops {
			if c.Name == name {
				refs = append(refs, pxlib.OpRef{Part: p.ID, Index: i, Op: name}.String())
				calls = append(calls, c)
			}
		}
	}
	return refs, calls
}

// triesFor は違反 1 件に付ける数の候補（parts はそのスプライトの 1 コマ目の部品）。
func triesFor(v violation, parts []*part) []checkres.Try {
	var out []checkres.Try
	call, _, hasOp := opAt(parts, v)
	ref := v.Op.String()
	switch v.Check {
	case checkPillow:
		if hasOp && call.Name == "sel_out" {
			out = append(out, checkres.Try{Op: ref, Arg: "lit_drop", Now: argNow(call, "lit_drop"), Try: 0})
		}
		if hasOp && (call.Name == "shade_step" || call.Name == "shade_parts") {
			out = append(out, checkres.Try{Op: ref, Arg: "op", Now: call.Name, Try: "directional"})
		}
	case checkSeam:
		refs, calls := opsNamed(parts, "scatter_clusters")
		for i, c := range calls {
			if w, _ := argNow(c, "wrap").(bool); !w {
				out = append(out, checkres.Try{Op: refs[i], Arg: "wrap", Now: false, Try: true})
			}
		}
	case checkValueSep:
		refs, calls := opsNamed(parts, "depth_fade")
		for i, c := range calls {
			if d, ok := numOf(argNow(c, "depth")); ok && d < 1 {
				out = append(out, checkres.Try{Op: refs[i], Arg: "depth", Now: d, Try: math.Min(1, math.Round((d+0.15)*100)/100)})
			}
		}
	case checkAnim:
		if v.Sub == "bob" || v.Sub == "area" || v.Sub == "pop" {
			refs, calls := opsNamed(parts, "sway")
			for i, c := range calls {
				if a, ok := numOf(argNow(c, "amp")); ok && math.Abs(a) > 0.5 {
					out = append(out, checkres.Try{Op: refs[i], Arg: "amp", Now: a, Try: math.Round(a/2*10) / 10})
				}
			}
		}
	case checkGroundContrast:
		if hasOp && (call.Name == "directional" || call.Name == "gradient_fill") {
			if v.Want.Op == checkres.AtLeast && len(v.Fix) > 0 && containsDark(v.Fix) {
				out = append(out, checkres.Try{Op: ref, Arg: "from", Now: argNow(call, "from"), Try: 0})
			}
		}
	}
	return out
}

// containsDark は ground-contrast の直し方が「外周が地より暗い」向きか。
func containsDark(fix string) bool {
	const dark = "外周が地より暗い"
	return len(fix) >= len(dark) && fix[:len(dark)] == dark
}
