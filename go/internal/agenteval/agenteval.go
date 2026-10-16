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
// unless は減点の語だけに効く: 同じ行にこれも出たら数えない（道具の説明の行で減点しないため。
// 例: 「use-engine が local.mk を書き換える」は local.mk の手直しではない）。
type Pattern struct {
	Re     string `json:"re"`
	Why    string `json:"why"`
	Unless string `json:"unless,omitempty"`
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
	ID        string   `json:"id"`
	Suite     string   `json:"suite"`
	Run       int      `json:"run,omitempty"`
	Model     string   `json:"model,omitempty"`
	Hit       int      `json:"hit"`
	Want      int      `json:"want"`
	Penalty   int      `json:"penalty"`
	Missed    []string `json:"missed"`
	AvoidHits []string `json:"avoidHits"`
	// 本命の採点（strict）のときだけ: 答えの "choice" と、同じ答えを答え全体で数えた点（loose）。
	Strict       bool     `json:"strict,omitempty"`
	Choice       []string `json:"choice,omitempty"`
	LooseHit     int      `json:"looseHit,omitempty"`
	LoosePenalty int      `json:"loosePenalty,omitempty"`
	// ばらまきの量: ほかのお題の期待の語が、答え全体（loose）と choice（strict）にいくつ当たったか。
	CrossLoose   int      `json:"crossLoose,omitempty"`
	CrossStrict  int      `json:"crossStrict,omitempty"`
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
func (r Result) Points() int { return points(r.Hit, r.Penalty, r.Want) }

// LoosePoints は同じ答えを答え全体で数えた点（strict の記録で、前の版の loose の記録と比べるのに使う）。
func (r Result) LoosePoints() int { return points(r.LooseHit, r.LoosePenalty, r.Want) }

func points(hit, penalty, want int) int {
	if want == 0 {
		if penalty > 0 {
			return 0
		}
		return 100
	}
	p := (hit - penalty) * 100 / want
	if p < 0 {
		return 0
	}
	return p
}

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
	started := time.Now()
	jobs := selectJobs(suites, opt.only)
	if len(jobs) == 0 {
		return 2, errors.New("走らせるお題がありません（--tasks と --only を見直す）")
	}
	dir := filepath.Join(opt.out, opt.label)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return 2, err
	}
	// 同じ版の記録を黙って上書きしない（use-engine で開発中のエンジンを向けると、まだ前の版の番号のまま）。
	// 付け直し（--rescore）は同じ記録を採点し直すだけなので、そのまま上書きしてよい。
	historyPath := filepath.Join(opt.history, opt.version+".json")
	old, hadOld := readHistory(historyPath)
	if opt.history != "" && hadOld && !opt.rescore && !opt.overwrite {
		return 2, fmt.Errorf("%s が既にあります（開発中のエンジンで流していないか。上書きするなら --overwrite）", historyPath)
	}
	var results []Result
	if opt.rescore {
		if opt.repeat == 1 {
			opt.repeat = detectRepeat(dir, jobs[0].task.ID)
		}
		results, err = rescore(dir, jobs, opt.repeat, opt.loose)
		if err != nil {
			return 2, err
		}
		if !opt.loose && noChoiceAtAll(results) {
			return 2, errors.New("どの答えにも \"choice\" がありません。0.35.27 までの記録なら --loose を付けて付け直す")
		}
	} else {
		results = runAll(errOut, dir, jobs, opt)
	}
	// ばらまきの量は、--only で絞っても全部のお題の期待の語で数える。
	all := selectJobs(suites, nil)
	for i := range results {
		results[i].CrossLoose = crossHits(results[i].ID, all, results[i].Answer)
		if !opt.loose {
			results[i].CrossStrict = crossHits(results[i].ID, all, strings.Join(results[i].Choice, "\n"))
		}
	}
	wall := time.Since(started).Seconds()
	if err := writeSummary(dir, results); err != nil {
		return 2, err
	}
	writeTable(out, results)
	fmt.Fprintf(out, "\n記録: %s（summary.json・table.md・お題ごとの .jsonl）\n", dir)
	if opt.history != "" {
		h := BuildHistory(opt.version, opt.repeat, wall, results)
		h.Docs = DocHashes(".")
		if opt.rescore {
			// 付け直しでは走った日と時間・読んだ文書が分からないので、前の記録の物を引き継ぐ。
			h.Totals.WallSeconds = 0
			h.Docs = nil
			if hadOld {
				h.Date, h.Totals.WallSeconds, h.Docs = old.Date, old.Totals.WallSeconds, old.Docs
			}
		}
		path, err := WriteHistory(opt.history, h)
		if err != nil {
			return 2, err
		}
		fmt.Fprintf(out, "版ごとの記録: %s\n\n", path)
		var prevName string
		prev := PreviousHistory(opt.history, opt.version)
		if prev != nil {
			prevName = "v" + prev.Engine
		}
		WriteHistoryDiff(out, prev, h, prevName, "v"+opt.version, dir)
	}
	return 0, nil
}

// detectRepeat は記録のフォルダから回数を読む（<id>.1.jsonl, <id>.2.jsonl … があればその数）。
// 何回か流した記録を --repeat を付け忘れて付け直しても止まらないように。
func detectRepeat(dir, id string) int {
	n := 0
	for {
		if _, err := os.Stat(filepath.Join(dir, fmt.Sprintf("%s.%d.jsonl", id, n+1))); err != nil {
			break
		}
		n++
	}
	return max(n, 1)
}

const usage = `fge agent-eval — 何も教えていないエージェントがお題に正しい道具を選べるかを測る

  fge agent-eval --tasks <お題.json> [--tasks <お題.json>...] [--label 名前] [--only id,id] [--jobs 3]
                 [--max-turns 15] [--model 名前] [--add-dir DIR] [--out debug/agent-eval]
  fge agent-eval --tasks ... --label 名前 --rescore [--loose]   claude を呼ばず、残した記録に点だけ付け直す
                 （0.35.27 までの記録は "choice" が無いので --loose で付け直す）
  fge agent-eval --compare 前の名前 後の名前 [--out debug/agent-eval]   前後の表
  fge agent-eval --tasks ... --repeat 3 --history agent-eval/history --version 0.35.22
                 お題ごとに 3 回流し、版ごとの記録（<history>/<版>.json）を書いて 1 つ前の版と比べる

お題の形: {"version":1,"note":"…","tasks":[{"id":"…","prompt":"依頼の言葉（道具の名前を入れない）",
  "expect":[{"re":"ZStack\\.topLayer","why":"…"}],"avoid":[{"re":"let _ =","why":"…"}]}]}
点 = (期待の語の当たり − 減点の語の当たり) / 期待の語の数 × 100。
本命の採点（既定）: 答えの JSON の "choice"（実際に使う物・先頭 4 つ）だけに当てる。ほかの欄に並べた語は点にならない。
同じ答えを答え全体に当てた点（--loose の採点）も記録に残し、loose の記録しか無い前の版とはそれで比べる。
走らせる claude は読むだけの道具に絞る（Edit・Write・Agent なし）。それ以外は使う人の設定（~/.claude・
プロジェクトのフック・権限のモード）のまま走る —— 実際に使う環境で測るため。engine を読ませるなら --add-dir <engine>。
1 お題 10 分で打ち切る。heavy の鍵は取らない（claude -p は待ちが主で CPU をほとんど使わず、鍵を取ると
ほかの作業場の check・test を止めるため）。代わりに claude -p の同時本数をマシン全体で数える
（/tmp/fge-agent-eval.slots・既定 3 本・FGE_AGENT_EVAL_SLOTS で変える）。
--repeat N は同じお題を N 回流す（記録は <id>.<回>.jsonl）。表は最小・平均・最大になる。付け直しでは回数を記録から読む。
同じ版の記録が既にあると止まる（--overwrite で上書き）。失敗した回（打ち切りなど）は平均に入れず、本数だけ出す。
版ごとの記録の比べ方: 平均点が 15 点以上下がった・入力トークンの平均が 1.5 倍を超えたお題を「下がった」と出す。
`

type options struct {
	tasks     []string
	only      map[string]bool
	label     string
	out       string
	jobs      int
	maxTurns  int
	model     string
	claude    string
	addDirs   []string
	rescore   bool
	help      bool
	repeat    int
	history   string
	version   string
	overwrite bool
	loose     bool
	compare   []string
}

func parseArgs(args []string) (options, error) {
	o := options{out: "debug/agent-eval", jobs: 3, maxTurns: 15, claude: "claude", repeat: 1,
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
		case "--overwrite":
			o.overwrite = true
		case "--loose":
			o.loose = true
		case "--tasks", "--only", "--label", "--out", "--jobs", "--max-turns", "--model", "--claude", "--add-dir",
			"--repeat", "--history", "--version":
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
			case "--history":
				o.history = v
			case "--version":
				o.version = v
			case "--jobs", "--max-turns", "--repeat":
				n, convErr := strconv.Atoi(v)
				if convErr != nil || n < 1 {
					return o, fmt.Errorf("%s は 1 以上の数: %q", a, v)
				}
				switch a {
				case "--jobs":
					o.jobs = n
				case "--repeat":
					o.repeat = n
				default:
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
	if o.history != "" && o.version == "" {
		return o, errors.New("--history には --version（記録の名前になる版）も渡す")
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
				for _, re := range []string{pat.Re, pat.Unless} {
					if _, err := regexp.Compile(re); err != nil {
						return nil, fmt.Errorf("%s の %s: 正規表現 %q が読めない: %v", p, t.ID, re, err)
					}
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

// runAll はお題 × 回数を走らせる。結果はお題の順・回の順に並ぶ。
// 枠は回の順に取る（1 回目のお題を全部始めてから 2 回目）。
//
// WhyNot: お題ごとに 3 回続けて流さないのは、同じお題の 3 回が同じ混み具合の時間に
// 固まると、マシンの込み具合のぶれがお題のぶれに見えるため。
func runAll(errOut io.Writer, dir string, jobs []job, opt options) []Result {
	results := make([]Result, len(jobs)*opt.repeat)
	sem := make(chan struct{}, opt.jobs)
	machine := newSlots(os.Stderr)
	var wg sync.WaitGroup
	var mu sync.Mutex
	for run := 1; run <= opt.repeat; run++ {
		for i, j := range jobs {
			wg.Add(1)
			sem <- struct{}{}
			go func(slot, run int, j job) {
				defer wg.Done()
				defer func() { <-sem }()
				r := runInSlot(machine, dir, j, run, opt)
				results[slot] = r
				mu.Lock()
				// WhyNot: errOut（main が最後にまとめて出す）へ書かないのは、数分かかる間に
				// 何も出ないと止まったのか走っているのか見分けられないため。
				fmt.Fprintf(os.Stderr, "[agent-eval] %-28s %s%3d 点  %4.0f 秒%s\n", j.task.ID, runNote(run, opt.repeat), r.Points(), r.Seconds, errNote(r))
				mu.Unlock()
			}(i*opt.repeat+run-1, run, j)
		}
	}
	wg.Wait()
	return results
}

// runInSlot はマシン全体の枠を 1 つ取って 1 本走らせる。枠は失敗しても返す。
func runInSlot(machine *slots, dir string, j job, run int, opt options) Result {
	release, err := machine.acquire()
	if err != nil {
		return Result{ID: j.task.ID, Suite: j.suite, Run: run, Want: len(j.task.Expect), Err: err.Error()}
	}
	defer release()
	return runOne(dir, j, run, opt)
}

func runNote(run, repeat int) string {
	if repeat == 1 {
		return ""
	}
	return fmt.Sprintf("%d/%d ", run, repeat)
}

// logName は記録のファイル名。1 回だけなら今までどおり <id>.jsonl。
func logName(id string, run, repeat int) string {
	if repeat == 1 {
		return id + ".jsonl"
	}
	return fmt.Sprintf("%s.%d.jsonl", id, run)
}

func errNote(r Result) string {
	if r.Err == "" {
		return ""
	}
	return "  （失敗: " + r.Err + "）"
}

func runOne(dir string, j job, run int, opt options) Result {
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
	logPath := filepath.Join(dir, logName(j.task.ID, run, opt.repeat))
	writeErr := os.WriteFile(logPath, raw, 0o644)
	r := score(j, raw, !opt.loose)
	r.Run = run
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

func rescore(dir string, jobs []job, repeat int, loose bool) ([]Result, error) {
	var results []Result
	for _, j := range jobs {
		for run := 1; run <= repeat; run++ {
			name := logName(j.task.ID, run, repeat)
			raw, err := os.ReadFile(filepath.Join(dir, name))
			if err != nil {
				return nil, fmt.Errorf("%s の記録が無い（先に走らせる）: %v", name, err)
			}
			r := score(j, raw, !loose)
			r.Run = run
			results = append(results, r)
		}
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
	Model    string  `json:"model"`
	NumTurns int     `json:"num_turns"`
	Duration float64 `json:"duration_ms"`
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

// score は記録 1 本から点と数を出す。strict なら "choice" だけで採点し、答え全体の点は LooseHit に残す。
func score(j job, raw []byte, strict bool) Result {
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
		case "system":
			if l.Subtype == "init" {
				r.Model = l.Model
			}
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
			// 付け直し（--rescore）でも秒が残るように、記録の側の時間を使う。走らせたときは runOne が上書きする。
			r.Seconds = l.Duration / 1000
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
		var unless *regexp.Regexp
		if p.Unless != "" {
			unless = regexp.MustCompile(p.Unless)
		}
		if adopted(regexp.MustCompile(p.Re), unless, r.Answer) {
			r.Penalty++
			r.AvoidHits = append(r.AvoidHits, label(p))
		}
	}
	if !strict {
		return r
	}
	r.Strict = true
	r.LooseHit, r.LoosePenalty = r.Hit, r.Penalty
	choice, ok := extractChoice(r.Answer)
	r.Choice = choice
	scoreChoice(&r, j.task, choice)
	if !ok {
		r.Missed = append([]string{"choice が読めない"}, r.Missed...)
	}
	return r
}

// 「let _ = は使わない」のように打ち消して触れた行は減点しない。
// 「ない」1 字では見ない（「できない」「足りない」の行で減点が全部消えるため）。
var negation = regexp.MustCompile(`(使わ|使え|呼ば|書か|足さ|置か|頼ら|し)ない|使わず|使えず|避け|禁止|\bNG\b|消え|止ま|止め|代わりに|古い|非推奨|(?i)\b(not|don't|avoid|instead|catch(es)?|lint|forbid|z-table|value-discard)\b`)

// negationAfter は、当たった語の後ろ・同じ節（「。」「、」まで）の中だけで見る打ち消し。
// 「〜していないか見る」（lint やレビューが見る物の説明）・「X を消す」・「呼ぶと鳴る」・「手で掛けない」。
//
// WhyNot: 行のどこかで探さないのは、「zShifted でずらして揺れを消す」「効果音が鳴る」のように、
// 古い書き方を選んだ行にもこの語は普通に出るため（そうすると本当の減点まで消える）。
var negationAfter = regexp.MustCompile(`^[^。、]*?ていないか|^\s*[\w./-]*\s*[をも]消(す|し)|^[^。、]*?と鳴る|^[^。、]*?手で掛けない`)

// negated は、行の中で re が当たった所が打ち消されているか。
func negated(re *regexp.Regexp, line string) bool {
	if negation.MatchString(line) {
		return true
	}
	loc := re.FindStringIndex(line)
	return loc != nil && negationAfter.MatchString(line[loc[1]:])
}

// avoidKey は「使わない物」を並べる JSON の鍵（"avoid": [...]・"使わない": {...}）。語ごとに見る。
// 読んだファイルの一覧（"files_read"・"読んだファイル"）も入れる —— 「until mkdir を grep した」のように
// 探した語を書くだけで、選んだ物ではないため。
var avoidKey = regexp.MustCompile(`(?i)^(others?|read|files?_?read\w*|read_?files?|.*読んだ(ファイル|物|もの).*|.*調べた(ファイル|物|もの).*|avoid\w*|dont\w*|do_not\w*|not(_\w*)?|forbid\w*|deprecated|ng|old\w*|legacy|anti\w*|pitfalls?|使わない.*|避ける.*|やらない.*|しない.*|禁止.*|古い.*|非推奨.*)$`)

var keyOpen = regexp.MustCompile(`^"([^"]+)"\s*:\s*([\[{])`)

// adopted は、打ち消しの無い行に re が出たか（= その書き方を選んだか）。
// 「使わない物」の鍵の下（JSON の配列・オブジェクト。1 行で閉じる配列も）に並べた行も打ち消しとして読む。
func adopted(re, unless *regexp.Regexp, answer string) bool {
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
		hit := re.MatchString(line) && !negated(re, line) && !inAvoid() && !lineAvoid &&
			(unless == nil || !unless.MatchString(line))
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
	if hasRepeats(results) {
		writeRepeatTable(out, results)
		return
	}
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

func readSummary(path string) ([]Result, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var rs []Result
	if err := json.Unmarshal(data, &rs); err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	return rs, nil
}

func loadSummary(path string) (map[string]Result, []string, error) {
	rs, err := readSummary(path)
	if err != nil {
		return nil, nil, err
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
	// 何回か流した記録どうしは、1 本ずつではなく平均で比べる。
	ra, errA := readSummary(filepath.Join(opt.out, opt.compare[0], "summary.json"))
	rb, errB := readSummary(filepath.Join(opt.out, opt.compare[1], "summary.json"))
	// 片方でも本命の採点なら、採点をそろえて比べる（BuildHistory が採点を読み、WriteHistoryDiff がそろえる）。
	if errA == nil && errB == nil && (hasRepeats(ra) || hasRepeats(rb) || anyStrict(ra) || anyStrict(rb)) {
		prev := BuildHistory(opt.compare[0], 0, 0, ra)
		WriteHistoryDiff(out, &prev, BuildHistory(opt.compare[1], 0, 0, rb), opt.compare[0], opt.compare[1],
			filepath.Join(opt.out, opt.compare[1]))
		return 0, nil
	}
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
