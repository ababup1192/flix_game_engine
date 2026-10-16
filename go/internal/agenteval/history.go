package agenteval

// 版ごとの記録（agent-eval/history/<版>.json）。
//
// エンジンのリリースのたびに同じお題を何回か流し、お題ごとの点・トークン・ターン・秒・費用を
// 1 枚の JSON に残す。1 つ前の版の記録と並べて、下がったお題を知らせる。
// 答えの文は入れない（重い・読み返すのは debug/agent-eval/<label>/ の .jsonl で足りる）。

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// History は 1 つの版の記録。
type History struct {
	Version int    `json:"version"`
	Note    string `json:"note"`
	Engine  string `json:"engine"`
	Date    string `json:"date"`
	Model   string `json:"model"`
	Repeat  int    `json:"repeat"`
	// Scoring は採点の仕方。"strict" = 本命（"choice"）だけ・空 = 答え全体（0.35.27 までの記録）。
	Scoring string       `json:"scoring,omitempty"`
	Totals  HistoryTotal `json:"totals"`
	Tasks   []TaskRuns   `json:"tasks"`
}

// HistoryTotal は 1 回の測りに払った費用。
type HistoryTotal struct {
	Runs         int     `json:"runs"`
	Failed       int     `json:"failed"`
	CostUSD      float64 `json:"costUSD"`
	WallSeconds  float64 `json:"wallSeconds"`
	Seconds      float64 `json:"seconds"`
	InputTokens  int     `json:"inputTokens"`
	OutputTokens int     `json:"outputTokens"`
}

// TaskRuns は 1 つのお題の N 回分。配列は回の順。
type TaskRuns struct {
	ID           string    `json:"id"`
	Suite        string    `json:"suite"`
	Points       []int     `json:"points"`
	InputTokens  []int     `json:"inputTokens"`
	OutputTokens []int     `json:"outputTokens"`
	Turns        []int     `json:"turns"`
	Seconds      []float64 `json:"seconds"`
	CostUSD      float64   `json:"costUSD"`
	Failed       int       `json:"failed,omitempty"`
	Missed       []string  `json:"missed,omitempty"`
	// strict の記録だけ: 同じ答えを答え全体で数えた点（loose）と、ばらまきの量
	// （ほかのお題の期待の語が答え全体・choice にいくつ当たったか）。
	LoosePoints []int `json:"loosePoints,omitempty"`
	CrossLoose  []int `json:"crossLoose,omitempty"`
	CrossStrict []int `json:"crossStrict,omitempty"`
}

const scoringStrict = "strict"

// scoringName は表に出す採点の名前。
func scoringName(s string) string {
	if s == scoringStrict {
		return "本命"
	}
	return "答え全体"
}

const historyNote = "bin/fge agent-eval --history が書く版ごとの記録（お題ごとの N 回の点・トークン・ターン・秒）。" +
	"手で直さない。make status が最新の版を 1 行に出す。"

// BuildHistory は結果の列を版の記録にまとめる。お題の並びは結果に初めて出た順。
func BuildHistory(engine string, repeat int, wall float64, results []Result) History {
	h := History{Version: 1, Note: historyNote, Engine: engine, Repeat: repeat,
		Date: time.Now().Format("2006-01-02")}
	h.Tasks = groupRuns(results)
	if anyStrict(results) {
		h.Scoring = scoringStrict
	}
	missed := map[string]map[string]int{}
	for _, r := range results {
		if h.Model == "" {
			h.Model = r.Model
		}
		h.Totals.Runs++
		if r.Err != "" {
			h.Totals.Failed++
		}
		h.Totals.CostUSD += r.CostUSD
		h.Totals.Seconds += r.Seconds
		h.Totals.InputTokens += r.InputTokens
		h.Totals.OutputTokens += r.OutputTokens
		if missed[r.ID] == nil {
			missed[r.ID] = map[string]int{}
		}
		if r.Err != "" {
			continue
		}
		for _, m := range r.Missed {
			missed[r.ID][m]++
		}
		for _, m := range r.AvoidHits {
			missed[r.ID]["減点: "+m]++
		}
	}
	h.Totals.WallSeconds = wall
	for i := range h.Tasks {
		t := &h.Tasks[i]
		for m, n := range missed[t.ID] {
			t.Missed = append(t.Missed, fmt.Sprintf("%s (%d/%d)", m, n, len(t.Points)+t.Failed))
		}
		sort.Strings(t.Missed)
	}
	return h
}

// groupRuns はお題ごとに回を束ねる。失敗した回（打ち切り・claude の失敗）は数だけ数え、
// 点とトークンの列には入れない —— 0 点・0 トークンが平均に混ざると「下がった」に化けるため。
func groupRuns(results []Result) []TaskRuns {
	var tasks []TaskRuns
	at := map[string]int{}
	for _, r := range results {
		i, ok := at[r.ID]
		if !ok {
			i = len(tasks)
			at[r.ID] = i
			tasks = append(tasks, TaskRuns{ID: r.ID, Suite: r.Suite})
		}
		t := &tasks[i]
		t.CostUSD += r.CostUSD
		if r.Err != "" {
			t.Failed++
			continue
		}
		t.Points = append(t.Points, r.Points())
		t.InputTokens = append(t.InputTokens, r.InputTokens)
		t.OutputTokens = append(t.OutputTokens, r.OutputTokens)
		t.Turns = append(t.Turns, r.Turns)
		t.Seconds = append(t.Seconds, r.Seconds)
		if r.Strict {
			t.LoosePoints = append(t.LoosePoints, r.LoosePoints())
			t.CrossLoose = append(t.CrossLoose, r.CrossLoose)
			t.CrossStrict = append(t.CrossStrict, r.CrossStrict)
		}
	}
	return tasks
}

func hasRepeats(results []Result) bool {
	seen := map[string]bool{}
	for _, r := range results {
		if seen[r.ID] {
			return true
		}
		seen[r.ID] = true
	}
	return false
}

// writeRepeatTable は同じお題を何回か流したときの表（最小・平均・最大と、トークンの平均と幅）。
func writeRepeatTable(out io.Writer, results []Result) {
	h := BuildHistory("", 0, 0, results)
	fmt.Fprintln(out, "| お題 | 点 最小/平均/最大 | 答え全体の点 平均 | 入力 tok 平均 (幅) | 出力 tok 平均 | ターン 平均 (幅) | 外れた語・減点の語 (回数) |")
	fmt.Fprintln(out, "|---|---:|---:|---:|---:|---:|---|")
	for _, t := range h.Tasks {
		lo, mean, hi := spread(t.Points)
		inLo, inMean, inHi := spread(t.InputTokens)
		_, outMean, _ := spread(t.OutputTokens)
		tLo, tMean, tHi := spread(t.Turns)
		loose := "-"
		if len(t.LoosePoints) > 0 {
			_, lm, _ := spread(t.LoosePoints)
			loose = fmt.Sprintf("%.0f", lm)
		}
		fmt.Fprintf(out, "| %s | %d / %.0f / %d | %s | %.0f (%d–%d) | %.0f | %.1f (%d–%d) | %s |\n",
			t.ID, lo, mean, hi, loose, inMean, inLo, inHi, outMean, tMean, tLo, tHi, strings.Join(t.notes(), "・"))
	}
	fmt.Fprintf(out, "| **平均** | %.1f |  | %.0f |  | %.1f | %d 回・$%.2f |\n",
		h.MeanPoints(), h.MeanInputTokens(), h.MeanTurns(), h.Totals.Runs, h.Totals.CostUSD)
}

// spread は整数の列の最小・平均・最大。
func spread(xs []int) (int, float64, int) {
	if len(xs) == 0 {
		return 0, 0, 0
	}
	lo, hi, sum := xs[0], xs[0], 0
	for _, x := range xs {
		lo, hi = min(lo, x), max(hi, x)
		sum += x
	}
	return lo, float64(sum) / float64(len(xs)), hi
}

// notes は表の最後の列（外れた語と、失敗した回の数）。
func (t TaskRuns) notes() []string {
	if t.Failed == 0 {
		return t.Missed
	}
	return append([]string{fmt.Sprintf("失敗 %d 回", t.Failed)}, t.Missed...)
}

func (t TaskRuns) meanPoints() float64 { _, m, _ := spread(t.Points); return m }

// pointsScoredAs は、recordScoring の記録のお題を want の採点で数えた点の列
// （strict の記録を loose で読むときは LoosePoints）。その採点の点が無ければ nil。
func (t TaskRuns) pointsScoredAs(recordScoring, want string) []int {
	switch {
	case recordScoring == want:
		return t.Points
	case recordScoring == scoringStrict && want == "":
		return t.LoosePoints
	}
	return nil
}

// comparableScoring は 2 つの記録を比べる採点。同じならそれ・片方だけ strict なら loose（strict の記録は
// loose の点も持つ）。
func comparableScoring(prev, cur History) string {
	if prev.Scoring == cur.Scoring {
		return cur.Scoring
	}
	return ""
}

func (t TaskRuns) meanInput() float64 { _, m, _ := spread(t.InputTokens); return m }

// MeanPoints は全部のお題の平均点の平均。
func (h History) MeanPoints() float64 {
	return h.meanOf(func(t TaskRuns) float64 { return t.meanPoints() })
}

// MeanInputTokens はお題 1 本あたりの入力トークンの平均。
func (h History) MeanInputTokens() float64 {
	return h.meanOf(func(t TaskRuns) float64 { return t.meanInput() })
}

// MeanTurns はお題 1 本あたりのターンの平均。
func (h History) MeanTurns() float64 {
	return h.meanOf(func(t TaskRuns) float64 { _, m, _ := spread(t.Turns); return m })
}

func (h History) meanOf(f func(TaskRuns) float64) float64 {
	sum, n := 0.0, 0
	for _, t := range h.Tasks {
		if len(t.Points) == 0 {
			continue // 全部の回が失敗したお題
		}
		sum += f(t)
		n++
	}
	if n == 0 {
		return 0
	}
	return sum / float64(n)
}

// 「下がった」の線。
//
// WhyNot: 1 回分の外れ（3 回なら 33 点）で毎回鳴らないよう、点は平均で 15 点以上の差にする。
// 3 回のうち 1 回だけ 1 語外す程度（2 語のお題で 17 点）は拾い、ぶれの 1 回では鳴りにくい。
// トークンは 1 本ごとの幅が 2 倍近くあるので、平均で 1.5 倍を超えたときだけ拾う。
const (
	dropPoints    = 15.0
	growTokenRate = 1.5
)

// Regression は前の版より下がった 1 つのお題。
type Regression struct {
	ID     string
	Reason string
}

// Regressions は prev から cur で下がったお題（前の版にあるお題だけ比べる）。
func Regressions(prev, cur History) []Regression {
	before := map[string]TaskRuns{}
	for _, t := range prev.Tasks {
		before[t.ID] = t
	}
	sc := comparableScoring(prev, cur)
	var out []Regression
	for _, t := range cur.Tasks {
		b, ok := before[t.ID]
		bp, cp := b.pointsScoredAs(prev.Scoring, sc), t.pointsScoredAs(cur.Scoring, sc)
		if !ok || len(cp) == 0 || len(bp) == 0 {
			continue // 全部の回が失敗したお題は比べない（失敗の本数は表と status に出る）
		}
		var why []string
		_, bm, _ := spread(bp)
		_, cm, _ := spread(cp)
		if bm-cm >= dropPoints {
			why = append(why, fmt.Sprintf("点 %.0f → %.0f", bm, cm))
		}
		if b.meanInput() > 0 && t.meanInput() > b.meanInput()*growTokenRate {
			why = append(why, fmt.Sprintf("入力 %.0fk → %.0fk tok", b.meanInput()/1000, t.meanInput()/1000))
		}
		if len(why) > 0 {
			out = append(out, Regression{t.ID, strings.Join(why, "・")})
		}
	}
	return out
}

// WriteHistory は <dir>/<版>.json に書いて、そのパスを返す。
func WriteHistory(dir string, h History) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	data, err := json.MarshalIndent(h, "", "  ")
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, h.Engine+".json")
	return path, os.WriteFile(path, append(data, '\n'), 0o644)
}

func readHistory(path string) (History, bool) {
	var h History
	data, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(data, &h) != nil || h.Engine == "" {
		return History{}, false
	}
	return h, true
}

// LoadHistories は dir の記録を版の古い順に返す。読めない JSON は飛ばす（status から呼ぶので止めない）。
func LoadHistories(dir string) []History {
	paths, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	var hs []History
	for _, p := range paths {
		if h, ok := readHistory(p); ok {
			hs = append(hs, h)
		}
	}
	sort.Slice(hs, func(i, j int) bool { return versionLess(hs[i].Engine, hs[j].Engine) })
	return hs
}

// PreviousHistory は version より前の版のうち一番新しい記録。無ければ nil。
func PreviousHistory(dir, version string) *History {
	var prev *History
	for _, h := range LoadHistories(dir) {
		if versionLess(h.Engine, version) {
			h := h
			prev = &h
		}
	}
	return prev
}

// versionLess は "0.35.9" < "0.35.21" のように数の並びで比べる。
func versionLess(a, b string) bool {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(as) && i < len(bs); i++ {
		x, errX := strconv.Atoi(as[i])
		y, errY := strconv.Atoi(bs[i])
		if errX != nil || errY != nil {
			if as[i] != bs[i] {
				return as[i] < bs[i]
			}
			continue
		}
		if x != y {
			return x < y
		}
	}
	return len(as) < len(bs)
}

// WriteHistoryDiff は前の版との表と、下がったお題の一覧を書く。
// prevName・curName は表の見出し、logDir は外れた答えを読みに行く記録のフォルダ。
func WriteHistoryDiff(out io.Writer, prev *History, cur History, prevName, curName, logDir string) {
	wall := "" // 付け直しでは走った時間が分からない
	if cur.Totals.WallSeconds > 0 {
		wall = fmt.Sprintf("%.0f 分・", cur.Totals.WallSeconds/60)
	}
	fmt.Fprintf(out, "費用: %d 回・$%.2f（API 換算）・入力 %dk / 出力 %dk tok・%s1 本ずつ足すと %.0f 分\n",
		cur.Totals.Runs, cur.Totals.CostUSD, cur.Totals.InputTokens/1000, cur.Totals.OutputTokens/1000,
		wall, cur.Totals.Seconds/60)
	if cur.Scoring == scoringStrict {
		writeScoringSeam(out, cur)
	}
	if prev == nil {
		fmt.Fprintln(out, "前の版の記録がありません（比べるのは次の版から）")
		return
	}
	sc := comparableScoring(*prev, cur)
	mean := func(recordScoring string, t TaskRuns) float64 {
		_, m, _ := spread(t.pointsScoredAs(recordScoring, sc))
		return m
	}
	before := map[string]TaskRuns{}
	for _, t := range prev.Tasks {
		before[t.ID] = t
	}
	down := map[string]string{}
	for _, r := range Regressions(*prev, cur) {
		down[r.ID] = r.Reason
	}
	fmt.Fprintf(out, "\n| お題 | 点 %s → %s（%sで採点） | 入力 tok | ターン | |\n|---|---:|---:|---:|---|\n",
		prevName, curName, scoringName(sc))
	for _, t := range cur.Tasks {
		_, tm, _ := spread(t.Turns)
		b, ok := before[t.ID]
		if !ok {
			fmt.Fprintf(out, "| %s | - → %.0f | - → %.0fk | - → %.1f | 新しいお題 |\n", t.ID, mean(cur.Scoring, t), t.meanInput()/1000, tm)
			continue
		}
		_, bm, _ := spread(b.Turns)
		mark := ""
		if why, bad := down[t.ID]; bad {
			mark = "▼ " + why
		}
		if t.Failed > 0 {
			mark = strings.TrimSpace(fmt.Sprintf("%s 失敗 %d 回", mark, t.Failed))
		}
		fmt.Fprintf(out, "| %s | %.0f → %.0f | %.0fk → %.0fk | %.1f → %.1f | %s |\n", t.ID,
			mean(prev.Scoring, b), mean(cur.Scoring, t), b.meanInput()/1000, t.meanInput()/1000, bm, tm, mark)
	}
	fmt.Fprintf(out, "| **平均** | %.1f → %.1f | %.0fk → %.0fk | %.1f → %.1f | |\n",
		prev.meanOf(func(t TaskRuns) float64 { return mean(prev.Scoring, t) }),
		cur.meanOf(func(t TaskRuns) float64 { return mean(cur.Scoring, t) }),
		prev.MeanInputTokens()/1000, cur.MeanInputTokens()/1000, prev.MeanTurns(), cur.MeanTurns())
	if len(down) == 0 {
		fmt.Fprintln(out, "\n下がったお題: なし")
		return
	}
	fmt.Fprintf(out, "\n下がったお題: %d 本（外れた答えは %s/ の .jsonl）\n", len(down), logDir)
}

// writeScoringSeam は、同じ答えを答え全体と本命（choice）で数えた点と、ばらまきの量を並べる。
// 採点を替えた版で、どのお題の点がどう変わったかを残すため。
func writeScoringSeam(out io.Writer, cur History) {
	fmt.Fprintln(out, "\n| お題 | 答え全体 → 本命 | ほかのお題の語（答え全体 → choice） |\n|---|---:|---:|")
	var sumL, sumS, sumCL, sumCS float64
	n := 0
	for _, t := range cur.Tasks {
		if len(t.Points) == 0 {
			continue
		}
		_, l, _ := spread(t.LoosePoints)
		_, s, _ := spread(t.Points)
		_, cl, _ := spread(t.CrossLoose)
		_, cs, _ := spread(t.CrossStrict)
		mark := ""
		if l != s {
			mark = " ◆"
		}
		fmt.Fprintf(out, "| %s | %.0f → %.0f%s | %.1f → %.1f |\n", t.ID, l, s, mark, cl, cs)
		sumL, sumS, sumCL, sumCS = sumL+l, sumS+s, sumCL+cl, sumCS+cs
		n++
	}
	if n > 0 {
		f := float64(n)
		fmt.Fprintf(out, "| **平均** | %.1f → %.1f | %.1f → %.1f |\n\n", sumL/f, sumS/f, sumCL/f, sumCS/f)
	}
}

// StatusLine は make status に出す 1 行。記録が無ければ空。
func StatusLine(dir string) string {
	hs := LoadHistories(dir)
	if len(hs) == 0 {
		return ""
	}
	cur := hs[len(hs)-1]
	worst, worstID := 101.0, ""
	for _, t := range cur.Tasks {
		if len(t.Points) == 0 {
			continue
		}
		if m := t.meanPoints(); m < worst {
			worst, worstID = m, t.ID
		}
	}
	line := fmt.Sprintf("agent-eval v%s: 平均 %.0f 点（%sで採点・%d 題×%d 回・入力 %.0fk tok/題・$%.2f）", cur.Engine,
		cur.MeanPoints(), scoringName(cur.Scoring), len(cur.Tasks), cur.Repeat, cur.MeanInputTokens()/1000, cur.Totals.CostUSD)
	if worst < 100 {
		line += fmt.Sprintf(" 最低 %s %.0f", worstID, worst)
	}
	if cur.Totals.Failed > 0 {
		line += fmt.Sprintf(" 失敗 %d 回", cur.Totals.Failed)
	}
	if len(hs) >= 2 {
		if down := Regressions(hs[len(hs)-2], cur); len(down) > 0 {
			var ids []string
			for _, r := range down {
				ids = append(ids, r.ID)
			}
			line += fmt.Sprintf(" ▼v%s より下がった: %s", hs[len(hs)-2].Engine, strings.Join(ids, " "))
		}
	}
	return line
}
