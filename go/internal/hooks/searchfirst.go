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
// WhyNot: 読めない・索引が間に合わない・当たりが無い時は何もせず grep を通す。壊れても今まで通りの動きに戻るだけにする。

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
	pat, at, ok := nameSearchOf(payload, r.SearchNudge.Suffix)
	if !ok {
		return 0
	}
	if seen, readable := markInTranscript(agentTranscript(payload)); !readable || seen {
		return 0
	}
	name := nameOfPattern(pat)
	project := projectRootOf(at)
	if name == "" || project == "" {
		return 0
	}
	answer := runUsages(project, name, 8*time.Second)
	if !firstHit.MatchString(answer) {
		return 0
	}
	reason := fmt.Sprintf("%s grep の代わりに索引で引いた（cd %s && bin/fge refactor usages %s）:\n%s\n"+
		"この答えで足りなければ、同じ grep をもう一度流せば通る（止めるのはこの担当の最初の 1 回だけ）。"+
		"本文は bin/fge refactor show <Mod.名前>、宣言の一覧は search <語>。文字列・文書・JSON の値は grep のままで良い。",
		searchFirstMark, project, name, clip(answer, 60))
	js, _ := json.Marshal(map[string]any{"hookSpecificOutput": map[string]any{
		"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}})
	fmt.Fprintln(out, string(js))
	return 0
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

// markInTranscript は記録に searchFirstMark があるか。2 つ目は読めたか（読めなければ見分けられない）。
func markInTranscript(path string) (seen, readable bool) {
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
		if strings.Contains(sc.Text(), searchFirstMark) {
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

// runUsages は project で bin/fge refactor usages を流した出力（時間切れ・失敗は空）。
func runUsages(project, name string, limit time.Duration) string {
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	cmd := exec.CommandContext(ctx, filepath.Join(project, "bin", "fge"), "refactor", "usages", name)
	cmd.Dir = project
	b, _ := cmd.CombinedOutput()
	if ctx.Err() != nil {
		return ""
	}
	return string(b)
}

// clip は s を先頭の n 行に切る。
func clip(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) <= n {
		return strings.Join(lines, "\n")
	}
	return strings.Join(lines[:n], "\n") + fmt.Sprintf("\n…（ほか %d 行）", len(lines)-n)
}
