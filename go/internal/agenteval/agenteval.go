// Package agenteval は「何も教えていないエージェントが、お題に対して正しい道具を選べるか」を測る。
//
// お題（tasks の JSON）ごとに `claude -p` を 1 本走らせ、実装はさせずに「使う道具と読んだファイル」を
// 答えさせる。答えの文に期待する語（expect の正規表現）がいくつ出たか、出たら減点の語（avoid）が
// いくつ出たかで点を付け、使ったトークン・ターン数・読んだファイル数と一緒に表にする。
//
// 生の記録（stream-json）は <out>/<label>/<id>.jsonl に残すので、正規表現を直したら
// --rescore で claude を呼び直さずに点だけ付け直せる。前後の表は --compare。
package agenteval

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Pattern は答えの文に当てる正規表現 1 つ。why は外れたときに表へ出す一言。
type Pattern struct {
	Re  string `json:"re"`
	Why string `json:"why"`
}

// Task は 1 つのお題。prompt は依頼の言葉だけにして、道具の名前を入れない。
type Task struct {
	ID     string    `json:"id"`
	Prompt string    `json:"prompt"`
	Expect []Pattern `json:"expect"`
	Avoid  []Pattern `json:"avoid"`
	Note   string    `json:"note"`
}

// Suite はお題の JSON 1 枚（エンジン共通・ゲーム固有で分けて置く）。
type Suite struct {
	Version int    `json:"version"`
	Note    string `json:"note"`
	Tasks   []Task `json:"tasks"`
	name    string
}

// Result は 1 つのお題を 1 回走らせた結果。
type Result struct {
	ID           string   `json:"id"`
	Suite        string   `json:"suite"`
	Hit          int      `json:"hit"`
	Want         int      `json:"want"`
	Penalty      int      `json:"penalty"`
	Missed       []string `json:"missed"`
	AvoidHits    []string `json:"avoidHits"`
	InputTokens  int      `json:"inputTokens"`
	OutputTokens int      `json:"outputTokens"`
	CostUSD      float64  `json:"costUSD"`
	Turns        int      `json:"turns"`
	FilesRead    []string `json:"filesRead"`
	ToolCalls    int      `json:"toolCalls"`
	Seconds      float64  `json:"seconds"`
	Answer       string   `json:"answer"`
	Err          string   `json:"err,omitempty"`
}

// Points は 0..100 の点。期待の語の当たりから、減点の語 1 つにつき 1 つ分を引く。
func (r Result) Points() int {
	if r.Want == 0 {
		if r.Penalty > 0 {
			return 0
		}
		return 100
	}
	p := (r.Hit - r.Penalty) * 100 / r.Want
	if p < 0 {
		return 0
	}
	return p
}

// 答えの頼み方。お題の後ろに必ず付ける。
//
// WhyNot: お題の JSON ごとに変えられるようにしないのは、言い方が違うと前後・ゲーム間で
// 点が比べられなくなるため。
const suffix = "。実装はせず、使う道具（API・make の口・lint・スキル）と、判断のために読んだファイルを JSON で答えて"

// 走らせる claude が使ってよい道具。読むだけに絞る。
//
// WhyNot: Agent を外すのは、サブエージェントの読み物は親の記録に出ず、
// 読んだファイル数とトークンが数えられなくなるため。
var allowedTools = "Read,Grep,Glob,Skill,Bash(make api:*),Bash(make src:*),Bash(make help),Bash(grep:*),Bash(rg:*),Bash(ls:*),Bash(head:*),Bash(tail:*),Bash(sed -n:*),Bash(find:*),Bash(cat:*),Bash(wc:*)"
var disallowedTools = "Edit,Write,NotebookEdit,Agent"

// Run はサブコマンドの入口。
func Run(out, errOut io.Writer, args []string) (int, error) {
	opt, err := parseArgs(args)
	if err != nil {
		return 2, err
	}
	switch {
	case opt.help:
		fmt.Fprint(out, usage)
		return 0, nil
	case len(opt.compare) == 2:
		return compare(out, opt)
	}
	suites, err := loadSuites(opt.tasks)
	if err != nil {
		return 2, err
	}
	jobs := selectJobs(suites, opt.only)
	if len(jobs) == 0 {
		return 2, errors.New("走らせるお題がありません（--tasks と --only を見直す）")
	}
	dir := filepath.Join(opt.out, opt.label)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return 2, err
	}
	var results []Result
	if opt.rescore {
		results, err = rescore(dir, jobs)
		if err != nil {
			return 2, err
		}
	} else {
		results = runAll(errOut, dir, jobs, opt)
	}
	if err := writeSummary(dir, results); err != nil {
		return 2, err
	}
	writeTable(out, results)
	fmt.Fprintf(out, "\n記録: %s（summary.json・table.md・お題ごとの .jsonl）\n", dir)
	return 0, nil
}

const usage = `fge agent-eval — 何も教えていないエージェントがお題に正しい道具を選べるかを測る

  fge agent-eval --tasks <お題.json> [--tasks <お題.json>...] [--label 名前] [--only id,id] [--jobs 3]
                 [--max-turns 15] [--model 名前] [--add-dir DIR] [--out debug/agent-eval]
  fge agent-eval --tasks ... --label 名前 --rescore   claude を呼ばず、残した記録に点だけ付け直す
  fge agent-eval --compare 前の名前 後の名前 [--out debug/agent-eval]   前後の表

お題の形: {"version":1,"note":"…","tasks":[{"id":"…","prompt":"依頼の言葉（道具の名前を入れない）",
  "expect":[{"re":"ZStack\\.topLayer","why":"…"}],"avoid":[{"re":"let _ =","why":"…"}]}]}
点 = (期待の語の当たり − 減点の語の当たり) / 期待の語の数 × 100。答えの文だけに当てる。
走らせる claude は読むだけの道具に絞る（Edit・Write・Agent なし）。それ以外は使う人の設定（~/.claude・
プロジェクトのフック・権限のモード）のまま走る —— 実際に使う環境で測るため。engine を読ませるなら --add-dir <engine>。
1 お題 10 分で打ち切る。重いので何本も流すときは鍵を通す。
`

type options struct {
	tasks    []string
	only     map[string]bool
	label    string
	out      string
	jobs     int
	maxTurns int
	model    string
	claude   string
	addDirs  []string
	rescore  bool
	help     bool
	compare  []string
}

func parseArgs(args []string) (options, error) {
	o := options{out: "debug/agent-eval", jobs: 3, maxTurns: 15, claude: "claude",
		label: time.Now().Format("20060102-150405")}
	next := func(i *int, name string) (string, error) {
		if *i+1 >= len(args) {
			return "", fmt.Errorf("%s の後に値がありません", name)
		}
		*i++
		return args[*i], nil
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		var v string
		var err error
		switch a {
		case "-h", "--help":
			o.help = true
		case "--rescore":
			o.rescore = true
		case "--tasks", "--only", "--label", "--out", "--jobs", "--max-turns", "--model", "--claude", "--add-dir":
			if v, err = next(&i, a); err != nil {
				return o, err
			}
			switch a {
			case "--tasks":
				o.tasks = append(o.tasks, v)
			case "--only":
				o.only = map[string]bool{}
				for _, id := range strings.Split(v, ",") {
					if id = strings.TrimSpace(id); id != "" {
						o.only[id] = true
					}
				}
			case "--label":
				o.label = v
			case "--out":
				o.out = v
			case "--model":
				o.model = v
			case "--claude":
				o.claude = v
			case "--add-dir":
				o.addDirs = append(o.addDirs, v)
			case "--jobs", "--max-turns":
				n, convErr := strconv.Atoi(v)
				if convErr != nil || n < 1 {
					return o, fmt.Errorf("%s は 1 以上の数: %q", a, v)
				}
				if a == "--jobs" {
					o.jobs = n
				} else {
					o.maxTurns = n
				}
			}
		case "--compare":
			for k := 0; k < 2; k++ {
				if v, err = next(&i, a); err != nil {
					return o, errors.New("--compare には前と後の 2 つの名前を渡す")
				}
				o.compare = append(o.compare, v)
			}
		default:
			return o, fmt.Errorf("知らない引数: %s（--help）", a)
		}
	}
	if !o.help && len(o.compare) == 0 && len(o.tasks) == 0 {
		return o, errors.New("--tasks でお題の JSON を 1 つ以上渡す（--help）")
	}
	return o, nil
}

func loadSuites(paths []string) ([]Suite, error) {
	var suites []Suite
	seen := map[string]string{}
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			return nil, err
		}
		var s Suite
		if err := json.Unmarshal(data, &s); err != nil {
			return nil, fmt.Errorf("%s: %v", p, err)
		}
		s.name = strings.TrimSuffix(filepath.Base(p), ".json")
		for _, t := range s.Tasks {
			if prev, dup := seen[t.ID]; dup {
				return nil, fmt.Errorf("お題の id %q が %s と %s の両方にあります（記録のファイル名が重なる）", t.ID, prev, p)
			}
			seen[t.ID] = p
		}
		for _, t := range s.Tasks {
			for _, pat := range append(append([]Pattern{}, t.Expect...), t.Avoid...) {
				if _, err := regexp.Compile(pat.Re); err != nil {
					return nil, fmt.Errorf("%s の %s: 正規表現 %q が読めない: %v", p, t.ID, pat.Re, err)
				}
			}
		}
		suites = append(suites, s)
	}
	return suites, nil
}

type job struct {
	suite string
	task  Task
}

func selectJobs(suites []Suite, only map[string]bool) []job {
	var jobs []job
	for _, s := range suites {
		for _, t := range s.Tasks {
			if only == nil || only[t.ID] {
				jobs = append(jobs, job{s.name, t})
			}
		}
	}
	return jobs
}

func runAll(errOut io.Writer, dir string, jobs []job, opt options) []Result {
	results := make([]Result, len(jobs))
	sem := make(chan struct{}, opt.jobs)
	var wg sync.WaitGroup
	var mu sync.Mutex
	for i, j := range jobs {
		wg.Add(1)
		go func(i int, j job) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			r := runOne(dir, j, opt)
			results[i] = r
			mu.Lock()
			// WhyNot: errOut（main が最後にまとめて出す）へ書かないのは、数分かかる間に
			// 何も出ないと止まったのか走っているのか見分けられないため。
			fmt.Fprintf(os.Stderr, "[agent-eval] %-28s %3d 点  %4.0f 秒%s\n", j.task.ID, r.Points(), r.Seconds, errNote(r))
			mu.Unlock()
		}(i, j)
	}
	wg.Wait()
	return results
}

func errNote(r Result) string {
	if r.Err == "" {
		return ""
	}
	return "  （失敗: " + r.Err + "）"
}

func runOne(dir string, j job, opt options) Result {
	start := time.Now()
	args := []string{"-p", j.task.Prompt + suffix,
		"--output-format", "stream-json", "--verbose",
		"--max-turns", strconv.Itoa(opt.maxTurns),
		"--allowedTools", allowedTools,
		"--disallowedTools", disallowedTools}
	if opt.model != "" {
		args = append(args, "--model", opt.model)
	}
	for _, d := range opt.addDirs {
		args = append(args, "--add-dir", d)
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, opt.claude, args...)
	cmd.Stdin = nil
	raw, runErr := cmd.Output()
	var exitErr *exec.ExitError
	if errors.As(runErr, &exitErr) && len(exitErr.Stderr) > 0 {
		runErr = fmt.Errorf("%v: %s", runErr, lastLine(string(exitErr.Stderr)))
	}
	logPath := filepath.Join(dir, j.task.ID+".jsonl")
	writeErr := os.WriteFile(logPath, raw, 0o644)
	r := score(j, raw)
	r.Seconds = time.Since(start).Seconds()
	switch {
	case runErr != nil && r.Answer == "":
		r.Err = runErr.Error()
	case writeErr != nil:
		r.Err = writeErr.Error()
	}
	return r
}

// timeout は 1 つのお題の上限。止まった claude で全体が待ち続けないように。
const timeout = 10 * time.Minute

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return lines[len(lines)-1]
}

func rescore(dir string, jobs []job) ([]Result, error) {
	var results []Result
	for _, j := range jobs {
		raw, err := os.ReadFile(filepath.Join(dir, j.task.ID+".jsonl"))
		if err != nil {
			return nil, fmt.Errorf("%s の記録が無い（先に走らせる）: %v", j.task.ID, err)
		}
		results = append(results, score(j, raw))
	}
	return results, nil
}

// streamLine は stream-json の 1 行のうち、数えるのに要る所だけ。
type streamLine struct {
	Type    string `json:"type"`
	Message struct {
		Content []struct {
			Type  string          `json:"type"`
			Name  string          `json:"name"`
			Input json.RawMessage `json:"input"`
		} `json:"content"`
	} `json:"message"`
	Result   string  `json:"result"`
	NumTurns int     `json:"num_turns"`
	CostUSD  float64 `json:"total_cost_usd"`
	IsError  bool    `json:"is_error"`
	Subtype  string  `json:"subtype"`
	Usage    struct {
		Input       int `json:"input_tokens"`
		CacheCreate int `json:"cache_creation_input_tokens"`
		CacheRead   int `json:"cache_read_input_tokens"`
		Output      int `json:"output_tokens"`
	} `json:"usage"`
}

// fileArg は Bash の引数のうちファイルの名前に見える物（拡張子つき・Makefile）。
var fileArg = regexp.MustCompile(`[\w./~$-]*\w\.(md|flix|json|mk|py|txt)\b|\bMakefile\b`)

// score は記録 1 本から点と数を出す。
func score(j job, raw []byte) Result {
	r := Result{ID: j.task.ID, Suite: j.suite, Want: len(j.task.Expect)}
	files := map[string]bool{}
	sc := bufio.NewScanner(strings.NewReader(string(raw)))
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		var l streamLine
		if json.Unmarshal(sc.Bytes(), &l) != nil {
			continue
		}
		switch l.Type {
		case "assistant":
			for _, c := range l.Message.Content {
				if c.Type != "tool_use" {
					continue
				}
				r.ToolCalls++
				var in struct {
					FilePath string `json:"file_path"`
					Command  string `json:"command"`
				}
				if json.Unmarshal(c.Input, &in) != nil {
					continue
				}
				if c.Name == "Read" && in.FilePath != "" {
					files[filepath.Base(in.FilePath)] = true
				}
				// Bash の cat・sed・grep で読んだファイルも数える（名前の形をした引数だけ）。
				for _, m := range fileArg.FindAllString(in.Command, -1) {
					files[filepath.Base(m)] = true
				}
			}
		case "result":
			r.Answer = l.Result
			r.Turns = l.NumTurns
			r.CostUSD = l.CostUSD
			// 入力はキャッシュから読んだ分も含めて数える（毎回読まれる AGENTS.md の重さが見えるように）。
			r.InputTokens = l.Usage.Input + l.Usage.CacheCreate + l.Usage.CacheRead
			r.OutputTokens = l.Usage.Output
			if l.IsError {
				r.Err = l.Subtype
			}
		}
	}
	for f := range files {
		r.FilesRead = append(r.FilesRead, f)
	}
	sort.Strings(r.FilesRead)
	for _, p := range j.task.Expect {
		if regexp.MustCompile(p.Re).MatchString(r.Answer) {
			r.Hit++
		} else {
			r.Missed = append(r.Missed, label(p))
		}
	}
	for _, p := range j.task.Avoid {
		if adopted(regexp.MustCompile(p.Re), r.Answer) {
			r.Penalty++
			r.AvoidHits = append(r.AvoidHits, label(p))
		}
	}
	return r
}

// 「let _ = は使わない」のように打ち消して触れた行は減点しない。
// 「ない」1 字では見ない（「できない」「足りない」の行で減点が全部消えるため）。
var negation = regexp.MustCompile(`(使わ|呼ば|書か|足さ|置か|頼ら|し)ない|使わず|避け|禁止|NG|消え|止ま|止め|代わりに|古い|非推奨|(?i)\b(not|don't|avoid|instead|catch(es)?|lint|forbid|z-table|value-discard)\b`)

// avoidKey は「使わない物」を並べる JSON の鍵（"avoid": [...]・"使わない": {...}）。語ごとに見る。
var avoidKey = regexp.MustCompile(`(?i)^(avoid\w*|dont\w*|do_not\w*|not\w*|forbid\w*|deprecated|ng|old\w*|legacy|anti\w*|pitfalls?|使わない.*|避ける.*|やらない.*|しない.*|禁止.*|古い.*|非推奨.*)$`)

var keyOpen = regexp.MustCompile(`^"([^"]+)"\s*:\s*([\[{])`)

// adopted は、打ち消しの無い行に re が出たか（= その書き方を選んだか）。
// 「使わない物」の鍵の下（JSON の配列・オブジェクト。1 行で閉じる配列も）に並べた行も打ち消しとして読む。
func adopted(re *regexp.Regexp, answer string) bool {
	var stack []bool
	inAvoid := func() bool {
		for _, k := range stack {
			if k {
				return true
			}
		}
		return false
	}
	for _, line := range strings.Split(answer, "\n") {
		t := strings.TrimSpace(line)
		lineAvoid := false
		if m := keyOpen.FindStringSubmatch(t); m != nil {
			lineAvoid = avoidKey.MatchString(m[1])
		}
		hit := re.MatchString(line) && !negation.MatchString(line) && !inAvoid() && !lineAvoid
		if hit {
			return true
		}
		// 行の中の括弧の開け閉めで、鍵の文脈を積む・外す（文字列の中の括弧は数えない）。
		first := true
		inStr := false
		for i := 0; i < len(t); i++ {
			c := t[i]
			switch {
			case inStr && c == '\\':
				i++
			case c == '"':
				inStr = !inStr
			case inStr:
			case c == '[' || c == '{':
				stack = append(stack, first && lineAvoid)
				first = false
			case c == ']' || c == '}':
				if len(stack) > 0 {
					stack = stack[:len(stack)-1]
				}
			}
		}
	}
	return false
}

func label(p Pattern) string {
	if p.Why != "" {
		return p.Why
	}
	return p.Re
}

func writeSummary(dir string, results []Result) error {
	data, err := json.MarshalIndent(results, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "summary.json"), data, 0o644); err != nil {
		return err
	}
	var b strings.Builder
	writeTable(&b, results)
	return os.WriteFile(filepath.Join(dir, "table.md"), []byte(b.String()), 0o644)
}

func writeTable(out io.Writer, results []Result) {
	fmt.Fprintln(out, "| お題 | 点 | 外れた語 | 減点の語 | 入力 tok | 出力 tok | ターン | 触れたファイル |")
	fmt.Fprintln(out, "|---|---:|---|---|---:|---:|---:|---:|")
	var sumP, sumIn, sumOut, sumTurns, sumFiles int
	for _, r := range results {
		fmt.Fprintf(out, "| %s | %d | %s | %s | %d | %d | %d | %d |\n", r.ID, r.Points(),
			strings.Join(r.Missed, "・"), strings.Join(r.AvoidHits, "・"),
			r.InputTokens, r.OutputTokens, r.Turns, len(r.FilesRead))
		sumP += r.Points()
		sumIn += r.InputTokens
		sumOut += r.OutputTokens
		sumTurns += r.Turns
		sumFiles += len(r.FilesRead)
	}
	if n := len(results); n > 0 {
		fmt.Fprintf(out, "| **平均** | %d |  |  | %d | %d | %.1f | %.1f |\n", sumP/n, sumIn/n, sumOut/n,
			float64(sumTurns)/float64(n), float64(sumFiles)/float64(n))
	}
}

func loadSummary(path string) (map[string]Result, []string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}
	var rs []Result
	if err := json.Unmarshal(data, &rs); err != nil {
		return nil, nil, fmt.Errorf("%s: %v", path, err)
	}
	m := map[string]Result{}
	var order []string
	for _, r := range rs {
		m[r.ID] = r
		order = append(order, r.ID)
	}
	return m, order, nil
}

func compare(out io.Writer, opt options) (int, error) {
	before, order, err := loadSummary(filepath.Join(opt.out, opt.compare[0], "summary.json"))
	if err != nil {
		return 2, err
	}
	after, afterOrder, err := loadSummary(filepath.Join(opt.out, opt.compare[1], "summary.json"))
	if err != nil {
		return 2, err
	}
	for _, id := range afterOrder {
		if _, ok := before[id]; !ok {
			order = append(order, id)
		}
	}
	fmt.Fprintf(out, "| お題 | 点 %s → %s | 入力 tok | 出力 tok | ターン | 触れたファイル | 残った外れ |\n", opt.compare[0], opt.compare[1])
	fmt.Fprintln(out, "|---|---:|---:|---:|---:|---:|---|")
	arrow := func(a, b int, okA, okB bool) string {
		as, bs := "-", "-"
		if okA {
			as = strconv.Itoa(a)
		}
		if okB {
			bs = strconv.Itoa(b)
		}
		return as + " → " + bs
	}
	var tb, ta, nb, na int
	for _, id := range order {
		b, okB := before[id]
		a, okA := after[id]
		left := append(append([]string{}, a.Missed...), a.AvoidHits...)
		fmt.Fprintf(out, "| %s | %s | %s | %s | %s | %s | %s |\n", id,
			arrow(b.Points(), a.Points(), okB, okA),
			arrow(b.InputTokens, a.InputTokens, okB, okA),
			arrow(b.OutputTokens, a.OutputTokens, okB, okA),
			arrow(b.Turns, a.Turns, okB, okA),
			arrow(len(b.FilesRead), len(a.FilesRead), okB, okA),
			strings.Join(left, "・"))
		if okB {
			tb += b.Points()
			nb++
		}
		if okA {
			ta += a.Points()
			na++
		}
	}
	if nb > 0 && na > 0 {
		fmt.Fprintf(out, "| **平均** | %d → %d |  |  |  |  |  |\n", tb/nb, ta/na)
	}
	return 0, nil
}
