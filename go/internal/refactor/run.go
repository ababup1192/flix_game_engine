package refactor

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

// Usage は使い方の全文。
const Usage = `使い方: fge refactor <操作> [引数] [--json] [-v|--verbose] [--all] [--max N] [--limit N] [--stage resolved|typed] [--rebuild] [--require-clean] [--flixlint PATH] [--root DIR]

  usages <Mod.f|Enum|Enum.Case|Alias> [--callers [--depth N]]
                                                       使われ所（Find Usages）: file:line:col・使う def・種類（呼び出し・参照・
                                                       組み立て・パターン・型の注記・use）。--callers は使う def に畳み、
                                                       --depth N で呼び手の呼び手まで（Call Hierarchy）
  usages <Alias>#<欄> | --label x [--receiver T]       record の欄の読み・書き・組み立て（typed の段）。同じ名前の欄が
                                                       別の型にもあれば候補を並べて止まる
  usages --unused                                      外から使われない pub の def（参照 0・テストからだけ・同じ mod の中だけ）と
                                                       使っていない use（読むだけ。消すのは remove-dead か手）
  refs <Mod.name> [--callers]                          def・enum・case の宣言と参照（--callers は参照する def ごと）
  match-sites <Enum|Enum.Case> [--catch-all]           match の位置・腕の数・` + "`_`" + `／変数の腕（--catch-all はそれを持つ物だけ）
  field-sites --label x [--receiver T] [--outside Mod] record の欄 x の直の読み（e#x）と書き（{ x = v | e }）
  index [--stage resolved|typed]                       索引を作る（か使い回す）だけ。種類ごとの行の数と秒
  expand-wildcard --enum E [--apply] [--skip file:line]  E への match の ` + "`case _ =>`" + `（使わない変数の腕も）を残りの case に書き出す
  remove-dead [--with-tests] [--only test-only|unreferenced] [--def Mod.name] [--apply] [--skip file:line]
                                                       テストからだけ・どこからも参照されない pub の def を ///・注記ごと消す
  field-to-accessor --label x[,y,…] --receiver T [--labels-file F] [--getter R] [--mapper M | --setter S] [--outside Mod] [--apply] [--skip file:line]
                                                       口の既定は T の mod の xOf（読み）と withX（書き）。索引に無ければ
                                                       T を宣言したファイルの既存の …Of の並びの後ろに作る（--reader は --getter と同じ）。
                                                       R・M・S は Mod.f でも f でもよい（呼ぶ所の mod が口の mod なら素の名前・外なら修飾つきで書く）。
                                                       欄を 2 つ以上渡すと、口は既定の名前で全部作り、1 つの patch・確かめ 1 回（落ちれば全部戻す）。
                                                       --apply で通れば最後の行に done: N sites → 残り left outside Mod。
                                                       受け手が T の欄 x の直の読み e#x を R(e) へ、書き { x = v | e } を
                                                       S(v, e)・M(x -> f(x), e)（v が e#x を読む時）・M(_ -> v, e) へ（typed の段）。
                                                       { x = v, y = u | e } は { y = u | S(v, e) } に。
                                                       R の戻りの型と欄の型が字で違えば読みは替えない。口の def の中は替えない
  remove-field --label x (--receiver T | --case E.C) [--apply] [--skip file:line]
                                                       record の型（alias T か enum の case E.C の record）から欄 x を消し、
                                                       組み立て（record の式）からも消す（typed の段）。欄の直の読み書きが
                                                       残っていれば場所を並べて止める（case の record は受け手が ? の物も数える）
  fix-construction --label x (--receiver T | --case E.C) [--value EXPR] [--apply] [--skip file:line]
                                                       組み立て（record の式）の欄を型に合わせる: 型に x があれば無い式へ
                                                       x = EXPR を足し、型に x が無ければある式から消す。式は欄の組で当てる
                                                       （型の別名を通した物も拾う・欄の組が同じ別の型があれば fix）

  出力は全部の操作で同じ形の数行: 当てた物 1 行・数 1 行・注 0〜3 行・結末（dry-run・applied・歯止め）1 行・
  場所の上位 10 行（書き換える操作は人へ回す所を先に）・ファイルごとの数・全部の置き場・終わりに next（写して流せる
  コマンド）。場所の全部は build/refactor/last-<操作>.txt。--all（か --limit N・0 は全部）で場所を画面に、--json で全部を JSON。
  -v・--verbose は今までの全文: got・want・status と索引の秒・場所の全部・索引を作る flixlint の出力・dry-run の diff・
  確かめの口の出力（既定ではそれぞれ build/refactor/index-<段>.log・last.diff・verify.log に書き、場所だけ言う）。
  根は --root（無ければ FGE_ROOT、無ければ今の所から上へ flix.toml を探す）。flixlint は根の flixlint/（submodule）から探す。
  依存（lib/）が無くて flixlint が止めた時は、道具は make を流さず next: make check を出す（依存を入れるのは flix）。

  書き換える操作は既定で dry-run（build/refactor/last.diff を書くだけ）。--apply で書き、確かめの口（refactor.json の
  verify・remove-dead は verifyTests）を流し、落ちたら書く前の中身へ戻す。書く前の中身はコミットしていない変更も
  含む今の中身で、道具が控える（build/refactor/before/<パス>。git の clean は要らない・--require-clean で求められる）。
  書いた後に別の手が同じファイルを変えていれば、その変更を消さないよう戻さずに revert-failed で知らせる。
  決められない所は書き換えず fix に並べる。
  ほかの操作は読むだけ（ファイルは書き換えない）。索引は build/refactor/spans-<段>.tsv（無いか古ければ bin/fge heavy の枠で作る）。
  refs・match-sites は resolved の段（速い）、field-sites は typed の段（型検査まで。遅い）。
  --max N を付けると数の歯止めになる（got が N を超えれば終了コード 1）。例: 欄の直の読み書きを口の mod の外で 0 に
    fge refactor field-sites --label scene --receiver World --outside World --max 0
  名前は終わりで当てる（Phase.Clear は World.Phase.Clear に当たる。2 つ以上に当たれば候補を出して止まる）。
  設定は bin/lint-rules/refactor.json（engine が配る）と refactor.local.json（flixlint・sources・verify・verifyTests・testDirs・library）。
  library（既定 auto: flix.toml に repository がある package）では remove-dead が pub の def を消さない（使う側が索引の外）。
  flixlint は 0.6.0 以上。確かめは sh -c で流す（Windows は make と同じく Git Bash か MSYS の sh が要る）。
  終了コード: 0 問題なし・1 --max を超えた／確かめが落ちて戻した（reverted）・2 呼び方か索引の誤り／断った（refused）・
  3 戻せないファイルが残った（revert-failed）。
  道具のテスト: cd go && go test ./internal/refactor。本物の flixlint と flix で書き換えて確かめる e2e は
  FGE_REFACTOR_E2E=1 FGE_FLIXLINT=<bin/flixlint> FLIX_JAR=<flix.jar> go test ./internal/refactor -run EndToEnd`

// Options は差し替えられる所（テストが索引の作り方と出力先を替える）。
type Options struct {
	Run    Runner
	Verify VerifyRunner
	Log    io.Writer
}

type args struct {
	op, target, label, receiver, outside, flixlint, stage string
	labelsFile                                            string // field-to-accessor の --labels-file
	callers, catchAll, rebuild, asJSON                    bool
	apply, withTests, unused, verbose                     bool
	requireClean                                          bool // --require-clean: 書き換えるファイルが git で clean な時だけ --apply
	depth                                                 int  // usages --depth（0 は指定なし）
	only                                                  string
	def                                                   string
	reader, mapper, setter                                string
	caseName, value                                       string
	skip                                                  map[string]bool
	max, limit                                            int // max < 0 は無し・limit 0 は全部
}

func parseArgs(rest []string) (args, error) {
	a := args{max: -1, limit: 10}
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
		case "--unused":
			a.unused = true
		case "--verbose", "-v":
			a.verbose = true
		case "--all":
			a.limit = 0
		case "--depth":
			var v string
			if v, err = value(&i, x); err == nil {
				n, convErr := strconv.Atoi(v)
				if convErr != nil || n < 1 {
					return a, fmt.Errorf("--depth には 1 以上の数を渡してください: %s", v)
				}
				a.depth = n
			}
		case "--catch-all":
			a.catchAll = true
		case "--apply":
			a.apply = true
		case "--require-clean":
			a.requireClean = true
		case "--with-tests":
			a.withTests = true
		case "--def":
			a.def, err = value(&i, x)
		case "--enum":
			a.target, err = value(&i, x)
		case "--only":
			a.only, err = value(&i, x)
			if err == nil && a.only != "test-only" && a.only != "unreferenced" {
				return a, fmt.Errorf("--only は test-only か unreferenced: %s", a.only)
			}
		case "--skip":
			var v string
			if v, err = value(&i, x); err == nil {
				if a.skip == nil {
					a.skip = map[string]bool{}
				}
				a.skip[v] = true
			}
		case "--rebuild":
			a.rebuild = true
		case "--label":
			a.label, err = value(&i, x)
		case "--labels-file":
			a.labelsFile, err = value(&i, x)
		case "--receiver":
			a.receiver, err = value(&i, x)
		case "--outside":
			a.outside, err = value(&i, x)
		case "--reader", "--getter":
			a.reader, err = value(&i, x)
		case "--mapper":
			a.mapper, err = value(&i, x)
		case "--setter":
			a.setter, err = value(&i, x)
		case "--case":
			a.caseName, err = value(&i, x)
		case "--value":
			a.value, err = value(&i, x)
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
	if a.verbose {
		a.limit = 0
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

// applyWith は書き換える操作の当て方（確かめの口 verify）。
func (a args) applyWith(verify string, o Options) Apply {
	return Apply{On: a.apply, RequireClean: a.requireClean, Verify: verify, Run: o.Verify}
}

// needs は操作に要る一番低い段（欄の読み書きと受け手の型を見る物だけ typed）。
func (a args) needs() Stage {
	if a.op == "field-sites" || a.op == "field-to-accessor" || a.op == "remove-field" {
		return Typed
	}
	if _, _, field := a.fieldTarget(); a.op == "usages" && field && !a.unused {
		return Typed
	}
	return Resolved
}

// preflight は索引を作る前に分かる止め所（索引を作らずに答える）。止めなければ msg は ""。
// remove-field で型から欄がもう無い（手で先に消した）時は、組み立てを合わせる fix-construction（resolved で足りる）へ回す。
// WhyNot: ここで止めないと、欄の読み書きが残ったまま型検査の通らないソースへ typed の索引を作りに行って落ちる。
func preflight(root string, a args, cfg Config) (msg, next, why string) {
	if a.op != "remove-field" || a.receiver == "" {
		return "", "", ""
	}
	srcs, err := loadSources(root, cfg)
	if err != nil {
		return "", "", ""
	}
	shape, err := FindAliasShape(srcs, a.receiver)
	if err != nil || shape.Has(a.label) {
		return "", "", ""
	}
	return fmt.Sprintf("型 %s（%s）に欄 %s がもう無い（先に手で消した）", shape.Name, shape.File, a.label),
		fmt.Sprintf("bin/fge refactor fix-construction --label %s --receiver %s", a.label, a.receiver),
		"組み立てから欄を消す。resolved の索引で足り、型検査が通らなくても作れる。残った欄の読み書きは make check の誤りの所を手で"
}

// stageOf は操作が要る段（--stage で上げられる）。
func (a args) stageOf() (Stage, error) {
	need := a.needs()
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
	case "expand-wildcard":
		if a.target == "" {
			fmt.Fprintln(errOut, "refactor expand-wildcard: --enum <Enum> が要ります（例 --enum World.Scene）")
			return 2
		}
	case "field-to-accessor":
		if (a.label == "" && a.labelsFile == "") || a.receiver == "" {
			fmt.Fprintln(errOut, "refactor field-to-accessor: --label <欄>（a,b,c か --labels-file で複数）・--receiver <型 alias> が要ります（例 --label replayClock --receiver World。口は既定で World.replayClockOf・World.withReplayClock を使い、無ければ作る）")
			return 2
		}
		if a.mapper != "" && a.setter != "" {
			fmt.Fprintln(errOut, "refactor field-to-accessor: 書きの口は --mapper か --setter のどちらか 1 つ")
			return 2
		}
	case "remove-field", "fix-construction":
		if a.label == "" || (a.receiver == "") == (a.caseName == "") {
			fmt.Fprintf(errOut, "refactor %s: --label <欄> と、--receiver <record の alias> か --case <Enum.Case> のどちらか 1 つが要ります（例 --label replayClock --receiver World）\n", a.op)
			return 2
		}
	case "usages":
		if !a.unused && a.target == "" && a.label == "" {
			fmt.Fprintln(errOut, "refactor usages: 名前を渡してください（例 refactor usages World.moveTo・refactor usages World#scene・refactor usages --unused）")
			return 2
		}
	case "index", "remove-dead":
	default:
		fmt.Fprintf(errOut, "refactor: 知らない操作 %s（usages・refs・match-sites・field-sites・index・expand-wildcard・remove-dead・field-to-accessor・remove-field・fix-construction）\n", a.op)
		return 2
	}
	if a.op != "field-to-accessor" && (strings.Contains(a.label, ",") || a.labelsFile != "") {
		fmt.Fprintf(errOut, "refactor %s: 欄は 1 つだけ（複数の欄を 1 回で渡せるのは field-to-accessor）\n", a.op)
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
	b := Builder{Root: root, Config: cfg, Flixlint: fl, FlixJar: FindFlixJar(root, fl, cfg), Run: o.Run, Log: o.Log, Rebuild: a.rebuild, Verbose: a.verbose}
	if b.Log == nil {
		b.Log = os.Stderr
	}
	if msg, next, why := preflight(root, a, cfg); msg != "" {
		fmt.Fprintf(errOut, "refactor %s: %s\nnext: %s\n  （%s）\n", a.op, msg, next, why)
		return 2
	}
	idx, err := b.Load(stage)
	var ie *IndexError
	if err != nil && errors.As(err, &ie) && ie.Compile && stage == Typed && a.needs() == Resolved {
		// 型の要らない操作が --stage typed で呼ばれ、型検査が通らない: resolved の索引で続ける。
		fmt.Fprintf(b.Log, "[refactor] typed の索引は型検査が通らないので作れない。%s は resolved で足りるので resolved で続けます\n", a.op)
		idx, err = b.Load(Resolved)
	}
	if err != nil {
		fmt.Fprintf(errOut, "refactor: %v\n", err)
		if errors.As(err, &ie) {
			switch {
			case ie.Next != "":
				fmt.Fprintf(errOut, "next: %s\n  （%s）\n", ie.Next, ie.NextWhy)
			case ie.NextWhy != "":
				fmt.Fprintf(errOut, "next: %s\n", ie.NextWhy)
			}
		}
		return 2
	}
	var rep report
	switch a.op {
	case "usages":
		rep, err = usagesReport(root, idx, a, cfg)
	case "refs":
		rep, err = refsReport(idx, a)
	case "match-sites":
		rep, err = matchReport(idx, a)
	case "field-sites":
		rep = fieldReport(idx, a)
	case "index":
		rep = indexReport(idx)
	case "expand-wildcard":
		rep, err = expandReport(root, idx, a, cfg, o)
	case "remove-dead":
		rep, err = deadReport(root, idx, a, cfg, o)
	case "field-to-accessor":
		rep, err = accessorReport(root, idx, a, cfg, o)
	case "remove-field":
		rep, err = removeFieldReport(root, idx, a, cfg, o)
	case "fix-construction":
		rep, err = fixConstructionReport(root, idx, a, cfg, o)
	}
	if err != nil {
		fmt.Fprintf(errOut, "refactor %s: %v\n", a.op, err)
		return 2
	}
	rep.Index = indexInfo{Stage: string(idx.Stage), Path: idx.Path, Cached: idx.Cached, Seconds: idx.Seconds, Rows: len(idx.Rows)}
	rep.finish(a)
	rep.saveList(b.Dir(), a)
	switch {
	case a.asJSON:
		out.Write(checkres.Compact(rep))
	case a.verbose:
		rep.text(out, a)
	default:
		out.WriteString(rep.brief(a).Text())
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
	Usage   *Target           `json:"usage,omitempty"` // usages が当てた物（種類と宣言の場所）
	Unsure  []FieldSite       `json:"unsure,omitempty"`
	Maybe   []UsageSite       `json:"maybe,omitempty"` // usages: 受け手の型が決まらない欄の読み書き（数えていない）
	Kinds   map[string]int    `json:"kinds,omitempty"`
	Index   indexInfo         `json:"index"`
	Next    string            `json:"next,omitempty"`
	NextWhy string            `json:"nextWhy,omitempty"` // next の訳（next は写してそのまま流せる命令だけ）
	Done    string            `json:"done,omitempty"`    // 当てた後の言い切りの 1 行（最後の行に出す。例 done: 36 sites → 0 left outside World · check ok）
	Outcome *Outcome          `json:"outcome,omitempty"` // 書き換える操作の結末（dry-run・applied・reverted・refused）
	Fix     []Fixed           `json:"fix,omitempty"`     // 書き換えずに人へ回した所と理由

	wantText string // want の行（書き換える操作）
	fixHint  string // 直し方の 1 行（書き換える操作）
	Exit     int    `json:"exit"`

	code     string
	got      int
	gotText  string
	lines    []string // 人向けの場所の行（--limit で切る。列はタブで区切ってよい）
	fixLines []string // 書き換えずに人へ回した所の行（lines より先に出す）
	listPath string   // 場所の行の全部を書いたファイル（切った時に言う）
	extra    []string // got の下に足す行
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
	if r.Outcome != nil {
		want, msg = 0, fmt.Sprintf("人へ回した所 %d（%s）", r.got, r.Outcome.State)
	} else if a.max >= 0 {
		want = float64(a.max)
		msg = fmt.Sprintf("%d 件（%d 件まで）", r.got, a.max)
	}
	res := checkres.New(r.code, 0, checkres.Measure{Got: float64(r.got), Want: checkres.WantAtMost(want)}, nil, msg)
	res.Scope = checkres.ScopeSpec
	res.Cause = checkres.Cause{Op: strings.TrimSpace(r.Op + " " + r.Target)}
	switch {
	case r.Outcome != nil:
		if r.fixHint != "" {
			res.Fix = checkres.Fix{Hint: r.fixHint}
		}
		switch r.Outcome.State {
		case StateReverted:
			r.Exit = 1
		case StateRevertFailed:
			r.Exit = 3
		case StateRefused:
			r.Exit = 2
		}
	case res.Status == checkres.Fail:
		res.Fix = checkres.Fix{Hint: "sites の場所を直して数を減らすか、増えてよい理由があれば --max を上げる"}
		r.Exit = 1
	}
	r.Results = append(r.Results, res)
}

// text は -v（--verbose）の全文: got・want・status（索引の秒）・fix・next・場所の全部・diff と確かめの出力。
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
		switch {
		case r.wantText != "":
			fmt.Fprintf(out, "  want:   %s\n", r.wantText)
		case a.max >= 0:
			fmt.Fprintf(out, "  want:   <= %d\n", a.max)
		default:
			fmt.Fprintln(out, "  want:   一覧だけ（--max N で歯止めにする）")
		}
		if r.Outcome != nil {
			fmt.Fprintf(out, "  status: %s · %s\n", r.Outcome.status(), idx)
		} else {
			fmt.Fprintf(out, "  status: %s · %s\n", res.Status, idx)
		}
		if res.Fix.Hint != "" {
			fmt.Fprintf(out, "  fix:    %s\n", res.Fix.Hint)
		}
	} else {
		fmt.Fprintf(out, "  status: %s\n", idx)
	}
	r.sites(a).Write(out, "    ", rel)
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
	if r.Outcome != nil {
		dumpFile(out, "diff", r.Outcome.Diff)
		dumpFile(out, "確かめの出力", r.Outcome.VerifyLog)
	}
	if r.Done != "" {
		fmt.Fprintln(out, r.Done)
	}
}

// sites は場所の行の全部（人へ回した所が先）を --limit で切る一覧。
func (r report) sites(a args) checkres.Sites {
	return checkres.Sites{Lines: append(append([]string{}, r.fixLines...), r.lines...), Limit: a.limit, Path: r.listPath}
}

// saveList は切って見せる時に、場所の行の全部を build/refactor/last-<操作>.txt に書く。
func (r *report) saveList(dir string, a args) {
	if a.asJSON {
		return
	}
	s := r.sites(a)
	s.Save(filepath.Join(dir, "last-"+r.Op+".txt"))
	r.listPath = s.Path
}

// brief は既定の短い答え（出力の約束: 当てた物 1 行・数 1 行・注 0〜3 行・結末 1 行・場所の上位・終わりに next）。
func (r report) brief(a args) checkres.Brief {
	head := r.Op
	if r.Usage != nil {
		head += " " + r.Usage.Sym + "（" + r.Usage.Kind
		if r.Usage.Decl != "" {
			head += "・" + r.Usage.Decl
		}
		head += "）"
	} else {
		if r.Target != "" {
			head += " " + r.Target
		}
		if r.Sym != "" && r.Sym != r.Target {
			head += "（" + r.Sym + "）"
		}
	}
	b := checkres.Brief{Head: head, Count: r.gotText, Notes: r.extra, Sites: r.sites(a), Next: r.Next, NextWhy: r.NextWhy, Done: r.Done, Shown: rel}
	switch {
	case r.Outcome != nil:
		b.State = strings.ReplaceAll(r.Outcome.status(), "\n          ", "\n  ")
	case a.max >= 0 && r.Exit == 1:
		b.State = fmt.Sprintf("fail: %d 件（--max %d を超えた）", r.got, a.max)
	case a.max >= 0:
		b.State = fmt.Sprintf("pass: %d 件（--max %d まで）", r.got, a.max)
	}
	if len(r.Results) > 0 && r.Results[0].Status != checkres.Pass {
		b.Fix = r.Results[0].Fix.Hint
	}
	return b
}

// dumpFile は --verbose の時に、ファイルに書いた物（diff・確かめの出力）を画面にも出す。
func dumpFile(out *strings.Builder, what, path string) {
	if path == "" {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return
	}
	fmt.Fprintf(out, "---- %s（%s）\n%s", what, rel(path), data)
	if data[len(data)-1] != '\n' {
		out.WriteString("\n")
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
			r.lines = append(r.lines, fmt.Sprintf("%s\t%d\t%s", c.Owner, c.Count, c.First))
		}
		r.Next, r.NextWhy = fmt.Sprintf("bin/fge refactor refs %s", a.target), "場所ごと"
	} else {
		for _, x := range all {
			r.lines = append(r.lines, fmt.Sprintf("%s\t%s\t%s", x.Where(), x.Kind, x.Owner))
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
		r.lines = append(r.lines, fmt.Sprintf("%s\t腕 %d%s\t%s", s.Where(), s.Arms, mark, s.Owner))
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
		r.lines = append(r.lines, fmt.Sprintf("%s\t%s\t%s\t%s", s.Where(), rw, s.Recv, s.Owner))
	}
	for _, s := range ans.Unsure {
		r.lines = append(r.lines, fmt.Sprintf("%s\t?\t%s\t%s（%s）", s.Where(), s.Recv, s.Owner, s.Via))
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
