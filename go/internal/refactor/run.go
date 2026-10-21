package refactor

import (
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

// Usage は使い方の全文。
const Usage = `使い方: fge refactor <操作> [引数] [--json] [--max N] [--limit N] [--stage resolved|typed] [--rebuild] [--flixlint PATH] [--root DIR]

  refs <Mod.name> [--callers]                          def・enum・case の宣言と参照（--callers は参照する def ごと）
  match-sites <Enum|Enum.Case> [--catch-all]           match の位置・腕の数・` + "`_`" + `／変数の腕（--catch-all はそれを持つ物だけ）
  field-sites --label x [--receiver T] [--outside Mod] record の欄 x の直の読み（e#x）と書き（{ x = v | e }）
  index [--stage resolved|typed]                       索引を作る（か使い回す）だけ。種類ごとの行の数と秒

  読むだけ（ファイルは書き換えない）。索引は build/refactor/spans-<段>.tsv（無いか古ければ bin/fge heavy の枠で作る）。
  refs・match-sites は resolved の段（速い）、field-sites は typed の段（型検査まで。遅い）。
  --max N を付けると数の歯止めになる（got が N を超えれば終了コード 1）。例: 欄の直の読み書きを口の mod の外で 0 に
    fge refactor field-sites --label scene --receiver World --outside World --max 0
  名前は終わりで当てる（Phase.Clear は World.Phase.Clear に当たる。2 つ以上に当たれば候補を出して止まる）。
  設定は bin/lint-rules/refactor.json（engine が配る）と refactor.local.json（flixlint の場所・sources・verify）。`

// Options は差し替えられる所（テストが索引の作り方と出力先を替える）。
type Options struct {
	Run Runner
	Log io.Writer
}

type args struct {
	op, target, label, receiver, outside, flixlint, stage string
	callers, catchAll, rebuild, asJSON                    bool
	max, limit                                            int // max < 0 は無し・limit 0 は全部
}

func parseArgs(rest []string) (args, error) {
	a := args{max: -1, limit: 40}
	var pos []string
	value := func(i *int, name string) (string, error) {
		if *i+1 >= len(rest) {
			return "", fmt.Errorf("%s には値が要ります", name)
		}
		*i++
		return rest[*i], nil
	}
	for i := 0; i < len(rest); i++ {
		var err error
		switch x := rest[i]; x {
		case "--json":
			a.asJSON = true
		case "--callers":
			a.callers = true
		case "--catch-all":
			a.catchAll = true
		case "--rebuild":
			a.rebuild = true
		case "--label":
			a.label, err = value(&i, x)
		case "--receiver":
			a.receiver, err = value(&i, x)
		case "--outside":
			a.outside, err = value(&i, x)
		case "--flixlint":
			a.flixlint, err = value(&i, x)
		case "--stage":
			a.stage, err = value(&i, x)
		case "--max", "--limit":
			var v string
			if v, err = value(&i, x); err == nil {
				n, convErr := strconv.Atoi(v)
				if convErr != nil || n < 0 {
					return a, fmt.Errorf("%s には 0 以上の数を渡してください: %s", x, v)
				}
				if x == "--max" {
					a.max = n
				} else {
					a.limit = n
				}
			}
		default:
			if strings.HasPrefix(x, "--") {
				return a, fmt.Errorf("知らない旗 %s", x)
			}
			pos = append(pos, x)
		}
		if err != nil {
			return a, err
		}
	}
	if len(pos) == 0 {
		return a, fmt.Errorf("操作がありません")
	}
	a.op = pos[0]
	if len(pos) > 1 {
		a.target = pos[1]
	}
	if len(pos) > 2 {
		return a, fmt.Errorf("引数が多すぎます: %s", strings.Join(pos[2:], " "))
	}
	return a, nil
}

// stageOf は操作が要る段（--stage で上げられる）。
func (a args) stageOf() (Stage, error) {
	need := Resolved
	if a.op == "field-sites" {
		need = Typed
	}
	switch Stage(a.stage) {
	case "":
		return need, nil
	case Typed:
		return Typed, nil
	case Resolved:
		if need == Typed {
			return "", fmt.Errorf("%s は typed の段が要ります（--stage resolved では欄の行がありません）", a.op)
		}
		return Resolved, nil
	}
	return "", fmt.Errorf("知らない段 %s（resolved か typed）", a.stage)
}

// Run は fge refactor の入口。終了コード: 0 問題なし・1 --max を超えた・2 呼び方か索引の誤り。
func Run(out, errOut *strings.Builder, root string, rest []string, o Options) int {
	if len(rest) == 0 || rest[0] == "--help" || rest[0] == "-h" || rest[0] == "help" {
		fmt.Fprintln(out, Usage)
		if len(rest) == 0 {
			return 2
		}
		return 0
	}
	a, err := parseArgs(rest)
	if err != nil {
		fmt.Fprintf(errOut, "refactor: %v\n\n%s\n", err, Usage)
		return 2
	}
	switch a.op {
	case "refs", "match-sites":
		if a.target == "" {
			fmt.Fprintf(errOut, "refactor %s: 名前を渡してください（例 refactor %s World.Scene）\n", a.op, a.op)
			return 2
		}
	case "field-sites":
		if a.label == "" {
			fmt.Fprintln(errOut, "refactor field-sites: --label <欄の名前> が要ります")
			return 2
		}
	case "index":
	default:
		fmt.Fprintf(errOut, "refactor: 知らない操作 %s（refs・match-sites・field-sites・index。段 1 で expand-wildcard・remove-dead）\n", a.op)
		return 2
	}
	stage, err := a.stageOf()
	if err != nil {
		fmt.Fprintf(errOut, "refactor: %v\n", err)
		return 2
	}
	cfg, err := LoadConfig(root)
	if err != nil {
		fmt.Fprintf(errOut, "refactor: %v\n", err)
		return 2
	}
	fl, err := FindFlixlint(root, a.flixlint, cfg)
	if err != nil {
		fmt.Fprintf(errOut, "refactor: %v\n", err)
		return 2
	}
	b := Builder{Root: root, Config: cfg, Flixlint: fl, FlixJar: FindFlixJar(root, fl, cfg), Run: o.Run, Log: o.Log, Rebuild: a.rebuild}
	if b.Log == nil {
		b.Log = os.Stderr
	}
	idx, err := b.Load(stage)
	if err != nil {
		fmt.Fprintf(errOut, "refactor: %v\n", err)
		return 2
	}
	var rep report
	switch a.op {
	case "refs":
		rep, err = refsReport(idx, a)
	case "match-sites":
		rep, err = matchReport(idx, a)
	case "field-sites":
		rep = fieldReport(idx, a)
	case "index":
		rep = indexReport(idx)
	}
	if err != nil {
		fmt.Fprintf(errOut, "refactor %s: %v\n", a.op, err)
		return 2
	}
	rep.Index = indexInfo{Stage: string(idx.Stage), Path: idx.Path, Cached: idx.Cached, Seconds: idx.Seconds, Rows: len(idx.Rows)}
	rep.finish(a)
	if a.asJSON {
		out.Write(checkres.Compact(rep))
	} else {
		rep.text(out, a)
	}
	return rep.Exit
}

// report は 1 回の答え（--json の形）。results は checkres の 1 件（数と基準）、sites は場所の全部。
type report struct {
	Op      string            `json:"op"`
	Target  string            `json:"target,omitempty"`
	Sym     string            `json:"sym,omitempty"`
	Results []checkres.Result `json:"results"`
	Sites   any               `json:"sites"`
	Callers []Caller          `json:"callers,omitempty"`
	Unsure  []FieldSite       `json:"unsure,omitempty"`
	Kinds   map[string]int    `json:"kinds,omitempty"`
	Index   indexInfo         `json:"index"`
	Next    string            `json:"next,omitempty"`
	NextWhy string            `json:"nextWhy,omitempty"` // next の訳（next は写してそのまま流せる命令だけ）
	Exit    int               `json:"exit"`

	code    string
	got     int
	gotText string
	lines   []string // 人向けの場所の行（--limit で切る）
	extra   []string // got の下に足す行
}

type indexInfo struct {
	Stage   string  `json:"stage"`
	Path    string  `json:"path"`
	Cached  bool    `json:"cached"`
	Seconds float64 `json:"seconds"`
	Rows    int     `json:"rows"`
}

// finish は数と基準から results・exit を決める。--max が無ければ基準は got そのもの（一覧だけ・いつも pass）。
func (r *report) finish(a args) {
	r.Results = []checkres.Result{}
	if r.code == "" {
		return
	}
	want := float64(r.got)
	msg := "一覧だけ（--max N で歯止めにする）"
	if a.max >= 0 {
		want = float64(a.max)
		msg = fmt.Sprintf("%d 件（%d 件まで）", r.got, a.max)
	}
	res := checkres.New(r.code, 0, checkres.Measure{Got: float64(r.got), Want: checkres.WantAtMost(want)}, nil, msg)
	res.Scope = checkres.ScopeSpec
	res.Cause = checkres.Cause{Op: strings.TrimSpace(r.Op + " " + r.Target)}
	if res.Status == checkres.Fail {
		res.Fix = checkres.Fix{Hint: "sites の場所を直して数を減らすか、増えてよい理由があれば --max を上げる"}
		r.Exit = 1
	}
	r.Results = append(r.Results, res)
}

func (r report) text(out *strings.Builder, a args) {
	head := "refactor " + r.Op
	if r.Target != "" {
		head += ": " + r.Target
	}
	if r.Sym != "" && r.Sym != r.Target {
		head += "（" + r.Sym + "）"
	}
	fmt.Fprintln(out, head)
	fmt.Fprintf(out, "  got:    %s\n", r.gotText)
	for _, e := range r.extra {
		fmt.Fprintf(out, "          %s\n", e)
	}
	idx := fmt.Sprintf("索引 %s: ", r.Index.Stage)
	if r.Index.Cached {
		idx += fmt.Sprintf("使い回し（作った時 %.1f s）", r.Index.Seconds)
	} else {
		idx += fmt.Sprintf("作った（%.1f s・%d 行）", r.Index.Seconds, r.Index.Rows)
	}
	if len(r.Results) > 0 {
		res := r.Results[0]
		if a.max >= 0 {
			fmt.Fprintf(out, "  want:   <= %d\n", a.max)
		} else {
			fmt.Fprintln(out, "  want:   一覧だけ（--max N で歯止めにする）")
		}
		fmt.Fprintf(out, "  status: %s · %s\n", res.Status, idx)
		if res.Fix.Hint != "" {
			fmt.Fprintf(out, "  fix:    %s\n", res.Fix.Hint)
		}
	} else {
		fmt.Fprintf(out, "  status: %s\n", idx)
	}
	if r.Next != "" {
		fmt.Fprintf(out, "  next:   %s\n", r.Next)
	}
	if r.NextWhy != "" {
		if r.Next == "" {
			fmt.Fprintf(out, "  next:   %s\n", r.NextWhy)
		} else {
			fmt.Fprintf(out, "          （%s）\n", r.NextWhy)
		}
	}
	shown := r.lines
	if a.limit > 0 && len(shown) > a.limit {
		shown = shown[:a.limit]
	}
	for _, l := range shown {
		fmt.Fprintf(out, "    %s\n", l)
	}
	if len(shown) < len(r.lines) {
		fmt.Fprintf(out, "    …ほか %d 件（--limit 0 で全部・--json）\n", len(r.lines)-len(shown))
	}
}

// split は場所を src・test・ほかに数える。
func split(rows []Row) string {
	files := map[string]bool{}
	src, test, other := 0, 0, 0
	for _, r := range rows {
		files[r.File] = true
		switch {
		case strings.HasPrefix(r.File, "src/"):
			src++
		case strings.HasPrefix(r.File, "test/"):
			test++
		default:
			other++
		}
	}
	s := fmt.Sprintf("%d ファイル・src %d・test %d", len(files), src, test)
	if other > 0 {
		s += fmt.Sprintf("・ほか %d", other)
	}
	return s
}

func refsReport(idx *Index, a args) (report, error) {
	sym, err := Resolve(idx.Rows, a.target, nameKinds)
	if err != nil {
		return report{}, err
	}
	res := Refs(idx.Rows, sym, a.callers)
	r := report{Op: "refs", Target: a.target, Sym: sym, code: CodeRefs, got: len(res.Uses)}
	all := append(append([]Row{}, res.Decls...), res.Uses...)
	r.Sites = all
	decl := "宣言 0（パッケージか標準の物）"
	if len(res.Decls) > 0 {
		decl = fmt.Sprintf("宣言 %d（%s）", len(res.Decls), res.Decls[0].Where())
	}
	r.gotText = fmt.Sprintf("参照 %d（%s）・%s", len(res.Uses), split(res.Uses), decl)
	sugar := 0
	for _, u := range res.Uses {
		if u.Extra == "sugar" {
			sugar++
		}
	}
	if sugar > 0 {
		r.extra = append(r.extra, fmt.Sprintf("うち構文が指す物 %d（`a :: b` の List.Cons・`a %% b` など。名前は書かれていないので書き換えの外）", sugar))
	}
	if kinds := countKinds(res.Uses); strings.Contains(kinds, "・") {
		r.extra = append(r.extra, "種類: "+kinds)
	}
	if a.callers {
		r.Callers = res.Callers
		r.extra = append(r.extra, fmt.Sprintf("参照する def %d", len(res.Callers)))
		for _, c := range res.Callers {
			r.lines = append(r.lines, fmt.Sprintf("%-48s %3d  %s", c.Owner, c.Count, c.First))
		}
		r.Next, r.NextWhy = fmt.Sprintf("bin/fge refactor refs %s", a.target), "場所ごと"
	} else {
		for _, x := range all {
			r.lines = append(r.lines, fmt.Sprintf("%-44s %-15s %s", x.Where(), x.Kind, x.Owner))
		}
		r.Next, r.NextWhy = fmt.Sprintf("bin/fge refactor refs %s --callers", a.target), "参照する def ごと"
	}
	return r, nil
}

func countKinds(rows []Row) string {
	n := map[string]int{}
	for _, r := range rows {
		n[r.Kind]++
	}
	keys := make([]string, 0, len(n))
	for k := range n {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s %d", k, n[k]))
	}
	return strings.Join(parts, "・")
}

// matchTargets は match-sites が当てられる名前: 宣言された enum・case と、match と型に出てくる enum・case
// （パッケージや標準の enum は宣言の行が無い）。
func matchTargets(rows []Row) []Row {
	var out []Row
	seen := map[string]bool{}
	add := func(kind, sym string) {
		if sym != "" && sym != "-" && !seen[kind+" "+sym] {
			seen[kind+" "+sym] = true
			out = append(out, Row{Kind: kind, Sym: sym})
		}
	}
	for _, r := range rows {
		switch r.Kind {
		case KindEnumDecl:
			add(KindEnumDecl, r.Sym)
		case KindCaseDecl, KindCasePattern:
			add(KindCaseDecl, r.Sym)
		case KindMatchSite:
			add(KindEnumDecl, r.Attr("enum"))
		}
	}
	return out
}

func matchReport(idx *Index, a args) (report, error) {
	targets := matchTargets(idx.Rows)
	sym, err := Resolve(targets, a.target, map[string]bool{KindEnumDecl: true, KindCaseDecl: true})
	if err != nil {
		return report{}, err
	}
	isCase := false
	for _, t := range targets {
		if t.Sym == sym && t.Kind == KindCaseDecl {
			isCase = true
		}
	}
	sites := MatchSites(idx.Rows, sym, isCase)
	catchAll, deep := 0, 0
	for _, s := range sites {
		if s.CatchAll() {
			catchAll++
		}
		if s.Deep {
			deep++
		}
	}
	shown := sites
	if a.catchAll {
		shown = nil
		for _, s := range sites {
			if s.CatchAll() {
				shown = append(shown, s)
			}
		}
	}
	r := report{Op: "match-sites", Target: a.target, Sym: sym, code: CodeMatchSites, got: len(shown)}
	if shown == nil {
		shown = []MatchSite{}
	}
	r.Sites = shown
	rows := make([]Row, len(shown))
	for i, s := range shown {
		rows[i] = s.Row
	}
	what := "match"
	if a.catchAll {
		what = "`_`・変数の腕を持つ match"
	}
	r.gotText = fmt.Sprintf("%s %d（%s）", what, len(shown), split(rows))
	if isCase {
		r.extra = append(r.extra, fmt.Sprintf("この case を当てる match・全 %d のうち `_`・変数の腕を持つ物 %d", len(sites), catchAll))
	} else {
		r.extra = append(r.extra, fmt.Sprintf("全 %d のうち `_`・変数の腕を持つ物 %d・内側で当てる物（tuple の中など）%d", len(sites), catchAll, deep))
	}
	for _, s := range shown {
		mark := ""
		if s.CatchAll() {
			mark = fmt.Sprintf("  catch-all(_ %d・変数 %d)", s.Wild, s.Var)
		}
		if s.Deep {
			mark += "  内側"
		}
		if s.Guard > 0 {
			mark += fmt.Sprintf("  if %d", s.Guard)
		}
		r.lines = append(r.lines, fmt.Sprintf("%-44s 腕 %2d%s  %s", s.Where(), s.Arms, mark, s.Owner))
	}
	switch {
	case !a.catchAll && catchAll > 0:
		r.Next, r.NextWhy = fmt.Sprintf("bin/fge refactor match-sites %s --catch-all", a.target), "段 1 の expand-wildcard が書き出す所"
	case a.catchAll && catchAll > 0:
		r.NextWhy = "段 1 の expand-wildcard で `case _` を残りの case に書き出す（今は手で）"
	}
	return r, nil
}

func fieldReport(idx *Index, a args) report {
	q := FieldQuery{Label: a.label, Receiver: a.receiver, Outside: a.outside}
	ans := FieldSites(idx.Rows, q)
	target := "#" + a.label
	if a.receiver != "" {
		target = a.receiver + target
	}
	r := report{Op: "field-sites", Target: target, code: CodeFieldSites, got: len(ans.Sites)}
	if ans.Sites == nil {
		ans.Sites = []FieldSite{}
	}
	r.Sites = ans.Sites
	r.Unsure = ans.Unsure
	reads, writes := 0, 0
	via := map[string]int{}
	rows := make([]Row, len(ans.Sites))
	for i, s := range ans.Sites {
		rows[i] = s.Row
		if s.Write {
			writes++
		} else {
			reads++
		}
		via[s.Via]++
	}
	r.gotText = fmt.Sprintf("直の読み書き %d（読み %d・書き %d・%s）", len(ans.Sites), reads, writes, split(rows))
	if a.outside != "" {
		r.gotText = fmt.Sprintf("%s の外の", a.outside) + r.gotText
		r.extra = append(r.extra, fmt.Sprintf("%s の中（口）の物 %d は数えない", a.outside, ans.Inside))
	}
	if len(via) > 0 {
		var parts []string
		for _, k := range []string{"decl", "row", "ambiguous"} {
			if via[k] > 0 {
				parts = append(parts, fmt.Sprintf("%s %d", k, via[k]))
			}
		}
		r.extra = append(r.extra, "受け手の分かり方: "+strings.Join(parts, "・")+"（decl は書いた型・row は欄の組が 1 つの alias と同じ）")
	}
	if len(ans.Unsure) > 0 {
		r.extra = append(r.extra, fmt.Sprintf("受け手の型が決まらない物 %d（数えていない。開いた row・別の record・欄の組が同じ alias が複数の ambiguous。unsure に並べた）", len(ans.Unsure)))
	}
	for _, s := range ans.Sites {
		rw := "読み"
		if s.Write {
			rw = "書き"
		}
		r.lines = append(r.lines, fmt.Sprintf("%-44s %s  %-20s %s", s.Where(), rw, s.Recv, s.Owner))
	}
	for _, s := range ans.Unsure {
		r.lines = append(r.lines, fmt.Sprintf("%-44s ?     %-20s %s（%s）", s.Where(), s.Recv, s.Owner, s.Via))
	}
	if len(ans.Sites) > 0 && a.max < 0 && a.outside == "" && a.receiver != "" {
		mod := a.receiver
		r.Next, r.NextWhy = fmt.Sprintf("bin/fge refactor field-sites --label %s --receiver %s --outside %s --max 0", a.label, a.receiver, mod), "口の外を 0 にする歯止め（--outside は口の mod）"
	}
	return r
}

func indexReport(idx *Index) report {
	r := report{Op: "index", Kinds: map[string]int{}, Sites: []Row{}}
	for _, row := range idx.Rows {
		r.Kinds[row.Kind]++
	}
	r.gotText = fmt.Sprintf("%d 行（%s）", len(idx.Rows), countKinds(idx.Rows))
	r.lines = append(r.lines, idx.Path)
	return r
}
