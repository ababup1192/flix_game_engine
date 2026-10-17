package jargon

// jargon — 独自の比喩語（このリポジトリでしか通じない言い回し）が新しく入るのを止める検査。
//
//	fge-go jargon              ステージした差分の + 行だけ（コミット時と同じ）
//	fge-go jargon --all        追跡ファイル全部
//	fge-go jargon a.md b.py    指定ファイルだけ
//	fge-go jargon --all --show-warn
//	fge-go jargon --self-test
//
// 見るのはコメントとドキュメントだけ。語のリストは bin/lint-rules/jargon.json が正。

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// skipPaths はこの検査自身。語で埋まっているので検査しない。
var skipPaths = map[string]bool{"bin/lint-jargon.py": true}

var (
	escapeRe   = regexp.MustCompile(`jargon-ok\s*[:：]`)
	stringLit  = regexp.MustCompile(`"(?:[^"\\\n]|\\.)*"`)
	inlineCode = regexp.MustCompile("`[^`]*`")
	// fenceRe は md のコードブロックの囲い。頭の空白は Unicode の空白すべてを許す。
	fenceRe = regexp.MustCompile("^[\\s\\v\\x{1c}-\\x{1f}\\x{85}\\p{Z}]*(?:```|~~~)")
	echoRe  = regexp.MustCompile(`@?echo\s+"([^"]*)"`)
	plusRe  = regexp.MustCompile(`\+(\d+)`)
)

// jsonDocKeys は JSON で説明として書かれるキー。
var jsonDocKeys = []string{"//", "note", "help", "label", "comment", "desc", "description"}

var jsonDocValueRe = func() []*regexp.Regexp {
	out := make([]*regexp.Regexp, 0, len(jsonDocKeys))
	for _, key := range jsonDocKeys {
		out = append(out, regexp.MustCompile(`"`+regexp.QuoteMeta(key)+`"\s*:\s*"((?:[^"\\]|\\.)*)"`))
	}
	return out
}()

// suffixKind は拡張子から言語を決める。上から順に見て最初に当たった物を採る。
var suffixKind = []struct{ suffix, kind string }{
	{".md", "md"}, {".flix", "flix"}, {".elm", "elm"}, {".json", "json"}, {".py", "py"},
	{".go", "go"}, {".sh", "sh"},
}

// kindOf はファイル名から言語を返す。対象外なら空文字。
func kindOf(path string) string {
	name := strings.ReplaceAll(path, `\`, "/")
	if i := strings.LastIndex(name, "/"); i >= 0 {
		name = name[i+1:]
	}
	if name == "Makefile" || strings.HasSuffix(name, ".mk") {
		return "make"
	}
	for _, sk := range suffixKind {
		if strings.HasSuffix(name, sk.suffix) {
			return sk.kind
		}
	}
	return ""
}

// ---------------------------------------------- コメント・文章だけ取り出す

// lineText は (行番号, 見る文字列)。
type lineText struct {
	lineno int
	text   string
}

// afterMarker は印より後ろを返す。found=false は「印が無い」。
//
// WhyNot: 文字列リテラルを消した側で位置を探すのに、切り出しは元の行から行う。
// 消した側で切ると、リテラルの中に書かれた印まで拾って行の途中から鳴る。
func afterMarker(line, marker string) (string, bool) {
	body := stringLit.ReplaceAllString(line, `""`)
	i := strings.Index(body, marker)
	if i < 0 {
		return "", false
	}
	at := utf8.RuneCountInString(body[:i])
	runes := []rune(line)
	if at >= len(runes) {
		return "", true
	}
	return string(runes[at:]), true
}

// jsonDocValues は 1 行から説明キーの値をつないで返す。
func jsonDocValues(line string) string {
	var out []string
	for _, re := range jsonDocValueRe {
		for _, m := range re.FindAllStringSubmatch(line, -1) {
			out = append(out, m[1])
		}
	}
	return strings.Join(out, " ")
}

// proseLines は (行番号, 見る文字列) を返す。
// wholeFile=false は差分の + 行（前後が見えないので複数行の追跡を全部やめる）。
func proseLines(kind string, lines []string, wholeFile bool) []lineText {
	var out []lineText
	fence := false // md のコードブロック
	block := false // Elm の {- -}
	quote := ""    // Python の docstring
	for i, line := range lines {
		text, has := "", false
		switch kind {
		case "md":
			if wholeFile && fenceRe.MatchString(line) {
				fence = !fence
				continue
			}
			if !fence {
				text, has = inlineCode.ReplaceAllString(line, ""), true
			}
		case "flix", "go":
			text, has = afterMarker(line, "//")
		case "sh":
			text, has = afterMarker(line, "#")
		case "elm":
			if wholeFile {
				switch {
				case block:
					text, has = line, true
					if strings.Contains(line, "-}") {
						block = false
					}
				case strings.Contains(line, "{-"):
					text, has = line, true
					block = !strings.Contains(line, "-}")
				}
			}
			if !has {
				text, has = afterMarker(line, "--")
			}
		case "json":
			text, has = jsonDocValues(line), true
		case "py":
			if wholeFile {
				matched := false
				for _, q := range []string{`"""`, `'''`} {
					if quote == q && strings.Contains(line, q) {
						quote, text, has, matched = "", line, true, true
						break
					}
					if quote == "" && strings.Count(line, q) == 1 {
						quote, text, has, matched = q, line, true, true
						break
					}
				}
				if !matched && quote != "" {
					text, has = line, true
				}
			}
			if !has {
				text, has = afterMarker(line, "#")
			}
		case "make":
			text, has = afterMarker(line, "#")
			if !has {
				var said []string
				for _, m := range echoRe.FindAllStringSubmatch(line, -1) {
					said = append(said, m[1])
				}
				text, has = strings.Join(said, " "), true
			}
		}
		if has && text != "" {
			out = append(out, lineText{i + 1, text})
		}
	}
	return out
}

// ---------------------------------------------------------------- 検査本体

type hit struct {
	path    string
	lineno  int
	rule    *Rule
	excerpt string
}

// excerptOf は前後の空白を落として先頭 70 文字を返す（バイト数でなく文字数）。
func excerptOf(text string) string {
	trimmed := strings.TrimFunc(text, unicode.IsSpace)
	runes := []rune(trimmed)
	if len(runes) > 70 {
		runes = runes[:70]
	}
	return string(runes)
}

func check(path, kind string, lines []string, rules []*Rule, wholeFile bool) []hit {
	var hits []hit
	for _, lt := range proseLines(kind, lines, wholeFile) {
		if escapeRe.MatchString(lt.text) {
			continue
		}
		for _, rule := range rules {
			if rule.Search(lt.text) {
				hits = append(hits, hit{path, lt.lineno, rule, excerptOf(lt.text)})
			}
		}
	}
	return hits
}

// checkJSONFile は JSON を構造で歩く（行ごとの正規表現より確実）。
// ok=false は「JSON として読めなかった」で、呼ぶ側は行ごとの検査へ落ちる。
func checkJSONFile(path, body string, rules []*Rule) ([]hit, bool) {
	values, err := jsonDocStrings(body)
	if err != nil {
		return nil, false
	}
	var hits []hit
	for _, value := range values {
		if escapeRe.MatchString(value) {
			continue
		}
		for _, rule := range rules {
			if rule.Search(value) {
				hits = append(hits, hit{path, 0, rule, excerptOf(value)})
			}
		}
	}
	return hits, true
}

// jsonDocStrings は JSON を上から順に歩いて、説明キーに直接ぶら下がる文字列だけを集める。
//
// WhyNot: json.Unmarshal で map に入れてから歩かないのは、Go の map の走査順が
// 毎回変わって出力の行順が走らせるたびに変わるため。読んだ順のまま歩く。
func jsonDocStrings(body string) ([]string, error) {
	dec := json.NewDecoder(strings.NewReader(body))
	var out []string
	if err := walkJSONValue(dec, "", &out); err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("JSON の後ろに余分な字があります")
	}
	return out, nil
}

func isJSONDocKey(key string) bool {
	for _, k := range jsonDocKeys {
		if k == key {
			return true
		}
	}
	return false
}

func walkJSONValue(dec *json.Decoder, key string, out *[]string) error {
	tok, err := dec.Token()
	if err != nil {
		return err
	}
	switch v := tok.(type) {
	case json.Delim:
		switch v {
		case '{':
			for dec.More() {
				keyTok, err := dec.Token()
				if err != nil {
					return err
				}
				name, _ := keyTok.(string)
				if err := walkJSONValue(dec, name, out); err != nil {
					return err
				}
			}
			_, err := dec.Token()
			return err
		case '[':
			for dec.More() {
				if err := walkJSONValue(dec, "", out); err != nil {
					return err
				}
			}
			_, err := dec.Token()
			return err
		}
		return fmt.Errorf("閉じ括弧が先に来ています")
	case string:
		if isJSONDocKey(key) {
			*out = append(*out, v)
		}
	}
	return nil
}

// ---------------------------------------------------------------- 入力の口

func gitOut(root string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("git %s に失敗しました: %v %s",
			strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}

// pending は差分から拾った 1 行。
type pending struct {
	path   string
	kind   string
	lineno int
	body   string
}

// stagedHits はステージした差分の + 行だけを見る。
func stagedHits(root string, rules []*Rule) ([]hit, error) {
	diff, err := gitOut(root, "diff", "--cached", "-U0", "--diff-filter=ACMR")
	if err != nil {
		return nil, err
	}
	return diffHits(diff, rules), nil
}

// diffHits は git の差分そのものから + 行だけを拾って検査する。
func diffHits(diff string, rules []*Rule) []hit {
	var queue []pending
	path, kind, lineno := "", "", 0
	for _, line := range pxlib.SplitLines(diff) {
		if strings.HasPrefix(line, "+++ b/") {
			path = line[6:]
			if skipPaths[path] || pxlib.InTestdata(path) {
				kind = ""
			} else {
				kind = kindOf(path)
			}
			continue
		}
		if strings.HasPrefix(line, "@@") {
			lineno = 0
			if m := plusRe.FindStringSubmatch(line); m != nil {
				lineno, _ = strconv.Atoi(m[1])
			}
			continue
		}
		if kind != "" && strings.HasPrefix(line, "+") && !strings.HasPrefix(line, "+++") {
			queue = append(queue, pending{path, kind, lineno, line[1:]})
			lineno++
		}
	}
	var hits []hit
	for _, p := range queue {
		for _, lt := range proseLines(p.kind, []string{p.body}, false) {
			if escapeRe.MatchString(lt.text) {
				continue
			}
			for _, rule := range rules {
				if rule.Search(lt.text) {
					hits = append(hits, hit{p.path, p.lineno, rule, excerptOf(lt.text)})
				}
			}
		}
	}
	return hits
}

// allPaths は追跡しているファイルのうち検査できる物を返す。
func allPaths(root string) ([]string, error) {
	out, err := gitOut(root, "ls-files", "-z")
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, p := range strings.Split(out, "\x00") {
		if p == "" || skipPaths[p] || pxlib.InTestdata(p) || kindOf(p) == "" {
			continue
		}
		paths = append(paths, p)
	}
	return paths, nil
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func fileHits(root string, paths []string, rules []*Rule) []hit {
	var hits []hit
	for _, p := range paths {
		full := p
		if !isFile(full) {
			full = filepath.Join(root, p)
		}
		if !isFile(full) {
			continue
		}
		kind := kindOf(p)
		if kind == "" || skipPaths[p] {
			continue
		}
		body, err := pxlib.LoadTextReplace(full)
		if err != nil {
			continue
		}
		if kind == "json" {
			if structured, ok := checkJSONFile(p, body, rules); ok {
				hits = append(hits, structured...)
				continue
			}
		}
		hits = append(hits, check(p, kind, pxlib.SplitLines(body), rules, true)...)
	}
	return hits
}

// ---------------------------------------------------------------- 出力

func report(out *strings.Builder, hits []hit, rules []*Rule, showWarn bool) int {
	var errors, warns []hit
	for _, h := range hits {
		if h.rule.Stage == "error" {
			errors = append(errors, h)
		} else {
			warns = append(warns, h)
		}
	}
	shown := errors
	if showWarn {
		shown = append(append([]hit{}, errors...), warns...)
	}
	for _, h := range shown {
		where := h.path
		if h.lineno != 0 {
			where = fmt.Sprintf("%s:%d", h.path, h.lineno)
		}
		mark := ""
		if h.rule.Stage == "warn" {
			mark = "注意 "
		}
		fmt.Fprintf(out, "  %s%s: 「%s」→ %s (%s)\n", mark, where, h.rule.Word, h.rule.Better, h.rule.English)
		fmt.Fprintf(out, "      %s\n", h.excerpt)
	}
	if len(errors) > 0 {
		fmt.Fprintf(out, "[lint-jargon] 独自語 %d 件。上の言い換えへ直すか、"+
			"本当に必要なら行末に jargon-ok: 理由 を書いてください\n", len(errors))
	}
	if len(warns) > 0 {
		fmt.Fprintf(out, "[lint-jargon] 注意 %d 件 (止めません): %s\n", len(warns), warnSummary(warns))
	}
	if len(hits) == 0 {
		fmt.Fprintf(out, "[lint-jargon] OK (%d 語で検査)\n", len(rules))
	}
	if len(errors) > 0 {
		return 1
	}
	return 0
}

// warnSummary は多い順に 8 語まで「語×件数」で並べる。
func warnSummary(warns []hit) string {
	var order []string
	count := map[string]int{}
	for _, h := range warns {
		if _, seen := count[h.rule.Word]; !seen {
			order = append(order, h.rule.Word)
		}
		count[h.rule.Word]++
	}
	// WhyNot: sort.Slice でなく安定な並べ替えにするのは、同じ件数の語の並びを
	// 「最初に出た順」に保つため。入れ替わると走らせるたびに字面が変わる。
	sort.SliceStable(order, func(i, j int) bool { return count[order[i]] > count[order[j]] })
	if len(order) > 8 {
		order = order[:8]
	}
	parts := make([]string, 0, len(order))
	for _, w := range order {
		parts = append(parts, fmt.Sprintf("%s×%d", w, count[w]))
	}
	return strings.Join(parts, " / ")
}

// ---------------------------------------------------------------- 自己検査

// selfTestWords は自己検査で使う 2 語 (error 段と warn 段を 1 つずつ)。
var selfTestWords = []wordEntry{
	{Word: strPtr("関所"), Pattern: nil, Better: strPtr("ゲート"), English: strPtr("gate"), Stage: strPtr("error")},
	{Word: strPtr("倒す"), Pattern: strPtr(`(既定|空)[^。]{0,12}へ?倒`), Better: strPtr("既定へ落とす"),
		English: strPtr("fall back"), Stage: strPtr("warn")},
}

func strPtr(s string) *string { return &s }

func selfTest(out *strings.Builder, root string) (int, error) {
	rules := make([]*Rule, 0, len(selfTestWords))
	for _, w := range selfTestWords {
		r, err := newRule(*w.Word, w.Pattern, *w.Better, *w.English, *w.Stage)
		if err != nil {
			return 1, err
		}
		rules = append(rules, r)
	}
	hits := func(kind, line string) bool {
		return len(check("x", kind, []string{line}, rules, false)) > 0
	}
	type expectation struct {
		name string
		got  bool
		want bool
	}
	checks := []expectation{
		{"既定へ倒す", rules[1].Search("既定へ倒す"), true},
		{"敵を倒す", rules[1].Search("敵を倒す"), false},
		{"flix のコメント", hits("flix", "// 関所で止める"), true},
		{"flix の文字列", hits("flix", `let msg = "関所を通っておくれ"`), false},
		{"flix の文字列とコメント", hits("flix", "let name = \"関所\" // ok"), false},
		{"md の本文", hits("md", "コミットの関所で止める"), true},
		{"md のコード", hits("md", "`関所` は使わない"), false},
		{"py のコメント", hits("py", "# 関所を通す"), true},
		{"elm のコメント", hits("elm", "-- 関所のあたり"), true},
		{"json の説明キー", hits("json", `{"note": "関所で止める"}`), true},
		{"json のセリフ", hits("json", `{"text": "関所を通っておくれ"}`), false},
		{"make の echo", hits("make", "\t@echo \"  make x   関所の検査\""), true},
		{"go のコメント", hits("go", "// 関所で止める"), true},
		{"go の文字列", hits("go", `msg := "関所を通っておくれ"`), false},
		{"sh のコメント", hits("sh", "# 関所で止める"), true},
		{"逃げ道の印", hits("flix", "// 関所で止める  jargon-ok: 説明のため"), false},
		{"md のコードの囲い", hits("md", "```"), false},
	}
	for _, c := range checks {
		if c.got != c.want {
			return 1, fmt.Errorf("self-test が落ちました: %s", c.name)
		}
	}

	real, err := LoadRules(root)
	if err != nil {
		return 1, err
	}
	var stopped []*Rule
	for _, r := range real {
		if r.Stage == "error" {
			stopped = append(stopped, r)
		}
	}
	// 止める語が増えすぎると --no-verify が常用されて仕組みごと死ぬ
	if len(stopped) > 15 {
		return 1, fmt.Errorf("self-test が落ちました: 止める語が %d 語", len(stopped))
	}
	for _, r := range stopped {
		for _, s := range []string{"武器を持つ", "改札を抜ける"} {
			if r.Search(s) {
				return 1, fmt.Errorf("self-test が落ちました: 「%s」が %s に当たる", r.Word, s)
			}
		}
	}
	fmt.Fprintf(out, "[lint-jargon] self-test OK (%d 語で止め、%d 語で知らせる)\n",
		len(stopped), len(real)-len(stopped))
	return 0, nil
}

// ---------------------------------------------------------------- 入口

func hasFlag(args []string, name string) bool {
	for _, a := range args {
		if a == name {
			return true
		}
	}
	return false
}

// Run は検査を走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（規約を読めないまま緑にしない）。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	if hasFlag(args, "--self-test") {
		return selfTest(out, root)
	}
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	var files []string
	for _, a := range args {
		if !strings.HasPrefix(a, "--") {
			files = append(files, a)
		}
	}
	var hits []hit
	switch {
	case len(files) > 0:
		hits = fileHits(root, files, rules)
	case hasFlag(args, "--all"):
		paths, err := allPaths(root)
		if err != nil {
			return 2, err
		}
		hits = fileHits(root, paths, rules)
	default:
		hits, err = stagedHits(root, rules)
		if err != nil {
			return 2, err
		}
	}
	return report(out, hits, rules, hasFlag(args, "--show-warn")), nil
}
