package hooks

// hook-search-nudge (PostToolUse・Grep / Bash) — .flix の名前を字で探した後に、索引で引く道具を案内する。
//
// 当てる形: Grep の道具か、Bash の grep・rg・git grep で、探す字が名前（`def 名前`・`Mod.名前`・camelCase の語）で、
// 探す先が .flix（glob・type・パス・--include の .flix か、src/・test/ の下）の物。案内は additionalContext で返し、
// 呼び出しは止めない。担当（セッション × サブエージェント × 記録のファイル）ごとに、名前の字の検索を数え、
// 1 回目と、その後 Every 回ごとに案内する（数は <cache>/fge/search-nudge/<担当のハッシュ> に持つ）。
//
// WhyNot: 止めない（exit 2 にしない）。字で探すのが正しい時（文書の言葉・JSON の値・コメントの語）を見分けられず、
// 止めると正しい探し方まで 1 手増える。
// WhyNot: セッションに 1 回にしない。サブエージェントも、そこから立てた claude -p も同じ session_id を持つので、
// 最初の 1 人が案内を受けると、後の担当は誰も受けない。1 回で終わらせないのは、案内を読み流した担当が
// そのまま grep を続けるため（数を添えて言い直すと、続けていることに気づける）。

import (
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// SearchNudge は hook-search-nudge の設定（bin/lint-rules/hooks.json の searchNudge）。
type SearchNudge struct {
	Suffix  string `json:"suffix"`
	Message string `json:"message"`
	// Every は 1 回目の後に何回ごとに言い直すか（0 なら 1 回目だけ）。
	Every int `json:"every"`
}

var (
	nudgeDef       = regexp.MustCompile(`\bdef\b`)
	nudgeQual      = regexp.MustCompile(`\b[A-Z][A-Za-z0-9]*\.[a-z][A-Za-z0-9_]*\b`)
	nudgeCamel     = regexp.MustCompile(`^\\?b?[a-z][a-z0-9]*[A-Z][A-Za-z0-9]*(\\b)?$`)
	nudgeType      = regexp.MustCompile(`\b[A-Z][A-Za-z0-9]*\.[A-Z][A-Za-z0-9_]*\b`)
	nudgeRecursive = regexp.MustCompile(`\s-[a-zA-Z]*[rR]|\s--recursive`)
	nudgeUpper     = regexp.MustCompile(`^\\?b?[A-Z][a-z0-9]+(?:[A-Z][A-Za-z0-9]*)?(\\b)?$`)
	nudgeTool      = regexp.MustCompile(`^(sudo\s+)?(grep|egrep|rg|git\s+grep)\b`)
)

// RunSearchNudge は .flix の名前を字で探した呼び出しの後に、案内を 1 回だけ返す。いつも 0（止めない）。
func RunSearchNudge(out io.Writer, root, fallback string, in io.Reader) int {
	payload, ok := ReadPayload(in)
	if !ok {
		return 0
	}
	r := LoadGuardRules(root, fallback, func(r *Rules) bool { return r.SearchNudge != nil && r.SearchNudge.Message != "" })
	if r == nil {
		return 0
	}
	g := r.SearchNudge
	if !NameSearchOnFlix(payload, g.Suffix) {
		return 0
	}
	n := countNudge(nudgeMark(payload))
	if !nudgeDue(n, g.Every) {
		return 0
	}
	msg := g.Message
	if n > 1 {
		msg = fmt.Sprintf("（.flix の名前を字で探したのはこの担当で %d 回目）%s", n, msg)
	}
	js, _ := json.Marshal(map[string]any{"hookSpecificOutput": map[string]any{
		"hookEventName": "PostToolUse", "additionalContext": msg}})
	fmt.Fprintln(out, string(js))
	return 0
}

// nudgeDue は n 回目の名前の字の検索で案内するか（1 回目と、その後 every 回ごと）。
func nudgeDue(n, every int) bool {
	if n == 1 {
		return true
	}
	return every > 0 && n > 1 && (n-1)%every == 0
}

// countNudge は印の数を 1 つ増やして、増やした後の数を返す。印を置けない時は毎回 1（毎回案内する）。
func countNudge(mark string) int {
	if mark == "" {
		return 1
	}
	n := 0
	if b, err := os.ReadFile(mark); err == nil {
		fmt.Sscanf(strings.TrimSpace(string(b)), "%d", &n)
	}
	n++
	if os.MkdirAll(filepath.Dir(mark), 0o755) == nil {
		os.WriteFile(mark, []byte(fmt.Sprintf("%d\n", n)), 0o644)
	}
	return n
}

// NameSearchOnFlix は呼び出しが .flix の中を名前で字の検索をした物か。
func NameSearchOnFlix(p Payload, suffix string) bool {
	_, _, ok := nameSearchOf(p, suffix)
	return ok
}

// nameSearchOf は .flix の中を名前で字の検索をした呼び出しから、探した字と探した場所を取り出す。
func nameSearchOf(p Payload, suffix string) (pat, dir string, ok bool) {
	ti := p.sub("tool_input")
	cwd := p.str("cwd")
	if pat := ti.str("pattern"); pat != "" && ti.str("command") == "" {
		target := ti.str("glob") + " " + ti.str("path") + " " + ti.str("type")
		at := resolveDir(cwd, ti.str("path"))
		if !nameLike(pat) {
			return "", "", false
		}
		if flixTarget(target, suffix) || ti.str("type") == "flix" {
			return pat, at, true
		}
		// glob や type で .flix 以外に絞った検索は、探す先が Flix のプロジェクトでも .flix を見ていない。
		return pat, at, ti.str("glob") == "" && ti.str("type") == "" && flixProjectDir(at)
	}
	cmd := ti.str("command")
	if cmd == "" {
		return "", "", false
	}
	dir = cwd
	for _, seg := range shellSegments(cmd) {
		seg = strings.TrimSpace(seg)
		if w := shellWords(seg); len(w) == 2 && w[0] == "cd" {
			dir = resolveDir(dir, w[1])
			continue
		}
		if !nudgeTool.MatchString(seg) {
			continue
		}
		words := shellWords(seg)
		pat, rest := "", []string{}
		for _, w := range words[1:] {
			if w == "grep" || strings.HasPrefix(w, "-") && !strings.Contains(w, "=") {
				continue
			}
			if pat == "" && !strings.HasPrefix(w, "--include") {
				pat = w
				continue
			}
			rest = append(rest, w)
		}
		if pat == "" || !nameLike(pat) {
			continue
		}
		if flixTarget(strings.Join(rest, " ")+" "+seg, suffix) || searchesFlixProject(seg, rest, dir) {
			at := dir
			for _, w := range rest {
				if !strings.HasPrefix(w, "-") {
					at = resolveDir(dir, w)
					break
				}
			}
			return pat, at, true
		}
	}
	return "", "", false
}

// nameLike は探す字が Flix の名前を探す形か（def の行・Mod.名前・Mod.Type・camelCase か大文字で始まる 1 語）。
func nameLike(pat string) bool {
	return nudgeDef.MatchString(pat) || nudgeQual.MatchString(pat) || nudgeType.MatchString(pat) ||
		nudgeCamel.MatchString(pat) || nudgeUpper.MatchString(pat)
}

// searchesFlixProject は grep・rg が Flix のプロジェクトの根か .flix を直に持つフォルダを、中まで探したか。
// 探す先を書かない rg・git grep と grep -r は、今いるフォルダを探す。
func searchesFlixProject(seg string, rest []string, dir string) bool {
	recursive := !strings.HasPrefix(seg, "grep") && !strings.HasPrefix(seg, "egrep") || nudgeRecursive.MatchString(seg)
	if !recursive {
		return false
	}
	paths := 0
	for _, w := range rest {
		if strings.HasPrefix(w, "-") || strings.HasPrefix(w, "--include") {
			continue
		}
		paths++
		if flixProjectDir(resolveDir(dir, w)) {
			return true
		}
	}
	return paths == 0 && flixProjectDir(dir)
}

// flixProjectDir は d が Flix のプロジェクトの根（flix.toml がある）か、.flix を直に持つフォルダか。
// WhyNot: 上へたどって flix.toml を探さない。docs/ のようなプロジェクトの中の .flix の無いフォルダまで拾ってしまう。
func flixProjectDir(d string) bool {
	if d == "" {
		return false
	}
	if st, err := os.Stat(filepath.Join(d, "flix.toml")); err == nil && !st.IsDir() {
		return true
	}
	m, _ := filepath.Glob(filepath.Join(d, "*.flix"))
	return len(m) > 0
}

// resolveDir は dir から見た p の場所（p が空なら dir）。
func resolveDir(dir, p string) string {
	p = strings.Trim(p, `"'`)
	if p == "" {
		return dir
	}
	if filepath.IsAbs(p) || dir == "" {
		return p
	}
	return filepath.Join(dir, p)
}

// flixTarget は探す先が .flix か、src/・test/ の下か。
func flixTarget(s, suffix string) bool {
	if suffix != "" && strings.Contains(s, suffix) {
		return true
	}
	for _, w := range strings.Fields(s) {
		w = strings.Trim(w, `"'`)
		if w == "src" || w == "test" || strings.HasPrefix(w, "src/") || strings.HasPrefix(w, "test/") ||
			strings.Contains(w, "/src/") || strings.HasSuffix(w, "/src") {
			return true
		}
	}
	return false
}

// nudgeMark は担当ごとの印の置き場。担当はセッション・サブエージェント（agent_id）・記録のファイルの組で見分ける。
func nudgeMark(p Payload) string {
	who := p.SessionID() + "\x00" + p.str("agent_id") + "\x00" + p.TranscriptPath()
	if who == "\x00\x00" {
		return ""
	}
	dir, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	h := sha1.Sum([]byte(who))
	return filepath.Join(dir, "fge", "search-nudge", hex.EncodeToString(h[:8]))
}
