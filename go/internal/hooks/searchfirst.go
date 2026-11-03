package hooks

// hook-search-first (PreToolUse・Grep / Bash) — .flix の名前を字で探す最初の 1 回だけ、grep の代わりに索引の答えを返す。
//
// 当てる形は hook-search-nudge と同じ（NameSearchOnFlix）。探した字から名前を取り出して `bin/fge refactor usages` を
// 探した場所のプロジェクトで流し、当たりがあれば grep を止めて（permissionDecision: deny）その答えを理由として返す。
// 「最初の 1 回」は担当の作業の記録（transcript）に searchFirstMark がまだ無いことで見分ける。
// 担当がもう一度 grep を流すと、記録に印があるので通す。
//
// WhyNot: 印のファイルを書かない。書けない・消し忘れ・記録とのずれで、止め続けたり止めなかったりする。
// 担当が実際に受け取った物（記録）を読めば、それ自体が「もう止めた」の証になる。
// WhyNot: sed の行読みの印（lineReadMark）を grep の印と分ける。1 つにすると、先に grep で止められた担当の sed は止まらない。
// WhyNot: 読めない・当たりが無い時は何もせず通す。壊れても今まで通りの動きに戻るだけにする。
// WhyNot: 索引が時間内に答えない時も、形で名前と決まる字（def の行・camelCase・Mod.名前）は通さない。engine の根では
// 索引を作り直す間（10 秒ほど）に毎回間に合わず、担当の grep が全部止まらずに通っていた。答えの代わりに打つコマンドを返す。

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// searchFirstMark は止めた時の理由の頭に置く決まり文句。記録の中でこれを探して 2 回目を見分ける。
const searchFirstMark = "[fge 索引の答え]"

// lateMark は索引が間に合わずに止めた時の決まり文句。
// WhyNot: searchFirstMark を使わない。答えを返さずに止めた回で一度きりの止めを使い切ると、後の名前の grep が全部止まらずに通る。
const lateMark = "[fge 索引待ち]"

var fileExt = regexp.MustCompile(`\.(png|jpe?g|json|wav|ogg|flix|md|txt|toml|glb|obj|mtl|ttf|csv|tsv|log)$`)

// strongName は索引の答えを見ずに名前と決めてよい形か（def の行・camelCase・Mod.名前。ファイルの名前と小文字の 1 語は除く）。
// WhyNot: 答えを見ない時は、索引で当たり無しと分かれば通す字（ログの語・Player.png）まで止めてしまう。
func strongName(pat string) bool {
	for _, alt := range strings.Split(strings.ReplaceAll(pat, `\|`, "|"), "|") {
		alt = strings.TrimSuffix(strings.TrimPrefix(alt, `\b`), `\b`)
		if fileExt.MatchString(alt) {
			continue
		}
		if nudgeDef.MatchString(alt) || nudgeQual.MatchString(alt) || nudgeType.MatchString(alt) || nudgeCamel.MatchString(alt) {
			return true
		}
	}
	return false
}

// searchFirstLimit は索引の答えを待つ長さ（フックの timeout 15 秒の内）。
var searchFirstLimit = 8 * time.Second

// lineReadMark は .flix の行の範囲を読む sed を止めた時の決まり文句（grep の印と別に数える）。
const lineReadMark = "[fge 宣言の一覧]"

var (
	firstQualified = regexp.MustCompile(`[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+`)
	firstDefName   = regexp.MustCompile(`\bdef\s+([a-z][A-Za-z0-9_]*)`)
	firstWord      = regexp.MustCompile(`[A-Za-z_][A-Za-z0-9_]*`)
	firstHit       = regexp.MustCompile(`\.flix:\d+`)
)

// RunSearchFirst は名前の字の検索の最初の 1 回だけ、索引の答えを返して grep を止める。いつも 0。
func RunSearchFirst(out io.Writer, root, fallback string, in io.Reader) int {
	payload, ok := ReadPayload(in)
	if !ok {
		return 0
	}
	r := LoadGuardRules(root, fallback, func(r *Rules) bool { return r.SearchNudge != nil })
	if r == nil {
		return 0
	}
	deadline := time.Now().Add(searchFirstLimit)
	if reason := lineReadReason(payload, r.SearchNudge.Suffix, searchFirstLimit); reason != "" {
		denyWith(out, reason)
		return 0
	}
	pat, at, ok := nameSearchOf(payload, r.SearchNudge.Suffix)
	if !ok {
		return 0
	}
	if seen, readable := markInTranscript(agentTranscript(payload), searchFirstMark); !readable || seen {
		return 0
	}
	name := nameOfPattern(pat)
	project := projectRootOf(at)
	if name == "" || project == "" {
		return 0
	}
	answer, late := runRefactor(project, time.Until(deadline), "usages", name)
	switch {
	case late && strongName(pat):
		if seen, readable := markInTranscript(agentTranscript(payload), lateMark); !readable || seen {
			return 0
		}
		denyWith(out, fmt.Sprintf("%s 索引が %s の答えに間に合わなかった（裏で作っている）。grep の代わりに打つ: cd %s && bin/fge refactor usages %s"+
			"（本文は show <Mod.名前>・宣言は search <語>）。字で探すのが正しい物（文字列・コメント・ログ・文書）なら、同じ grep をもう一度流せば通る。",
			lateMark, name, project, name))
	case firstHit.MatchString(answer):
		denyWith(out, fmt.Sprintf("%s grep の代わりに索引で引いた（cd %s && bin/fge refactor usages %s）:\n%s\n"+
			"この答えで足りなければ、同じ grep をもう一度流せば通る（止めるのはこの担当の最初の 1 回だけ）。"+
			"本文は bin/fge refactor show <Mod.名前>、宣言の一覧は search <語>。文字列・文書・JSON の値は grep のままで良い。",
			searchFirstMark, project, name, clip(answer, 60)))
	}
	return 0
}

func denyWith(out io.Writer, reason string) {
	js, _ := json.Marshal(map[string]any{"hookSpecificOutput": map[string]any{
		"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}})
	fmt.Fprintln(out, string(js))
}

var sedLines = regexp.MustCompile(`^(\d+)(?:,(\d+))?p$`)

// lineReadOf は .flix の行の範囲を読む `sed -n A,Bp X.flix` から、ファイルと範囲を取り出す。
func lineReadOf(p Payload, suffix string) (file string, from, to int, ok bool) {
	cmd := p.sub("tool_input").str("command")
	if cmd == "" || suffix == "" {
		return "", 0, 0, false
	}
	dir := p.str("cwd")
	for _, seg := range shellSegments(cmd) {
		w := shellWords(strings.TrimSpace(seg))
		if len(w) == 2 && w[0] == "cd" {
			dir = resolveDir(dir, w[1])
			continue
		}
		if len(w) < 4 || w[0] != "sed" || w[1] != "-n" {
			continue
		}
		m := sedLines.FindStringSubmatch(w[2])
		if m == nil || !strings.HasSuffix(w[3], suffix) || strings.ContainsAny(w[3], "*?") {
			continue
		}
		fmt.Sscanf(m[1], "%d", &from)
		to = from
		if m[2] != "" {
			fmt.Sscanf(m[2], "%d", &to)
		}
		return resolveDir(dir, w[3]), from, to, true
	}
	return "", 0, 0, false
}

// lineReadReason は sed の行読みを止める理由（その範囲にかかる宣言と show のコマンド）。止めない時は空。
func lineReadReason(p Payload, suffix string, limit time.Duration) string {
	file, from, to, ok := lineReadOf(p, suffix)
	if !ok {
		return ""
	}
	if seen, readable := markInTranscript(agentTranscript(p), lineReadMark); !readable || seen {
		return ""
	}
	project := projectRootOf(file)
	if project == "" {
		return ""
	}
	rel, err := filepath.Rel(project, file)
	if err != nil {
		return ""
	}
	answer, late := runRefactor(project, limit, "outline", filepath.ToSlash(rel), "--json")
	if late {
		return fmt.Sprintf("%s 索引が間に合わなかった（裏で作っている）。行の番号で読む代わりに打つ: cd %s && bin/fge refactor outline %s"+
			"（宣言の一覧）→ bin/fge refactor show <Mod.名前>（本文だけ）。宣言の外（ファイルの頭・コメント）を読むなら、同じ sed をもう一度流せば通る。",
			lineReadMark, project, filepath.ToSlash(rel))
	}
	decls := declsInRange(answer, from, to)
	if len(decls) == 0 {
		return ""
	}
	var b strings.Builder
	for _, d := range decls {
		fmt.Fprintf(&b, "  %d  %s %s → bin/fge refactor show %s\n", d.Line, d.Kind, d.Sym, d.Sym)
	}
	return fmt.Sprintf("%s %s の %d〜%d 行にかかる宣言（cd %s && bin/fge refactor outline %s）:\n%s"+
		"本文は show で読める（/// と注記から本文の終わりまで・頭の行に file:始め-終わり）。宣言の外を読むなら、同じ sed をもう一度流せば通る。",
		lineReadMark, filepath.ToSlash(rel), from, to, project, filepath.ToSlash(rel), b.String())
}

type outlineDecl struct {
	Line int    `json:"line"`
	Kind string `json:"kind"`
	Sym  string `json:"sym"`
}

// declsInRange は outline --json の答えから、from〜to の行にかかる宣言（範囲の頭を含む 1 つ前の宣言から、範囲の中で始まる物まで）。
func declsInRange(answer string, from, to int) []outlineDecl {
	var js struct {
		Found []outlineDecl `json:"found"`
	}
	start := strings.Index(answer, "{")
	if start < 0 || json.Unmarshal([]byte(answer[start:]), &js) != nil {
		return nil
	}
	var out []outlineDecl
	var before *outlineDecl
	for i, d := range js.Found {
		if d.Kind == "case" {
			continue
		}
		switch {
		case d.Line < from:
			before = &js.Found[i]
		case d.Line <= to:
			out = append(out, d)
		}
	}
	if before != nil && (len(out) == 0 || out[0].Line > from) {
		out = append([]outlineDecl{*before}, out...)
	}
	return out
}

// agentTranscript は担当自身の作業の記録の場所。サブエージェントには親の記録の場所と agent_id が渡るので、
// 親の記録の隣の subagents/agent-<id>.jsonl を指す。
func agentTranscript(p Payload) string {
	t := p.TranscriptPath()
	if id := p.str("agent_id"); id != "" && t != "" {
		return filepath.Join(strings.TrimSuffix(t, ".jsonl"), "subagents", "agent-"+id+".jsonl")
	}
	return t
}

// markInTranscript は記録に mark があるか。2 つ目は読めたか（読めなければ見分けられない）。
func markInTranscript(path, mark string) (seen, readable bool) {
	if path == "" {
		return false, false
	}
	f, err := os.Open(path)
	if err != nil {
		return false, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		if strings.Contains(sc.Text(), mark) {
			return true, true
		}
	}
	return false, sc.Err() == nil
}

// nameOfPattern は grep の字から索引で引く名前を取り出す（Mod.名前 → def の名前 → 一番長い語の順）。
func nameOfPattern(pat string) string {
	pat = strings.NewReplacer(`\.`, ".", `\b`, " ", `\s`, " ", `\(`, " ", `\)`, " ", `\|`, " ", `\?`, " ", `^`, " ", `$`, " ").Replace(pat)
	if m := firstQualified.FindString(pat); m != "" {
		return m
	}
	if m := firstDefName.FindStringSubmatch(pat); m != nil {
		return m[1]
	}
	best := ""
	for _, w := range firstWord.FindAllString(pat, -1) {
		if w != "def" && w != "pub" && len(w) > len(best) {
			best = w
		}
	}
	return best
}

// projectRootOf は at から上へたどって、flix.toml と bin/fge のあるフォルダを返す。
func projectRootOf(at string) string {
	d := at
	if st, err := os.Stat(d); err == nil && !st.IsDir() {
		d = filepath.Dir(d)
	}
	for i := 0; i < 8 && d != "" && d != "/" && d != "."; i++ {
		if fileExists(filepath.Join(d, "flix.toml")) && fileExists(filepath.Join(d, "bin", "fge")) {
			return d
		}
		d = filepath.Dir(d)
	}
	return ""
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// runRefactor は project で bin/fge refactor <args> を流した出力。late は時間切れ（出力は空）。
func runRefactor(project string, limit time.Duration, args ...string) (answer string, late bool) {
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(project, "bin", "fge"), append([]string{"refactor"}, args...)...)
	cmd.Dir = project
	// WhyNot: 時間切れで止めるのは bin/fge だけで、その子（索引を作る flixlint）は出力の管を持ったまま走り続ける。
	// 管が閉じるのを待たないよう、待つ長さを切る。
	cmd.WaitDelay = 300 * time.Millisecond
	b, _ := cmd.CombinedOutput()
	if ctx.Err() != nil {
		return "", true
	}
	return string(b), false
}

// clip は s を先頭の n 行に切る。
func clip(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) <= n {
		return strings.Join(lines, "\n")
	}
	return strings.Join(lines[:n], "\n") + fmt.Sprintf("\n…（ほか %d 行）", len(lines)-n)
}
