package hooks

// hook-search-nudge (PostToolUse・Grep / Bash) — .flix の名前を字で探した後に、索引で引く道具を 1 回だけ案内する。
//
// 当てる形: Grep の道具か、Bash の grep・rg・git grep で、探す字が名前（`def 名前`・`Mod.名前`・camelCase の語）で、
// 探す先が .flix（glob・type・パス・--include の .flix か、src/・test/ の下）の物。案内は additionalContext で返し、
// 呼び出しは止めない。同じセッションでは 1 回だけ（印は <cache>/fge/search-nudge/<session のハッシュ>）。
//
// WhyNot: 止めない（exit 2 にしない）。字で探すのが正しい時（文書の言葉・JSON の値・コメントの語）を見分けられず、
// 止めると正しい探し方まで 1 手増える。案内は索引の道具を知らない時だけ効けばよいので、セッションに 1 回。

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
}

var (
	nudgeDef   = regexp.MustCompile(`\bdef\b`)
	nudgeQual  = regexp.MustCompile(`\b[A-Z][A-Za-z0-9]*\.[a-z][A-Za-z0-9_]*\b`)
	nudgeCamel = regexp.MustCompile(`^\\?b?[a-z][a-z0-9]*[A-Z][A-Za-z0-9]*(\\b)?$`)
	nudgeTool  = regexp.MustCompile(`^(sudo\s+)?(grep|egrep|rg|git\s+grep)\b`)
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
	mark := nudgeMark(payload.SessionID())
	if mark != "" {
		if _, err := os.Stat(mark); err == nil {
			return 0
		}
		if os.MkdirAll(filepath.Dir(mark), 0o755) == nil {
			os.WriteFile(mark, nil, 0o644)
		}
	}
	js, _ := json.Marshal(map[string]any{"hookSpecificOutput": map[string]any{
		"hookEventName": "PostToolUse", "additionalContext": g.Message}})
	fmt.Fprintln(out, string(js))
	return 0
}

// NameSearchOnFlix は呼び出しが .flix の中を名前で字の検索をした物か。
func NameSearchOnFlix(p Payload, suffix string) bool {
	ti := p.sub("tool_input")
	if pat := ti.str("pattern"); pat != "" && ti.str("command") == "" {
		target := ti.str("glob") + " " + ti.str("path") + " " + ti.str("type")
		return nameLike(pat) && (flixTarget(target, suffix) || ti.str("type") == "flix")
	}
	cmd := ti.str("command")
	if cmd == "" {
		return false
	}
	for _, seg := range shellSegment.Split(cmd, -1) {
		seg = strings.TrimSpace(seg)
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
		if pat != "" && nameLike(pat) && flixTarget(strings.Join(rest, " ")+" "+seg, suffix) {
			return true
		}
	}
	return false
}

// nameLike は探す字が Flix の名前を探す形か（def の行・Mod.名前・camelCase の 1 語）。
func nameLike(pat string) bool {
	return nudgeDef.MatchString(pat) || nudgeQual.MatchString(pat) || nudgeCamel.MatchString(pat)
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

func nudgeMark(session string) string {
	if session == "" {
		return ""
	}
	dir, err := os.UserCacheDir()
	if err != nil {
		return ""
	}
	h := sha1.Sum([]byte(session))
	return filepath.Join(dir, "fge", "search-nudge", hex.EncodeToString(h[:8]))
}
