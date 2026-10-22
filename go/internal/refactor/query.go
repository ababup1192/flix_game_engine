package refactor

import (
	"fmt"
	"sort"
	"strings"
)

// 種類（索引の 1 列目）。
const (
	KindDefDecl       = "def-decl"
	KindDefUse        = "def-use"
	KindEnumDecl      = "enum-decl"
	KindCaseDecl      = "case-decl"
	KindCaseConstruct = "case-construct"
	KindCasePattern   = "case-pattern"
	KindMatchSite     = "match-site"
	KindLabelSelect   = "label-select"
	KindLabelUpdate   = "label-update"
)

var declKinds = map[string]bool{KindDefDecl: true, KindEnumDecl: true, KindCaseDecl: true}

var nameKinds = map[string]bool{KindDefDecl: true, KindDefUse: true, KindEnumDecl: true, KindCaseDecl: true, KindCaseConstruct: true, KindCasePattern: true}

// nameMatches は書かれた名前 q が索引の sym を指すか。sym は名前空間つき（`World.Phase.Clear`・
// パッケージの物は `$pkg$…` で始まる）なので、q と同じか「. + q」で終わる物を当てる。
func nameMatches(sym, q string) bool {
	return sym == q || strings.HasSuffix(sym, "."+q)
}

// Resolve は q が指す symbol を 1 つに決める（kinds の行の sym から）。0 個・2 個以上は誤り（候補を並べる）。
func Resolve(rows []Row, q string, kinds map[string]bool) (string, error) {
	found := map[string]bool{}
	for _, r := range rows {
		if kinds[r.Kind] && nameMatches(r.Sym, q) {
			found[r.Sym] = true
		}
	}
	syms := make([]string, 0, len(found))
	for s := range found {
		syms = append(syms, s)
	}
	sort.Strings(syms)
	switch len(syms) {
	case 0:
		return "", fmt.Errorf("%s という名前は索引にありません（def・enum・case の名前を Mod.name で）", q)
	case 1:
		return syms[0], nil
	}
	// 書いた通りの名前が在ればそれ（`World` と `X.World` の両方が在る時の `World`）。
	if found[q] {
		return q, nil
	}
	return "", fmt.Errorf("%s が %d 個の名前に当たります（もっと長く書いてください）: %s", q, len(syms), strings.Join(syms, "・"))
}

// RefsResult は refs の答え。
type RefsResult struct {
	Sym     string
	Decls   []Row
	Uses    []Row
	Callers []Caller // --callers の時だけ
}

// Refs は sym の宣言と参照（def なら呼び出し・case なら作る所と当てる所）。
func Refs(rows []Row, sym string, callers bool) RefsResult {
	res := RefsResult{Sym: sym}
	for _, r := range rows {
		if !nameKinds[r.Kind] || r.Sym != sym {
			continue
		}
		if declKinds[r.Kind] {
			res.Decls = append(res.Decls, r)
		} else {
			res.Uses = append(res.Uses, r)
		}
	}
	if callers {
		by := map[string]*Caller{}
		var order []string
		for _, u := range res.Uses {
			c, ok := by[u.Owner]
			if !ok {
				c = &Caller{Owner: u.Owner, First: u.Where()}
				by[u.Owner] = c
				order = append(order, u.Owner)
			}
			c.Count++
		}
		for _, o := range order {
			res.Callers = append(res.Callers, *by[o])
		}
		sort.SliceStable(res.Callers, func(i, j int) bool { return res.Callers[i].Owner < res.Callers[j].Owner })
	}
	return res
}

// MatchSite は match 1 つ。
type MatchSite struct {
	Row
	Arms  int  `json:"arms"`
	Wild  int  `json:"wild"`  // 一番上の型が `_` の腕
	Var   int  `json:"var"`   // 一番上の型が変数の腕
	Guard int  `json:"guard"` // 見張り（if）つきの腕
	Hits  int  `json:"hits"`  // case を名指しした時: その case を当てる型の数
	Deep  bool `json:"deep"`  // enum の case を当てているが、一番上の型は別（tuple の中など）
}

// CatchAll は残りを全部受ける腕（`_` か変数）を持つか。
func (m MatchSite) CatchAll() bool { return m.Wild+m.Var > 0 }

// MatchSites は enum（か case）への match。enum なら「一番上の型の case がその enum の match」と
// 「その enum の case を内側で当てる match（tuple の中など）」の両方、case ならその case を当てる match。
// 当てる型（case-pattern）は、それを含む一番内側の match に数える。
func MatchSites(rows []Row, sym string, isCase bool) []MatchSite {
	enumOf := sym
	if isCase {
		enumOf = ""
	}
	byFile := map[string][]int{} // ファイル → match-site の行の番号
	for i, r := range rows {
		if r.Kind == KindMatchSite {
			byFile[r.File] = append(byFile[r.File], i)
		}
	}
	sites := map[int]*MatchSite{}
	site := func(i int) *MatchSite {
		if s, ok := sites[i]; ok {
			return s
		}
		r := rows[i]
		s := &MatchSite{Row: r, Arms: r.AttrInt("arms"), Wild: r.AttrInt("wild"), Var: r.AttrInt("var"), Guard: r.AttrInt("guard")}
		sites[i] = s
		return s
	}
	if enumOf != "" {
		for _, idx := range byFile {
			for _, i := range idx {
				if rows[i].Attr("enum") == enumOf {
					site(i)
				}
			}
		}
	}
	for _, r := range rows {
		if r.Kind != KindCasePattern {
			continue
		}
		hit := (isCase && r.Sym == sym) || (!isCase && strings.HasPrefix(r.Sym, enumOf+".") && !strings.Contains(r.Sym[len(enumOf)+1:], "."))
		if !hit {
			continue
		}
		inner := -1
		for _, i := range byFile[r.File] {
			m := rows[i]
			if m.contains(r) && (inner < 0 || rows[inner].contains(m)) {
				inner = i
			}
		}
		if inner < 0 {
			continue // let・lambda の型の中（match の外）
		}
		s := site(inner)
		s.Hits++
		if !isCase && s.Attr("enum") != enumOf {
			s.Deep = true
		}
	}
	out := make([]MatchSite, 0, len(sites))
	for _, s := range sites {
		out = append(out, *s)
	}
	sort.Slice(out, func(i, j int) bool { return less(out[i].Row, out[j].Row) })
	return out
}

func less(a, b Row) bool {
	if a.File != b.File {
		return a.File < b.File
	}
	if a.Line != b.Line {
		return a.Line < b.Line
	}
	return a.Col < b.Col
}

// FieldSite は欄の直の読み書き 1 つ。受け手が何の値かは索引（flixlint の typed の段）の事実をそのまま持つ。
type FieldSite struct {
	Row
	Write  bool     `json:"write"`            // `{ x = v | e }`（false は `e#x`）
	Recv   string   `json:"owner"`            // alias:A・case:E.C[#i]・other・ambiguous・maybe・none
	Chain  []string `json:"chain,omitempty"`  // 書いた別名から鎖の終わりまで（報告だけに使う）
	Cands  []string `json:"cands,omitempty"`  // ambiguous・maybe の候補（*N は候補が多すぎて並べていない）
	Why    string   `json:"why"`              // decl・case・row・open・none（報告の内訳だけに使う）
	RSpan  string   `json:"rspan,omitempty"`  // 受け手の式の範囲 sl:sc:el:ec
	RParam int      `json:"rparam,omitempty"` // 受け手が最上位の def の引数そのものなら番号 + 1（0 は違う）
}

func fieldSiteOf(r Row) FieldSite {
	s := FieldSite{Row: r, Write: r.Kind == KindLabelUpdate, Recv: r.Attr("owner"), Why: r.Attr("why"), RSpan: r.Attr("rspan")}
	if c := r.Attr("chain"); c != "" {
		s.Chain = strings.Split(c, ",")
	}
	if c := r.Attr("cands"); c != "" {
		s.Cands = strings.Split(c, "|")
	}
	if p := r.Attr("rparam"); p != "" {
		s.RParam = r.AttrInt("rparam") + 1
	}
	return s
}

// OwnerText は報告に出す受け手の字（alias・case はその名前、ほかは owner の語と候補）。
func (s FieldSite) OwnerText() string {
	if len(s.Cands) > 0 {
		return s.Recv + "（" + strings.Join(s.Cands, "|") + "）"
	}
	return s.Recv
}

// FieldClass は問いの受け手に対する読み書き 1 つの分類。
type FieldClass string

const (
	ClassHit   FieldClass = "hit"   // 受け手が問いの alias・case と証明できた
	ClassMaybe FieldClass = "maybe" // 証明できないが、候補に問いの alias・case がある
	ClassMiss  FieldClass = "miss"  // 別の物と分かっている
)

// FieldAct は分類ごとに操作がすること。
type FieldAct string

const (
	ActCount   FieldAct = "count"   // 残っている読み書きに数える（残れば止める）
	ActList    FieldAct = "list"    // 場所を並べる
	ActUnsure  FieldAct = "unsure"  // 「たぶん」の欄に場所つきで並べる
	ActRewrite FieldAct = "rewrite" // 書き換える
	ActFix     FieldAct = "fix"     // 書き換えずに人へ回す
	ActSkip    FieldAct = "skip"    // 数えない・並べない
)

// FieldActs は操作ごとの扱いの表（設計 semantic-index-design §2.2）。索引は事実だけを言い、数えるか・止めるかはここで決める。
// WhyNot: 消す操作は maybe も数える。取りこぼすと消した後の確かめで落ちる（人は --skip で外す）。書く操作は証明できた所だけ書く。
var FieldActs = map[string]map[FieldClass]FieldAct{
	"remove-field":         {ClassHit: ActCount, ClassMaybe: ActCount, ClassMiss: ActSkip},
	"move-fields --finish": {ClassHit: ActCount, ClassMaybe: ActCount, ClassMiss: ActSkip},
	"field-sites":          {ClassHit: ActList, ClassMaybe: ActUnsure, ClassMiss: ActSkip},
	"usages":               {ClassHit: ActList, ClassMaybe: ActUnsure, ClassMiss: ActSkip},
	"field-to-accessor":    {ClassHit: ActRewrite, ClassMaybe: ActFix, ClassMiss: ActSkip},
}

// OwnerTarget は問いの受け手: alias（別名を鎖の終わりへ写した名前）か case（`#i` は書いた時だけ）。
type OwnerTarget struct {
	Alias string // alias:… の …
	Case  string // case:… の …（`#i` を含めてよい）
}

// AliasTarget は --receiver の字を alias の sym に決め、別名なら鎖の終わりへ写す（`Model = World` の Model は World）。
// 索引に alias-decl の行が無い・1 つに決まらない時は書いた字のまま（名前の終わりで当てる）。
func AliasTarget(rows []Row, q string) OwnerTarget {
	found := map[string]string{}
	for _, r := range rows {
		if r.Kind == KindAliasDecl && nameMatches(r.Sym, q) {
			end := r.Attr("syn")
			if end == "" {
				end = r.Sym
			}
			found[r.Sym] = end
		}
	}
	if end, ok := found[q]; ok {
		return OwnerTarget{Alias: end}
	}
	if len(found) == 1 {
		for _, end := range found {
			return OwnerTarget{Alias: end}
		}
	}
	return OwnerTarget{Alias: q}
}

func (t OwnerTarget) matches(owner string) bool {
	switch {
	case t.Alias != "":
		a, ok := strings.CutPrefix(owner, "alias:")
		return ok && nameMatches(a, t.Alias)
	case t.Case != "":
		c, ok := strings.CutPrefix(owner, "case:")
		if !ok {
			return false
		}
		if !strings.Contains(t.Case, "#") {
			c, _, _ = strings.Cut(c, "#")
		}
		return nameMatches(c, t.Case)
	}
	return false
}

// Class は読み書き s を問い t で分ける。t が空なら全部 hit（受け手を問わない）。
func (s FieldSite) Class(t OwnerTarget) FieldClass {
	if t == (OwnerTarget{}) || t.matches(s.Recv) {
		return ClassHit
	}
	if s.Recv == "maybe" || s.Recv == "ambiguous" {
		for _, c := range s.Cands {
			if strings.HasPrefix(c, "*") || t.matches(c) {
				return ClassMaybe
			}
		}
	}
	return ClassMiss
}

// FieldQuery は field-sites の問い。
type FieldQuery struct {
	Label    string
	Receiver string // 空なら受け手を問わない（Case も空の時）
	Case     string // case の payload の欄を問う時の case の名前（--case）
	Outside  string // 空でなければ、この mod の def の中の物を数えない（口の中の読み書き）
	Op       string // 扱いの表（FieldActs）の行。空なら field-sites
}

// FieldAnswer は field-sites の答え。Sites は表が list・count・rewrite と言う物、Unsure は unsure・fix と言う物
// （受け手が証明できないが当たっているかもしれない物）、Inside は --outside の mod の中の物。
type FieldAnswer struct {
	Sites  []FieldSite
	Unsure []FieldSite
	Inside int
}

// FieldSites は欄 label の直の読み書きを、索引の受け手の事実と扱いの表で分ける。
func FieldSites(rows []Row, q FieldQuery) FieldAnswer {
	var t OwnerTarget
	switch {
	case q.Case != "":
		t = OwnerTarget{Case: q.Case}
	case q.Receiver != "":
		t = AliasTarget(rows, q.Receiver)
	}
	op := q.Op
	if op == "" {
		op = "field-sites"
	}
	acts := FieldActs[op]
	var a FieldAnswer
	for _, r := range rows {
		if (r.Kind != KindLabelSelect && r.Kind != KindLabelUpdate) || r.Sym != q.Label {
			continue
		}
		s := fieldSiteOf(r)
		act := acts[s.Class(t)]
		if act == ActSkip || act == "" {
			continue
		}
		if q.Outside != "" && inMod(r.Owner, q.Outside) {
			a.Inside++
			continue
		}
		switch act {
		case ActUnsure, ActFix:
			a.Unsure = append(a.Unsure, s)
		default:
			a.Sites = append(a.Sites, s)
		}
	}
	return a
}

// WithoutSkipped は --skip file:line の行の読み書きを外した残りと、外した数（人が受け手を見て当たらないと決めた所。
// remove-field・move-fields --finish の「残っている読み書き」に効かせる。組み立ての --skip と同じ鍵）。
func WithoutSkipped(sites []FieldSite, skip map[string]bool) ([]FieldSite, int) {
	if len(skip) == 0 {
		return sites, 0
	}
	var kept []FieldSite
	for _, s := range sites {
		if !skip[fmt.Sprintf("%s:%d", s.File, s.Line)] {
			kept = append(kept, s)
		}
	}
	return kept, len(sites) - len(kept)
}

// inMod は def owner が mod（か、その下の mod）の中か。mod は名前の終わりで当てる（`World` は `$pkg$….World` にも当たる）。
func inMod(owner, mod string) bool {
	i := strings.LastIndex(owner, ".")
	if i < 0 {
		return false
	}
	m := owner[:i]
	return nameMatches(m, mod) || strings.HasPrefix(m, mod+".") || strings.Contains(m, "."+mod+".")
}
