// Package doclookup は AI が最初に打つ 3 つの引き物（api・module・src）を持つ。
//
//	api    … engine の docs/api-digest/*.md から Q を含む行（grep -i・最大 40 行）
//	module … engine の docs/modules/*.md から Q を含む行を「分野のファイル:行  本文」の形に（engine.md は最後）
//	src    … ゲームの src/**/*.flix の pub 定義と mod を「ファイル:行: 定義」にし、Q を含む行
//
// 出力は make api・make module・make src（mk/common.mk・mk/game.mk の旧レシピ）と同じ形にそろえる。
//
// WhyNot: awk・sed・find を Git Bash で起こさない — 引くだけの道具に sh を挟むと、Windows の PowerShell から打てない。
package doclookup

import (
	"bufio"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode/utf8"
)

// MaxLines は 1 回に出す行の上限（旧レシピの head -40）。
const MaxLines = 40

// API は engine の根 engine の docs/api-digest から Q を引いて out に書く。
func API(out io.Writer, engine, q string) int {
	if q == "" {
		fmt.Fprintln(out, "usage: bin/fge api <関数名やモジュール名>（make api Q=<…> も同じ）")
		return 1
	}
	re := compileGrep(q)
	files, _ := filepath.Glob(filepath.Join(engine, "docs", "api-digest", "*.md"))
	sort.Strings(files)
	var hits []string
	for _, f := range files {
		eachLine(f, func(_ int, line string) bool {
			if re.MatchString(line) {
				hits = append(hits, line)
			}
			return len(hits) < MaxLines
		})
		if len(hits) >= MaxLines {
			break
		}
	}
	if len(hits) == 0 {
		fmt.Fprintf(out, "[api] '%s' に当たりなし。bin/fge module <やりたいこと> で別名を探す\n", q)
		return 0
	}
	writeLines(out, hits)
	return 0
}

// Module は engine の docs/modules/*.md から Q を（固定の字として・大小を問わず）引いて out に書く。
// prefix は行の頭に付ける engine の前置き（engine の根で打てば空・ゲームでは "<ENGINE>/"）。
func Module(out io.Writer, engine, prefix, q string) int {
	if q == "" {
		fmt.Fprintln(out, "usage: bin/fge module <やりたいこと・モジュール名の一部>（make module Q=<…> も同じ）")
		return 1
	}
	re := regexp.MustCompile("(?i)" + regexp.QuoteMeta(q))
	dir := filepath.Join(engine, "docs", "modules")
	entries, _ := os.ReadDir(dir)
	var names []string
	hasEngine := false
	for _, e := range entries {
		n := e.Name()
		if e.IsDir() || !strings.HasSuffix(n, ".md") {
			continue
		}
		// WhyNot: engine.md（engine/src の下請け）を最後に引くのは、ゲームが使う engine_world の行を先に見せるため。
		if n == "engine.md" {
			hasEngine = true
			continue
		}
		names = append(names, n)
	}
	sort.Strings(names)
	if hasEngine {
		names = append(names, "engine.md")
	}
	var hits []string
	for _, n := range names {
		shown := prefix + "docs/modules/" + n
		eachLine(filepath.Join(dir, n), func(no int, line string) bool {
			if !re.MatchString(line) {
				return true
			}
			if s, keep := moduleLine(shown, no, line); keep {
				hits = append(hits, s)
			}
			return len(hits) < MaxLines
		})
		if len(hits) >= MaxLines {
			break
		}
	}
	if len(hits) == 0 {
		fmt.Fprintf(out, "[module] '%s' に当たりなし。別の言い方で引き直すか、分野の目次 %sdocs/module-index.md から分野のファイルを開く\n", q, prefix)
		return 0
	}
	writeLines(out, hits)
	return 0
}

var (
	moduleTableRe = regexp.MustCompile(`^\| ([^|]*) \| (.*) \|$`)
	moduleItemRe  = regexp.MustCompile(`^- \*\*([^*]*)\*\*`)
)

// moduleLine は当たった 1 行を読みやすい形にする（旧 mk/module.sed）。見出しの決まり文句は落とす（keep=false）。
func moduleLine(file string, no int, text string) (string, bool) {
	head := fmt.Sprintf("%s:%d", file, no)
	switch {
	case strings.HasPrefix(text, "> "),
		text == "| やりたいこと | モジュール |",
		text == "| 症状 | モジュール |",
		strings.HasPrefix(text, "|---"):
		return "", false
	}
	if m := moduleTableRe.FindStringSubmatch(text); m != nil {
		return head + "  " + m[1] + " → " + m[2], true
	}
	if m := moduleItemRe.FindStringSubmatchIndex(text); m != nil {
		return head + "  " + text[m[2]:m[3]] + text[m[1]:], true
	}
	return head + "  " + text, true
}

// Src はゲームの根 game の src/ から pub 定義を引き、Q を含む行を out に書く。
func Src(out io.Writer, game, q string) int {
	if q == "" {
		fmt.Fprintln(out, "usage: bin/fge src <関数名や型名>（make src Q=<…> も同じ）")
		return 1
	}
	re := compileGrep(q)
	var files []string
	_ = filepath.WalkDir(filepath.Join(game, "src"), func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() && strings.HasSuffix(d.Name(), ".flix") {
			rel, rerr := filepath.Rel(game, path)
			if rerr == nil {
				files = append(files, filepath.ToSlash(rel))
			}
		}
		return nil
	})
	sort.Strings(files)
	var hits []string
	for _, f := range files {
		eachLine(filepath.Join(game, filepath.FromSlash(f)), func(no int, line string) bool {
			d, ok := srcDecl(line)
			if !ok {
				return true
			}
			s := fmt.Sprintf("%s:%d: %s", f, no, d)
			if re.MatchString(s) {
				hits = append(hits, s)
			}
			return len(hits) < MaxLines
		})
		if len(hits) >= MaxLines {
			break
		}
	}
	if len(hits) == 0 {
		fmt.Fprintf(out, "[src] '%s' の pub 定義なし。grep -n '%s' -r src で使われ方を探す\n", q, q)
		return 0
	}
	writeLines(out, hits)
	return 0
}

var (
	srcDeclRe  = regexp.MustCompile(`^[ \t]*(pub[ \t]+((opaque|lawful|sealed)[ \t]+)*(def|enum|type|trait|eff|struct)|mod)[ \t]`)
	srcLeadRe  = regexp.MustCompile(`^[ \t]+`)
	srcTrailRe = regexp.MustCompile(`[ \t]*(=|\{)[ \t]*$`)
)

// srcDecl は 1 行が pub 定義か mod なら、頭の空白と末尾の = / { を落とした形を返す（旧 mk/src-index.awk）。
func srcDecl(line string) (string, bool) {
	if !srcDeclRe.MatchString(line) {
		return "", false
	}
	d := srcLeadRe.ReplaceAllString(line, "")
	if loc := srcTrailRe.FindStringIndex(d); loc != nil {
		d = d[:loc[0]]
	}
	if utf8.RuneCountInString(d) > 160 {
		d = string([]rune(d)[:157]) + "..."
	}
	return d, true
}

// eachLine は path を 1 行ずつ（改行を落として・1 から数えて）fn に渡す。fn が false を返したら止める。
func eachLine(path string, fn func(no int, line string) bool) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for no := 1; sc.Scan(); no++ {
		if !fn(no, sc.Text()) {
			return
		}
	}
}

func writeLines(out io.Writer, lines []string) {
	for _, l := range lines {
		fmt.Fprintln(out, l)
	}
}

// compileGrep は grep -i の基本正規表現 q を Go の正規表現にする。読めなければ q を固定の字として引く。
func compileGrep(q string) *regexp.Regexp {
	if re, err := regexp.Compile("(?i)" + basicToRE2(q)); err == nil {
		return re
	}
	return regexp.MustCompile("(?i)" + regexp.QuoteMeta(q))
}

// basicToRE2 は POSIX の基本正規表現（grep の既定・GNU の \| \+ \? を含む）を RE2 の書き方に替える。
// WhyNot: q を固定の字として引かない — make api Q=draw.*Text のような引き方を旧レシピの grep が受けていた。
func basicToRE2(q string) string {
	var b strings.Builder
	rs := []rune(q)
	atStart := true
	for i := 0; i < len(rs); i++ {
		c := rs[i]
		switch {
		case c == '\\' && i+1 < len(rs):
			i++
			n := rs[i]
			switch n {
			case '(', ')', '{', '}', '|', '+', '?':
				b.WriteRune(n)
				atStart = n == '(' || n == '|'
				continue
			case '<', '>':
				b.WriteString(`\b`)
			case 'w', 'W', 's', 'S', 'b', 'B':
				b.WriteRune('\\')
				b.WriteRune(n)
			default:
				b.WriteString(regexp.QuoteMeta(string(n)))
			}
		case c == '[':
			j := i + 1
			if j < len(rs) && rs[j] == '^' {
				j++
			}
			if j < len(rs) && rs[j] == ']' {
				j++
			}
			for j < len(rs) && rs[j] != ']' {
				if rs[j] == '[' && j+1 < len(rs) && (rs[j+1] == ':' || rs[j+1] == '.' || rs[j+1] == '=') {
					end := strings.Index(string(rs[j+2:]), string(rs[j+1])+"]")
					if end >= 0 {
						j += 2 + len([]rune(string(rs[j+2:])[:end])) + 2
						continue
					}
				}
				j++
			}
			if j >= len(rs) {
				b.WriteString(regexp.QuoteMeta(string(rs[i:])))
				i = len(rs)
				break
			}
			b.WriteString(strings.ReplaceAll(string(rs[i:j+1]), `\`, `\\`))
			i = j
		case c == '*' && atStart:
			b.WriteString(`\*`)
		case c == '^' && atStart:
			b.WriteRune('^')
			continue
		case c == '$' && (i == len(rs)-1 || (i+2 < len(rs) && rs[i+1] == '\\' && (rs[i+2] == ')' || rs[i+2] == '|'))):
			b.WriteRune('$')
		case c == '.' || c == '*':
			b.WriteRune(c)
		default:
			b.WriteString(regexp.QuoteMeta(string(c)))
		}
		atStart = false
	}
	return b.String()
}
