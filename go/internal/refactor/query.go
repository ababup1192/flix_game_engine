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

// Caller は参照する def 1 つと参照の数。
type Caller struct {
	Owner string `json:"owner"`
	Count int    `json:"count"`
	First string `json:"first"` // 最初の参照の file:line:col
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

// FieldSite は欄の直の読み書き 1 つ。
type FieldSite struct {
	Row
	Write bool   `json:"write"` // `{ x = v | e }`（false は `e#x`）
	Recv  string `json:"recv"`  // 受け手の型 alias（分からなければ ?・候補が複数なら A|B）
	Via   string `json:"via"`   // decl・row・ambiguous・open・none
}

// FieldQuery は field-sites の問い。
type FieldQuery struct {
	Label    string
	Receiver string // 空なら受け手を問わない
	Outside  string // 空でなければ、この mod の def の中の物を数えない（口の中の読み書き）
}

// FieldAnswer は field-sites の答え。Sites は受け手が当たった物、Unsure は受け手の型が分からない物
// （--receiver を付けた時だけ。型が分からない物と、候補が複数で決まらない ambiguous。当たっているかもしれないので並べる）、Inside は --outside の mod の中の物。
type FieldAnswer struct {
	Sites  []FieldSite
	Unsure []FieldSite
	Inside int
}

// FieldSites は欄 label の直の読み書き。
func FieldSites(rows []Row, q FieldQuery) FieldAnswer {
	var a FieldAnswer
	for _, r := range rows {
		if (r.Kind != KindLabelSelect && r.Kind != KindLabelUpdate) || r.Sym != q.Label {
			continue
		}
		s := FieldSite{Row: r, Write: r.Kind == KindLabelUpdate, Recv: r.Attr("recv"), Via: r.Attr("via")}
		matched := q.Receiver == ""
		unsure := false
		if !matched {
			candidate := false
			for _, cand := range strings.Split(s.Recv, "|") {
				if nameMatches(cand, q.Receiver) {
					candidate = true
				}
			}
			// 決まらない物（候補が複数の ambiguous・型の分からない ?）は数えず unsure へ（設計 §5-1）。
			matched = candidate && s.Via != "ambiguous"
			unsure = s.Recv == "?" || (candidate && s.Via == "ambiguous")
		}
		if !matched && !unsure {
			continue
		}
		if q.Outside != "" && inMod(r.Owner, q.Outside) {
			a.Inside++
			continue
		}
		if matched {
			a.Sites = append(a.Sites, s)
		} else {
			a.Unsure = append(a.Unsure, s)
		}
	}
	return a
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
