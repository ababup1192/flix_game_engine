package refactor

import (
	"fmt"
	"sort"
	"strings"
)

// 索引の param の行（最上位の def の引数。flixlint 0.8.7 から adds=param）と alias-decl の fields=（adds=alias-fields）を引く口。
// 型の比べは「名前 1 つの型を引いた sym どうし」だけ（設計 semantic-index-design §2.3 の J4）: 型の字はどちらも shim が作る
// 正規の形（修飾つき・alias は名前のまま・空白なし）なので、別名（syn=）を鎖の終わりへ写してから字で比べる。
// 型の変数を含む物（poly=1・`?`）は比べない。

// KindParam は def の引数の行。
const KindParam = "param"

// MinFlixlintParam は param・aparam・alias の fields= を書く一番古い flixlint の版。
const MinFlixlintParam = "0.8.7"

// addsSince は adds= の名前ごとに、それを書く一番古い flixlint の版（設計 M3: 版の定数は adds ごとに 1 つ）。
var addsSince = map[string]string{
	"param":        MinFlixlintParam,
	"aparam":       MinFlixlintParam,
	"alias-fields": MinFlixlintParam,
}

// paramInfo は param の行 1 つを読んだ物。
type paramInfo struct {
	Row    Row
	I      int
	Name   string
	Type   string // 正規の形（`Kit.Res`・`{a=Int32|?}`）
	Reads  int    // 本体がこの引数を読む所の数
	Hidden bool   // 名前が _ で始まる
	Poly   bool   // 型に型の変数がある（比べない）
	Fields map[string]string
	Open   bool // record の型が開いている（row の変数で終わる）
}

func readParam(r Row) paramInfo {
	return paramInfo{Row: r, I: r.AttrInt("i"), Name: r.Attr("name"), Type: r.Attr("type"), Reads: r.AttrInt("reads"),
		Hidden: r.Attr("hidden") == "1", Poly: r.Attr("poly") == "1", Fields: parseFields(r.Attr("fields")), Open: r.Attr("row") == "open"}
}

// parseFields は `a:T;b:U` を欄 → 型にする。
func parseFields(s string) map[string]string {
	if s == "" {
		return nil
	}
	out := map[string]string{}
	for _, f := range strings.Split(s, ";") {
		if l, t, ok := strings.Cut(f, ":"); ok {
			out[l] = t
		}
	}
	return out
}

// paramIndex は def → 引数（順番どおり）。
type paramIndex map[string][]paramInfo

func newParamIndex(rows []Row) paramIndex {
	out := paramIndex{}
	for _, r := range rows {
		if r.Kind == KindParam {
			out[r.Sym] = append(out[r.Sym], readParam(r))
		}
	}
	for _, ps := range out {
		sort.Slice(ps, func(i, j int) bool { return ps[i].I < ps[j].I })
	}
	return out
}

// named は def の名前 n の引数（無ければ false）。
func (pix paramIndex) named(def, n string) (paramInfo, bool) {
	for _, p := range pix[def] {
		if p.Name == n {
			return p, true
		}
	}
	return paramInfo{}, false
}

// typeIndex は型の名前の表: alias の別名の鎖の終わり（syn=）と alias の欄（fields=）。
type typeIndex struct {
	syn    map[string]string
	fields map[string]map[string]string
	open   map[string]bool
	decls  map[string]Row // 型の宣言（alias-decl・enum-decl）の sym → 行
	uses   []Row
}

func newTypeIndex(rows []Row) *typeIndex {
	t := &typeIndex{syn: map[string]string{}, fields: map[string]map[string]string{}, open: map[string]bool{}, decls: map[string]Row{}}
	for _, r := range rows {
		switch r.Kind {
		case KindAliasDecl:
			if s := r.Attr("syn"); s != "" {
				t.syn[r.Sym] = s
			}
			if f := parseFields(r.Attr("fields")); f != nil {
				t.fields[r.Sym] = f
			}
			t.open[r.Sym] = r.Attr("row") == "open"
			t.decls[r.Sym] = r
		case KindEnumDecl:
			t.decls[r.Sym] = r
		case KindUse:
			t.uses = append(t.uses, r)
		}
	}
	return t
}

// end は型の字 typ が名前 1 つの alias の別名なら鎖の終わり（ほかはそのまま）。
func (t *typeIndex) end(typ string) string {
	if e, ok := t.syn[typ]; ok {
		return e
	}
	return typ
}

// singleName は型の字が名前 1 つ（型引数・record・tuple・関数・型の変数を含まない）か。
func singleName(typ string) bool {
	return typ != "" && !strings.ContainsAny(typ, "[]{}()?|->\\ ,")
}

// same は正規の形の型の字 a・b が同じ型か（どちらも型の変数を含まず、別名を鎖の終わりへ写して同じ）。
func (t *typeIndex) same(a, b string) bool {
	if a == "" || b == "" || strings.Contains(a+b, "?") {
		return false
	}
	if singleName(a) && singleName(b) {
		return t.end(a) == t.end(b)
	}
	return a == b
}

// resolveIn は人が書いた型の名前 name（`Res`・`Kit.Res`）を、file の mod の中で引いた正規の名前にする（設計 M2）。
// 引き方は Flix と同じ順: その mod の use の別名（索引の use の owner が mod の物だけ。ファイルの根の def は owner "" の use だけ）
// → 同じ mod の宣言 → 修飾名そのもの・根の宣言。標準の型（Int32 など）は宣言が無いので名前のまま。どこにも宣言が無ければ
// 名前のまま、在るのに引けなければ候補を並べて止める。答えは別名を鎖の終わりへ写した名前。
// WhyNot: 同じファイルの別の mod の use は見ない（`mod A { use X.Res }` は隣の `mod B` の Res を変えない。レビュー 2a の中-1）。
// 親の mod の宣言もたどらない（`mod A.B` の中の素の Res は A.Res を引かない。flixlint で E2916 を確かめた）。
func (t *typeIndex) resolveIn(name, file, mod string) (string, error) {
	name = strings.TrimSpace(name)
	if !singleName(name) {
		return "", fmt.Errorf("型 %s は名前 1 つでない（型引数・record・関数の型は比べない。人へ）", name)
	}
	head, rest, qualified := strings.Cut(name, ".")
	var hit string
	for _, u := range t.uses {
		if hit != "" || u.File != file || u.Owner != mod {
			continue
		}
		if u.Attr("alias") == name {
			if _, ok := t.decls[u.Sym]; ok {
				hit = u.Sym
			}
		} else if qualified && u.Attr("alias") == head && u.Attr("what") == "module" {
			if _, ok := t.decls[u.Sym+"."+rest]; ok {
				hit = u.Sym + "." + rest
			}
		}
	}
	if hit == "" && mod != "" {
		if _, ok := t.decls[mod+"."+name]; ok {
			hit = mod + "." + name
		}
	}
	if hit == "" {
		if _, ok := t.decls[name]; ok {
			hit = name
		}
	}
	if hit == "" {
		var cands []string
		for s := range t.decls {
			if nameMatches(s, name) {
				cands = append(cands, s)
			}
		}
		if len(cands) > 0 {
			sort.Strings(cands)
			return "", fmt.Errorf("型 %s を %s（mod %s）で引けない（候補: %s。修飾して書く）", name, file, mod, strings.Join(cands, "・"))
		}
		return name, nil
	}
	return t.end(hit), nil
}

// fieldsOf は正規の形の型 typ の欄（record の alias なら alias-decl の fields=）。
func (t *typeIndex) fieldsOf(typ string) map[string]string {
	return t.fields[t.end(typ)]
}

// paramRef は def の i 番目の引数（読みが減る所を数える鍵）。
type paramRef struct {
	Def string
	I   int
}

// requiredAdds は操作が読む adds= の名前（それを書く flixlint が要る）。
// WhyNot: 古い索引を読む道は持たない（決め 2）。要る操作だけを止め、ほかの操作は古い flixlint のまま使える（設計 M3）。
func (a args) requiredAdds() []string {
	switch a.op {
	case "change-signature":
		if a.retarget != "" {
			return []string{"param", "aparam", "alias-fields"}
		}
		return []string{"param", "aparam"}
	case "remove-param":
		return []string{"param", "aparam"}
	case "retarget-field":
		return []string{"param", "aparam", "alias-fields"}
	}
	return nil
}

// minFlixlintFor は adds の名前の列に要る一番新しい flixlint の版（無ければ MinFlixlint）。
func minFlixlintFor(adds []string) string {
	min := MinFlixlint
	for _, a := range adds {
		if v := addsSince[a]; v != "" && !versionAtLeast("flixlint "+min, v) {
			min = v
		}
	}
	return min
}

// argRowsByPlace は def を呼ぶ所の arg の行を「file L:C i」（呼ぶ名前の始まりと引数の番号）で引く表。
func argRowsByPlace(rows []Row) map[string]Row {
	out := map[string]Row{}
	for _, r := range rows {
		if r.Kind == KindArg && r.Attr("of") == KindDefUse {
			out[r.File+" "+r.Attr("at")+" "+r.Attr("i")] = r
		}
	}
	return out
}

// freedFixes は、計画が読みを減らす引数（dropped: 呼ぶ所で捨てる引数が呼び手の引数そのもの・freed: 読み替え）のうち、
// 読む所が全部消えるのに宣言に残る物の fix（Flix は使わない引数を誤りにし、確かめが落ちて全部戻る。レビュー 3 の R2・K2）。
// removedIn はこの計画が宣言から外す引数（def → 名前）。_ で始まる引数は Flix が問わないので見ない。
func freedFixes(rows []Row, removedIn map[string]map[string]bool, dropped, freed map[paramRef]int) []Fixed {
	if len(dropped) == 0 && len(freed) == 0 {
		return nil
	}
	pix := newParamIndex(rows)
	refs := map[paramRef]bool{}
	for r := range dropped {
		refs[r] = true
	}
	for r := range freed {
		refs[r] = true
	}
	var out []Fixed
	for ref := range refs {
		var p *paramInfo
		for i := range pix[ref.Def] {
			if pix[ref.Def][i].I == ref.I {
				p = &pix[ref.Def][i]
			}
		}
		n := dropped[ref] + freed[ref]
		if p == nil || p.Hidden || p.Reads == 0 || n < p.Reads || removedIn[ref.Def][p.Name] {
			continue
		}
		hint := fmt.Sprintf("呼び手の %s も外す必要がある（連なりを 1 回で外すのは段 2b の remove-param --cascade。今は %s の %s を本体で使うか、dry-run の diff に手で足す）", p.Name, ref.Def, p.Name)
		if dropped[ref] == 0 {
			hint = fmt.Sprintf("--params から %s を外す（retarget-field なら --drop-from）か、%s を本体で残す", p.Name, p.Name)
		}
		out = append(out, Fixed{p.Row, fmt.Sprintf("引数 %s を読む所が全部消える（読む所 %d・呼ぶ所で捨てる %d・読み替え %d）。Flix は使わない引数を誤りにするので書かない。%s",
			p.Name, p.Reads, dropped[ref], freed[ref], hint)})
	}
	return sortedFixed(out)
}
