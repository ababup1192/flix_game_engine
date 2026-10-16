package status

// status — セッション開始の現状 1 画面。
//
//	fge-go status                 いまのカレントを見る
//	fge-go status --root DIR      見に行く先を差し替える
//	fge-go status --now 1770000000  「いま」を差し替える（比較用。既定は実時刻）
//
// 散らばった記録 (git / .test-logs / スナップショット / 注釈チケット / NOTES.md) を集めて
// 30 行前後に要約する。何も実行しない・何も変更しない・必ず exit 0。

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/agenteval"
	"github.com/ababup1192/flix_game_engine/go/internal/renderbudget"
)

// ctx は 1 回の組み立てが見る世界。root がすべての相対パスの基準。
type ctx struct {
	rules *Rules
	// root は見に行く先の絶対パス。symlink をたどった実体の側にそろえる。
	root string
	// now は「いま」。age と見出しの時刻がここから出る。
	now time.Time
}

// ---- 小物 ----------------------------------------------------------------

func (c *ctx) abs(rel string) string { return filepath.Join(c.root, filepath.FromSlash(rel)) }

func (c *ctx) isDir(rel string) bool {
	info, err := os.Stat(c.abs(rel))
	return err == nil && info.IsDir()
}

func (c *ctx) isFile(rel string) bool {
	info, err := os.Stat(c.abs(rel))
	return err == nil && info.Mode().IsRegular()
}

func (c *ctx) glob(pattern string) []string { return pyGlob(c.root, pattern) }

// mtime は最後に書かれた時刻。読めなければ ok=false。
func (c *ctx) mtime(rel string) (float64, bool) {
	info, err := os.Stat(c.abs(rel))
	if err != nil {
		return 0, false
	}
	return float64(info.ModTime().UnixNano()) / 1e9, true
}

// age は更新からの経過を「3分前」「2時間前」「5日前」で返す。
func (c *ctx) age(rel string) string {
	m, ok := c.mtime(rel)
	if !ok {
		return "?"
	}
	sec := float64(c.now.UnixNano())/1e9 - m
	r := c.rules
	if sec < r.AgeJustNowSeconds {
		return "たった今"
	}
	if sec < r.AgeMinuteSeconds {
		return fmt.Sprintf("%d分前", int64(math.Floor(sec/60)))
	}
	if sec < r.AgeHourSeconds {
		return fmt.Sprintf("%d時間前", int64(math.Floor(sec/3600)))
	}
	return fmt.Sprintf("%d日前", int64(math.Floor(sec/86400)))
}

// git は git を root で走らせて stdout を返す。失敗・異常終了は空文字。
func (c *ctx) git(args ...string) string {
	runCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(runCtx, "git", args...)
	cmd.Dir = c.root
	var out, errOut strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errOut
	if err := cmd.Run(); err != nil {
		return ""
	}
	return pyStrip(universalNewlines(decodeReplace([]byte(out.String()))))
}

// firstLine は最初の中身のある行（先頭の "#" を落として前後を詰めた物）。
func (c *ctx) firstLine(rel string) string {
	text, err := readTextPy(c.abs(rel))
	if err != nil {
		return ""
	}
	for _, line := range pyFileLines(text) {
		s := pyStrip(pyLStripHash(pyStrip(line)))
		if s != "" {
			return s
		}
	}
	return ""
}

// ---- 節 ------------------------------------------------------------------

func sectionGit(c *ctx, out *[]string) {
	branch := c.git("rev-parse", "--abbrev-ref", "HEAD")
	if branch == "" {
		return
	}
	dirty := c.git("status", "--porcelain")
	n := 0
	if dirty != "" {
		n = len(pySplitLines(dirty))
	}
	*out = append(*out, fmt.Sprintf("git      ブランチ %s / 変更中 %d ファイル", branch, n))
	for _, line := range pySplitLines(c.git("log", "--oneline", "-"+strconv.Itoa(c.rules.GitLogCount))) {
		*out = append(*out, "  "+line)
	}
	// コミット時のゲートは clone ごとに配線が要る。読むだけの status は知らせるだけ。
	if c.isDir("bin/githooks") && c.git("config", "core.hooksPath") != "bin/githooks" {
		*out = append(*out, "  未配線: pre-commit ゲートが効いていません → make hooks")
	}
}

func sectionTests(c *ctx, out *[]string) {
	all := c.glob(c.rules.TestLogsDir + "/*.log")
	sort.Strings(all)
	var logs []string
	for _, p := range all {
		if !strings.HasPrefix(pyBasename(p), "render-") {
			logs = append(logs, p)
		}
	}
	if len(logs) == 0 {
		*out = append(*out, "テスト   記録なし (make test / make test-par を一度も通していない)")
		return
	}
	*out = append(*out, "テスト   (最終実行の記録から。回し直してはいない)")
	var reds, greens []string
	for _, p := range logs {
		name := pyDropTail(pyBasename(p), 4)
		entry := fmt.Sprintf("%s(%s)", name, c.age(p))
		if c.isFileAny(pyDropTail(p, 4) + ".fail") {
			reds = append(reds, entry)
		} else {
			greens = append(greens, entry)
		}
	}
	if len(greens) > 0 {
		shown := greens
		extra := ""
		if len(greens) > c.rules.GreensShown {
			shown = greens[:c.rules.GreensShown]
			extra = fmt.Sprintf(" 他%d", len(greens)-c.rules.GreensShown)
		}
		*out = append(*out, "  OK: "+strings.Join(shown, " ")+extra)
	}
	for _, r := range reds {
		*out = append(*out, fmt.Sprintf("  NG: %s — 詳細は .test-logs/ の同名ログ", r))
	}
	for _, p := range c.glob(c.rules.TestLogsDir + "/render-*.fail") {
		*out = append(*out, fmt.Sprintf("  NG(render): %s", pyDropTail(pyBasename(p), 5)))
	}
}

// isFileAny は os.path.exists（ディレクトリでも真）。
func (c *ctx) isFileAny(rel string) bool {
	_, err := os.Stat(c.abs(rel))
	return err == nil
}

// referencePair は (名前, reference/SHA256SUMS.txt, gallery/) の組。
type referencePair struct{ name, sums, gallery string }

// referencePairs はゲームリポなら自分 1 組、engine リポなら templates 全部。
func (c *ctx) referencePairs() []referencePair {
	if c.isFile("reference/SHA256SUMS.txt") {
		return []referencePair{{".", "reference/SHA256SUMS.txt", "gallery"}}
	}
	sums := c.glob("templates/*/reference/SHA256SUMS.txt")
	sort.Strings(sums)
	var pairs []referencePair
	for _, s := range sums {
		base := pyDirname(pyDirname(s))
		pairs = append(pairs, referencePair{pyBasename(base), s, base + "/gallery"})
	}
	return pairs
}

// checkReference は一致した枚数と食い違い一覧を返す。
// err はファイルが読めなかったとき（呼ぶ側はその組を飛ばす）。
func (c *ctx) checkReference(sums, gallery string) (int, []string, error) {
	text, err := readTextPy(c.abs(sums))
	if err != nil {
		return 0, nil, err
	}
	// WhyNot: map だけで持たないのは、書いた順に見ないと食い違い一覧の行順が変わるため。
	var order []string
	expected := map[string]string{}
	for _, line := range pyFileLines(text) {
		parts := pySplitWS1(line)
		if len(parts) != 2 {
			continue
		}
		name := pyStrip(parts[1])
		if _, dup := expected[name]; !dup {
			order = append(order, name)
		}
		expected[name] = parts[0]
	}
	actual := map[string]bool{}
	for _, p := range c.glob(gallery + "/*.png") {
		actual[pyBasename(p)] = true
	}
	bad := map[string]bool{}
	for name := range expected {
		if !actual[name] {
			bad[name] = true
		}
	}
	for name := range actual {
		if _, ok := expected[name]; !ok {
			bad[name] = true
		}
	}
	ok := 0
	for _, name := range order {
		p := gallery + "/" + name
		if !c.isFile(p) {
			continue
		}
		sum, err := sha256File(c.abs(p))
		if err != nil {
			return 0, nil, err
		}
		if sum == expected[name] {
			ok++
		} else {
			bad[name] = true
		}
	}
	list := make([]string, 0, len(bad))
	for name := range bad {
		list = append(list, name)
	}
	sort.Strings(list)
	return ok, list, nil
}

func sha256File(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func sectionReference(c *ctx, out *[]string) {
	pairs := c.referencePairs()
	if len(pairs) == 0 {
		return
	}
	var oks []string
	for _, pair := range pairs {
		if !c.isDir(pair.gallery) {
			continue // 未生成は「情報なし」。生成してから比べる
		}
		ok, bad, err := c.checkReference(pair.sums, pair.gallery)
		if err != nil {
			continue
		}
		if len(bad) > 0 {
			shown := bad
			extra := ""
			if len(bad) > c.rules.ReferenceBadShown {
				shown = bad[:c.rules.ReferenceBadShown]
				extra = fmt.Sprintf(" 他%d", len(bad)-c.rules.ReferenceBadShown)
			}
			*out = append(*out, fmt.Sprintf(
				"reference NG %s: %s%s (意図した変更なら make reference-update で更新)",
				pair.name, strings.Join(shown, " "), extra))
			continue
		}
		oks = append(oks, fmt.Sprintf("%s(%d枚)", pair.name, ok))
	}
	if len(oks) > 0 {
		*out = append(*out, "reference OK: "+strings.Join(oks, " "))
	}
}

func sectionBudget(c *ctx, out *[]string) {
	if c.isDir("templates") {
		return // engine リポ自身。テンプレごとの判定は make reference-check の仕事
	}
	if !c.isDir("gallery") {
		return
	}
	engine := ReadEngineDir(c.root)
	if engine == "" {
		return
	}
	var body, errBody strings.Builder
	code, err := renderbudget.Run(&body, &errBody, engine, []string{c.root, "--brief"})
	if err != nil {
		return // 規約データが読めない = 検査が動かなかった。status は黙る
	}
	if code == 0 {
		for _, s := range pySplitLines(body.String()) {
			if strings.HasPrefix(s, "budget OK") {
				*out = append(*out, s)
				break
			}
		}
		return
	}
	*out = append(*out, "budget NG: 絵の値段が予算を超えています")
	shown := 0
	for _, s := range pySplitLines(errBody.String()) {
		if !strings.HasPrefix(s, "  ") {
			continue
		}
		if shown >= c.rules.BudgetDetailLines {
			break
		}
		*out = append(*out, s)
		shown++
	}
}

func sectionTickets(c *ctx, out *[]string) {
	cands := append(c.glob("debug/annotations/*"),
		c.glob("templates/*/debug/annotations/*")...)
	var dirs []string
	for _, d := range cands {
		if c.isDir(d) {
			dirs = append(dirs, d)
		}
	}
	if len(dirs) == 0 {
		return
	}
	mtimes := make(map[string]float64, len(dirs))
	for _, d := range dirs {
		m, _ := c.mtime(d)
		mtimes[d] = m
	}
	// WhyNot: sort.Slice にしないのは、mtime が同着のとき並びが崩れるため。
	sort.SliceStable(dirs, func(i, j int) bool { return mtimes[dirs[i]] > mtimes[dirs[j]] })
	*out = append(*out, fmt.Sprintf("チケット 注釈 %d 件 (新しい順):", len(dirs)))
	for i, d := range dirs {
		if i >= c.rules.TicketsShown {
			break
		}
		summary := c.firstLine(d + "/README.md")
		*out = append(*out, fmt.Sprintf("  %s (%s) %s",
			pyBasename(d), c.age(d), pyHead(summary, c.rules.TicketSummaryWidth)))
	}
}

func sectionStyle(c *ctx, out *[]string) {
	// engine リポ自身にはルート AGENTS.local.md が無く、素朴に検査すると毎回誤発火する。
	if c.isDir("templates") {
		return
	}
	hint := "[画風] AGENTS.local.md の「この画面の画風」が未定（無い/仮置きのまま） → 絵を描く前に /style-interview"
	text, err := readTextPy(c.abs("AGENTS.local.md"))
	if err != nil {
		*out = append(*out, hint)
		return
	}
	// 全問おまかせでも聞き取り済みと分かるように、痕跡コメントを節より優先して見る
	if strings.Contains(text, "style-interview") {
		return
	}
	hasHeading := false
	for _, line := range pySplitLines(text) {
		if strings.HasPrefix(line, "## この") && strings.Contains(line, "画風") {
			hasHeading = true
			break
		}
	}
	if hasHeading && !strings.Contains(text, "最初に決めて、ここに") {
		return
	}
	*out = append(*out, hint)
}

var packStampRe = regexp.MustCompile(`agents-pack \(engine v([0-9][0-9A-Za-z.\-]*)\)`)

func sectionPack(c *ctx, out *[]string) {
	if c.isDir("templates") {
		return // engine リポ自身。AGENTS.md は pack の生成物ではない
	}
	text, err := readTextPy(c.abs("AGENTS.md"))
	if err != nil {
		return
	}
	head := pyHead(text, 400)
	m := packStampRe.FindStringSubmatch(head)
	if m == nil {
		return
	}
	engine := ReadEngineDir(c.root)
	if engine == "" {
		return
	}
	cur := ReadEngineVersion(engine)
	if cur != "" && cur != m[1] {
		*out = append(*out, fmt.Sprintf(
			"pack     古い (この AGENTS.md は engine v%s / いまの engine は v%s)。"+
				"engine 側で make sync-agents GAME=\"%s\" を再実行", m[1], cur, c.root))
	}
}

var enginePinRe = compilePySpace(
	`"github:ababup1192/flix_game_engine"\s*=\s*\{[^}]*version\s*=\s*"([0-9][0-9A-Za-z.\-]*)"`)

func sectionEngineDrift(c *ctx, out *[]string) {
	if c.isDir("templates") {
		return // engine リポ自身
	}
	text, err := readTextPy(c.abs("flix.toml"))
	if err != nil {
		return
	}
	m := enginePinRe.FindStringSubmatch(text)
	if m == nil {
		return
	}
	engine := ReadEngineDir(c.root)
	if engine == "" {
		return
	}
	cur := ReadEngineVersion(engine)
	if cur != "" && cur != m[1] {
		*out = append(*out, fmt.Sprintf(
			"engine   バージョンズレ (このゲームは v%s / いまの engine は v%s)。"+
				"make api や docs は v%s の物なので、無い API を引く恐れ → make engine-upgrade で追随",
			m[1], cur, cur))
	}
}

// countCapped は path 配下のファイル数。上限に達したら歩くのをやめる。
func countCapped(root, rel string, limit int) int {
	n := 0
	stack := []string{path.Join(root, rel)}
	for len(stack) > 0 {
		dir := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		f, err := os.Open(dir)
		if err != nil {
			continue
		}
		entries, err := f.ReadDir(-1)
		f.Close()
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				stack = append(stack, path.Join(dir, e.Name()))
				continue
			}
			n++
			if n >= limit {
				return n
			}
		}
	}
	return n
}

func sectionBuilds(c *ctx, out *[]string) {
	var cands []string
	for _, g := range c.rules.BuildGlobs {
		cands = append(cands, c.glob(g)...)
	}
	for _, p := range c.rules.BuildDirs {
		cands = append(cands, p+"/build")
	}
	sort.Strings(cands)
	heavy := 0
	for _, d := range cands {
		if countCapped(c.root, d, c.rules.BuildWarnEntries) >= c.rules.BuildWarnEntries {
			heavy++
		}
	}
	if heavy == 0 {
		return
	}
	*out = append(*out, fmt.Sprintf("build     %d プロジェクトにコンパイル成果物が溜まっている "+
		"(複製と glob が遅くなる。消しても再生成される) → make clean-game-builds", heavy))
}

// sectionAgentEval は版ごとの agent-eval の記録（make agent-eval-release が書く）の最新を 1 行。
// 記録が無いゲームでは黙る（測るかどうかは任意）。
func sectionAgentEval(c *ctx, out *[]string) {
	if line := agenteval.StatusLine(c.abs("agent-eval/history")); line != "" {
		*out = append(*out, line)
	}
}

func sectionNotes(c *ctx, out *[]string) {
	if !c.isFile("NOTES.md") {
		*out = append(*out, "引き継ぎ NOTES.md なし (セッションの終わりに「次やること」を 3 行残すと次が安い)")
		return
	}
	*out = append(*out, fmt.Sprintf("引き継ぎ NOTES.md (%s):", c.age("NOTES.md")))
	text, err := readTextPy(c.abs("NOTES.md"))
	if err != nil {
		return
	}
	shown := 0
	for _, line := range pyFileLines(text) {
		s := pyRStrip(line)
		if pyStrip(s) == "" {
			continue
		}
		*out = append(*out, "  "+pyHead(s, c.rules.NotesWidth))
		shown++
		if shown >= c.rules.NotesShown {
			break
		}
	}
}

// ---- 入口 ----------------------------------------------------------------

var sectionsByName = map[string]func(*ctx, *[]string){
	"section_git":          sectionGit,
	"section_tests":        sectionTests,
	"section_reference":    sectionReference,
	"section_budget":       sectionBudget,
	"section_tickets":      sectionTickets,
	"section_style":        sectionStyle,
	"section_pack":         sectionPack,
	"section_engine_drift": sectionEngineDrift,
	"section_builds":       sectionBuilds,
	"section_agent_eval":   sectionAgentEval,
	"section_notes":        sectionNotes,
}

// Options は Run の付加情報。
type Options struct {
	// Root は見に行く先。空なら実行時のカレント。
	Root string
	// Now は「いま」。ゼロ値なら実時刻。
	Now time.Time
}

// Run は 1 画面を組んで out へ書く。必ず 0 で返る（status は知らせるだけ）。
// err は検査そのものが動かなかったとき（規約データが読めない等）だけ。
func Run(out, errOut *strings.Builder, rulesRoot string, args []string, opts Options) (int, error) {
	rules, err := LoadRules(rulesRoot)
	if err != nil {
		return 2, err
	}
	root := opts.Root
	if root == "" {
		root, _ = os.Getwd()
	}
	root = resolveRoot(root)
	now := opts.Now
	if now.IsZero() {
		now = time.Now()
	}
	c := &ctx{rules: rules, root: root, now: now}

	lines := []string{fmt.Sprintf("== %s 状態 %s ==", pyBasename(root), now.Format("01-02 15:04"))}
	for _, name := range rules.Sections {
		fn, known := sectionsByName[name]
		if !known {
			return 2, fmt.Errorf("規約ファイルの sections に知らない節があります: %s", name)
		}
		runSection(c, name, fn, &lines)
	}
	if len(lines) > rules.MaxLines {
		lines = append(lines[:rules.MaxLines],
			"  … (長すぎるので切った。bin/fge status で全文)")
	}
	out.WriteString(strings.Join(lines, "\n"))
	out.WriteString("\n")
	return 0, nil
}

// runSection は 1 つの節を走らせる。
// WhyNot: panic を握るのは、「1 区画が転んでも残りは出す」を守るため。
// ここで落とすと画面が丸ごと消える。
func runSection(c *ctx, name string, fn func(*ctx, *[]string), lines *[]string) {
	defer func() {
		if r := recover(); r != nil {
			*lines = append(*lines, fmt.Sprintf("(status: %s 区画で失敗 %T)", name, r))
		}
	}()
	fn(c, lines)
}

// resolveRoot は絶対・symlink をたどった実体の字面にそろえる。
func resolveRoot(root string) string {
	abs, err := filepath.Abs(root)
	if err != nil {
		abs = filepath.Clean(root)
	}
	if real, err := filepath.EvalSymlinks(abs); err == nil {
		abs = real
	}
	return filepath.ToSlash(abs)
}

// ParseNow は --now の値（Unix 秒。小数可）を時刻にする。
func ParseNow(s string) (time.Time, error) {
	v, err := strconv.ParseFloat(strings.TrimSpace(s), 64)
	if err != nil {
		return time.Time{}, fmt.Errorf("--now には Unix 秒を渡してください: %s", s)
	}
	sec := math.Floor(v)
	return time.Unix(int64(sec), int64(math.Round((v-sec)*1e9))), nil
}
