package refactor

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Fixed は書き換えずに人へ回した 1 か所と理由。
type Fixed struct {
	Row
	Why string `json:"why"`
}

// Arm は match の腕 1 つ（索引の match-arm の行）。
type Arm struct {
	Row
	Pat   string // wild・var・tag・other
	At    Row    // 一番上の型の範囲
	Guard bool
	Full  bool // case の欄が全部 _ か変数（その case を全部受ける）
	Name  string
	Uses  bool
}

func armOf(r Row) (Arm, error) {
	at, err := spanOf(r.File, r.Attr("at"))
	if err != nil {
		return Arm{}, err
	}
	return Arm{Row: r, Pat: r.Attr("pat"), At: at, Guard: r.Attr("guard") == "1", Full: r.Attr("full") == "1",
		Name: r.Attr("name"), Uses: r.Attr("uses") == "1"}, nil
}

// ExpandPlan は expand-wildcard の計画。
type ExpandPlan struct {
	Edits []Edit
	Fix   []Fixed
	Sites int // `_`・変数の腕を持つ match の数（--skip を含む）
}

// caseInfo は enum の case 1 つ（宣言の順）。
type caseInfo struct {
	Sym   string
	Name  string
	Arity int
}

// PlanExpand は enum の match の `case _ =>`（使われない変数の腕も）を、上の腕が受けていない case に書き出す計画。
// 書き換えないで fix に回す物: 見張り（if）つきの腕・本体が束ねた変数を使う腕・宣言が索引に無い enum・
// 上の腕が全部の case を受けている（腕が要らない）・tuple の中で当てる match。
func PlanExpand(root string, rows []Row, enum string, skip map[string]bool) (ExpandPlan, error) {
	var plan ExpandPlan
	var cases []caseInfo
	for _, r := range rows {
		if r.Kind == KindCaseDecl && r.Owner == enum {
			cases = append(cases, caseInfo{Sym: r.Sym, Name: r.Sym[strings.LastIndex(r.Sym, ".")+1:], Arity: r.AttrInt("arity")})
		}
	}
	armsOf := map[string][]Arm{} // file + match=L:C → 腕（書いた順）
	for _, r := range rows {
		if r.Kind == "match-arm" {
			a, err := armOf(r)
			if err != nil {
				return plan, err
			}
			k := r.File + " " + r.Attr("match")
			armsOf[k] = append(armsOf[k], a)
		}
	}
	for k := range armsOf {
		as := armsOf[k]
		sort.Slice(as, func(i, j int) bool { return less(as[i].Row, as[j].Row) })
	}
	patterns := map[string][]Row{} // file → case-pattern（書かれた字の前の部分を写すため）
	for _, r := range rows {
		if r.Kind == KindCasePattern && r.Extra != "sugar" {
			patterns[r.File] = append(patterns[r.File], r)
		}
	}
	srcs := map[string]string{}
	read := func(f string) (string, error) {
		if s, ok := srcs[f]; ok {
			return s, nil
		}
		b, err := os.ReadFile(filepath.Join(root, f))
		if err != nil {
			return "", err
		}
		srcs[f] = string(b)
		return srcs[f], nil
	}
	for _, m := range MatchSites(rows, enum, false) {
		if !m.CatchAll() {
			continue
		}
		plan.Sites++
		if m.Deep {
			plan.Fix = append(plan.Fix, Fixed{m.Row, "tuple などの中で当てる match（一番上の型が別）"})
			continue
		}
		arms := armsOf[m.File+" "+fmt.Sprintf("%d:%d", m.Line, m.Col)]
		var catch *Arm
		covered := map[string]bool{}
		var qualified []Row
		for i := range arms {
			a := arms[i]
			if a.Pat == "tag" {
				for _, p := range patterns[a.File] {
					if a.At.contains(p) && p.Line == a.At.Line && p.Col == a.At.Col {
						qualified = append(qualified, p)
					}
				}
				if !a.Guard && a.Full {
					covered[a.Sym] = true
				}
				continue
			}
			if (a.Pat == "wild" || a.Pat == "var") && catch == nil {
				catch = &arms[i]
				if !a.Guard {
					break
				}
			}
		}
		if catch == nil {
			plan.Fix = append(plan.Fix, Fixed{m.Row, "`_`・変数の腕が見つからない（索引の match-arm が無い）"})
			continue
		}
		site := catch.Row
		switch {
		case skip[site.File+":"+fmt.Sprint(site.Line)] || skip[m.File+":"+fmt.Sprint(m.Line)]:
			plan.Fix = append(plan.Fix, Fixed{site, "--skip で外した"})
			continue
		case catch.Guard:
			plan.Fix = append(plan.Fix, Fixed{site, "見張り（if）つきの腕（書き出すと見張りの意味が変わる）"})
			continue
		case catch.Pat == "var" && catch.Uses:
			plan.Fix = append(plan.Fix, Fixed{site, fmt.Sprintf("本体が束ねた変数 %s を使う（case ごとに作り直す必要がある）", catch.Name)})
			continue
		case len(cases) == 0:
			plan.Fix = append(plan.Fix, Fixed{site, "enum の宣言が索引に無い（パッケージか標準の enum）"})
			continue
		}
		var rest []caseInfo
		for _, c := range cases {
			if !covered[c.Sym] {
				rest = append(rest, c)
			}
		}
		if len(rest) == 0 {
			plan.Fix = append(plan.Fix, Fixed{site, "上の腕が全部の case を受けている（この腕は要らない。手で消す）"})
			continue
		}
		src, err := read(site.File)
		if err != nil {
			return plan, err
		}
		prefix, err := qualifier(src, qualified, enum)
		if err != nil {
			return plan, err
		}
		armStart, armEnd, err := ByteRange(src, site)
		if err != nil {
			return plan, err
		}
		patStart, patEnd, err := ByteRange(src, catch.At)
		if err != nil {
			return plan, err
		}
		oldPat := src[patStart:patEnd]
		want := "_"
		if catch.Pat == "var" {
			want = catch.Name
		}
		lineHead := src[strings.LastIndex(src[:armStart], "\n")+1 : armStart]
		sep := " "
		if strings.TrimSpace(lineHead) == "" {
			sep = "\n" + lineHead
		}
		relStart, relEnd := patStart-armStart, patEnd-armStart
		pats := make([]string, len(rest))
		for i, c := range rest {
			pats[i] = prefix + c.Name
			if c.Arity > 0 {
				pats[i] += "(" + strings.TrimSuffix(strings.Repeat("_, ", c.Arity), ", ") + ")"
			}
		}
		plan.Edits = append(plan.Edits, Edit{
			File: site.File, Start: armStart, End: armEnd, Site: site,
			Check: []Want{{Span: catch.At, Text: want}},
			Make: func(cur string) (string, error) {
				if relEnd > len(cur) || cur[relStart:relEnd] != oldPat {
					return "", fmt.Errorf("腕の型の位置が合わない")
				}
				head, tail := cur[:relStart], cur[relEnd:]
				gap := len(tail) - len(strings.TrimLeft(tail, " "))
				body := strings.TrimLeft(tail, " ")
				copies := make([]string, len(pats))
				for i, p := range pats {
					pad := gap - (len(p) - len(oldPat))
					if pad < 1 {
						pad = 1
					}
					copies[i] = head + p + strings.Repeat(" ", pad) + body
				}
				return strings.Join(copies, sep), nil
			},
		})
	}
	sort.Slice(plan.Fix, func(i, j int) bool { return less(plan.Fix[i].Row, plan.Fix[j].Row) })
	return plan, nil
}

// qualifier は書き出す case の前に付ける字（`Phase.`・`World.Phase.` など）。同じ match の他の腕の書き方を写す。
// 他の腕が素の名前（use で入れた物）か、腕が無ければ、enum の名前を根から書く（use で入れていない case もあるため）。
func qualifier(src string, written []Row, enum string) (string, error) {
	short := enum[strings.LastIndex(enum, ".")+1:]
	for _, p := range written {
		text, err := SpanText(src, p)
		if err != nil {
			return "", err
		}
		name := p.Sym[strings.LastIndex(p.Sym, ".")+1:]
		pre := strings.TrimSuffix(text, name)
		if pre != text && strings.HasSuffix(pre, short+".") {
			return pre, nil
		}
	}
	if strings.HasPrefix(enum, "$") {
		return "", fmt.Errorf("パッケージの enum %s の書き方が決められない", enum)
	}
	return enum + ".", nil
}
