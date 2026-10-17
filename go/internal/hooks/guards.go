package hooks

// PreToolUse のフック 2 本 — 道具の呼び出しを実行の前に止める。
//
//   - hook-asset-guard: ゲームの assets/ の素材（sprite.json・png・wav…）へ Write / Edit /
//     MultiEdit / apply_patch で書く・Bash で書き込む形（BashWriteTargets）を止め、atelier/ の同じ名前を返す。
//   - hook-read-guard: 大きな .flix を Read で limit 無し（か maxLines 超え）で読む・Bash で
//     `cat x.flix` と丸ごと出すのを止め、grep -n と Read の offset/limit を返す。
//
// 止めるときは exit 2 と stderr（Claude Code の PreToolUse では「呼び出しを止め、
// stderr をモデルへ返す」）。判定値は bin/lint-rules/hooks.json の assetGuard・readGuard。
//
// WhyNot: 規約が読めないときも 0（通す）なのは、門の都合で人の作業まで止めないため。
// 素材の Doc（*.cycle.json などの調整の JSON）は suffixes に入れず、止めない。

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// LoadGuardRules は root の規約を読み、want の節が無ければ fallback の規約を読む。
// WhyNot: 片方だけ更新された作業場（バイナリが新しく hooks.json が古い）で、
// 門だけ黙って消えないため。どちらにも無ければ nil。
func LoadGuardRules(root, fallback string, want func(*Rules) bool) *Rules {
	for _, dir := range []string{root, fallback} {
		if dir == "" {
			continue
		}
		if r, err := LoadRules(dir); err == nil && want(r) {
			return r
		}
	}
	return nil
}

// RunAssetGuard は書き込みの宛先が素材のスロットなら止める。
func RunAssetGuard(errOut io.Writer, root, fallback string, in io.Reader) int {
	payload, ok := ReadPayload(in)
	if !ok {
		return 0
	}
	r := LoadGuardRules(root, fallback, func(r *Rules) bool { return r.AssetGuard != nil && len(r.AssetGuard.Suffixes) > 0 })
	if r == nil {
		return 0
	}
	g := r.AssetGuard
	base := projectBase(payload, root)
	if !isDir(filepath.Join(base, g.AtelierDir)) {
		// atelier/ を持たないリポジトリ（エンジンの templates など）は対象外。
		return 0
	}
	paths := payload.EditedPaths(r)
	if cmd := payload.sub("tool_input").str("command"); cmd != "" {
		paths = append(paths, BashWriteTargets(cmd, g)...)
	}
	var msgs []string
	seen := map[string]bool{}
	for _, path := range paths {
		if strings.HasSuffix(path, "/") && len(path) > 1 {
			abs := filepath.Clean(absolutize(payload, base, strings.TrimRight(path, "/")))
			rel, inside := relUnder(base, abs, g.AssetsDir)
			if inside || sameDir(abs, filepath.Join(base, g.AssetsDir)) {
				d := filepath.ToSlash(filepath.Join(g.AssetsDir, rel)) + "/"
				if !seen[d] {
					seen[d] = true
					msgs = append(msgs, fill(g.Message, map[string]string{"path": d, "atelier": g.AtelierDir + "/"}))
				}
			}
			continue
		}
		rel, inside := relUnder(base, absolutize(payload, base, path), g.AssetsDir)
		if !inside || !hasAnySuffix(rel, g.Suffixes) {
			continue
		}
		rel = filepath.Clean(rel)
		if seen[rel] {
			continue
		}
		seen[rel] = true
		alt := filepath.ToSlash(filepath.Join(g.AtelierDir, rel))
		msgs = append(msgs, fill(g.Message, map[string]string{
			"path":    filepath.ToSlash(filepath.Join(g.AssetsDir, rel)),
			"atelier": alt,
		}))
	}
	if len(msgs) == 0 {
		return 0
	}
	fmt.Fprintln(errOut, strings.Join(msgs, "\n"))
	return 2
}

// RunReadGuard は大きな .flix の丸読みを止める。
func RunReadGuard(errOut io.Writer, root, fallback string, in io.Reader) int {
	payload, ok := ReadPayload(in)
	if !ok {
		return 0
	}
	r := LoadGuardRules(root, fallback, func(r *Rules) bool { return r.ReadGuard != nil && r.ReadGuard.MaxLines > 0 })
	if r == nil {
		return 0
	}
	g := r.ReadGuard
	base := projectBase(payload, root)
	ti := payload.sub("tool_input")
	var cands []string
	if path := ti.str("file_path"); path != "" {
		// Read の形。limit が maxLines 以下なら範囲を決めて読んでいる。
		// WhyNot: offset だけ・大きな limit を通さないのは、offset: 0 や limit: 5000 で
		// 丸読みと同じになるため（offset だけでも残りを全部読む）。
		if n, ok := ti["limit"].(float64); ok && n > 0 && int(n) <= g.MaxLines {
			return 0
		}
		cands = []string{path}
	} else if cmd := ti.str("command"); cmd != "" {
		cands = WholeCatTargets(cmd, g.CatCommands)
	}
	var msgs []string
	for _, path := range cands {
		if !strings.HasSuffix(path, g.Suffix) {
			continue
		}
		n, ok := countLines(absolutize(payload, base, path))
		if !ok || n <= g.MaxLines {
			continue
		}
		msgs = append(msgs, fill(g.Message, map[string]string{
			"path":  path,
			"lines": strconv.Itoa(n),
			"max":   strconv.Itoa(g.MaxLines),
		}))
	}
	if len(msgs) == 0 {
		return 0
	}
	fmt.Fprintln(errOut, strings.Join(msgs, "\n"))
	return 2
}

var shellSplit = regexp.MustCompile(`&&|\|\||;|\n`)

// BashWriteTargets は Bash のコマンドが書き込む先のパスを拾う（cd を追った相対パスか絶対パス）。
// 素材かどうかの判定は呼ぶ側（assets/ の下か・suffixes に当たるか）。拾う形:
//   - シェル: リダイレクトの行き先・`dd of=`・その場で書き換える道具（`sed -i*` `perl -*i*`）の
//     引数・g.BashInPlace の道具（tee など）の引数・g.BashCopy の道具（cp mv rsync…）の最後の引数
//   - スクリプト（heredoc と -c の中）: `open(P, 'w')`・`Path(P).write_text`・`.save(P)`・
//     `writeFileSync(P` の P。P が変数なら同じコマンドの中の `名前 = '…'` から引く。
//
// WhyNot: 素材のパスが書かれているだけでは止めないのは、読むだけ（grep・head・json.load）や、
// 素材を読んで atelier/ へ書く手順（勧めている手順そのもの）まで止めないため。
func BashWriteTargets(cmd string, g *AssetGuard) []string {
	shell, script := splitHeredocs(cmd)
	out := shellWriteTargets(shell, g)
	return append(out, scriptWriteTargets(script+"\n"+shell)...)
}

var heredocStart = regexp.MustCompile(`<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?`)

// splitHeredocs はコマンドをシェルの行と heredoc の本文に分ける。
func splitHeredocs(cmd string) (shell, body string) {
	var sh, bd []string
	lines := strings.Split(cmd, "\n")
	for i := 0; i < len(lines); i++ {
		sh = append(sh, lines[i])
		m := heredocStart.FindStringSubmatch(lines[i])
		if m == nil {
			continue
		}
		for i++; i < len(lines) && strings.TrimSpace(lines[i]) != m[1]; i++ {
			bd = append(bd, lines[i])
		}
	}
	return strings.Join(sh, "\n"), strings.Join(bd, "\n")
}

var shellSegment = regexp.MustCompile(`&&|\|\||;|\n|\|`)

func shellWriteTargets(shell string, g *AssetGuard) []string {
	var out []string
	dir := ""
	at := func(p string) string {
		if p == "" || filepath.IsAbs(p) || dir == "" {
			return p
		}
		return filepath.Join(dir, p)
	}
	for _, seg := range shellSegment.Split(shell, -1) {
		args := shellWords(seg)
		var words []string
		for i := 0; i < len(args); i++ {
			a := args[i]
			switch {
			case a == ">" || a == ">>" || a == "&>" || a == "1>" || a == ">|":
				if i+1 < len(args) {
					out = append(out, at(args[i+1]))
					i++
				}
				continue
			case strings.HasPrefix(a, ">") || strings.HasPrefix(a, "1>") || strings.HasPrefix(a, "&>"):
				t := strings.TrimLeft(a, "1&>|")
				if t != "" && !strings.HasPrefix(t, "&") {
					out = append(out, at(t))
				}
				continue
			case strings.HasPrefix(a, "2>") || strings.HasPrefix(a, "<"):
				if (a == "2>" || a == "<" || a == "2>>") && i+1 < len(args) {
					i++
				}
				continue
			}
			words = append(words, a)
		}
		for len(words) > 0 && strings.Contains(words[0], "=") && !strings.HasPrefix(words[0], "-") {
			words = words[1:]
		}
		for len(words) > 1 && (words[0] == "command" || words[0] == "sudo" || words[0] == "env") {
			words = words[1:]
		}
		if len(words) == 0 {
			continue
		}
		head := filepath.Base(words[0])
		rest := words[1:]
		var files []string
		for _, a := range rest {
			if !strings.HasPrefix(a, "-") {
				files = append(files, a)
			}
		}
		switch {
		case head == "cd":
			if len(rest) > 0 {
				if filepath.IsAbs(rest[0]) {
					dir = rest[0]
				} else {
					dir = filepath.Join(dir, rest[0])
				}
			}
		case head == "dd":
			for _, a := range rest {
				if strings.HasPrefix(a, "of=") {
					out = append(out, at(strings.TrimPrefix(a, "of=")))
				}
			}
		case head == "sed" && hasFlag(rest, "-i", "--in-place"), head == "perl" && hasPerlInPlace(rest):
			for _, f := range files {
				out = append(out, at(f))
			}
		case contains(g.BashInPlace, head):
			for _, f := range files {
				out = append(out, at(f))
			}
		case contains(g.BashCopy, head) && len(files) >= 2:
			dst := files[len(files)-1]
			out = append(out, at(dst))
			// ディレクトリごと写す（`rsync -a atelier/ assets/`・`cp -r x/ assets/y/`）は末尾の / で知らせる。
			for _, src := range files[:len(files)-1] {
				if strings.HasSuffix(src, "/") {
					out = append(out, strings.TrimRight(at(dst), "/")+"/")
					break
				}
			}
			// 行き先がディレクトリなら、入る名前（写す元の名前）でも見る。
			for _, src := range files[:len(files)-1] {
				out = append(out, at(filepath.Join(dst, filepath.Base(strings.TrimRight(src, "/")))))
			}
		}
	}
	return out
}

func hasFlag(args []string, short, long string) bool {
	for _, a := range args {
		if strings.HasPrefix(a, short) || strings.HasPrefix(a, long) {
			return true
		}
	}
	return false
}

// hasPerlInPlace は perl の旗に i が入っているか（-i・-pi・-0pi・-i.bak）。
func hasPerlInPlace(args []string) bool {
	for _, a := range args {
		if strings.HasPrefix(a, "-") && !strings.HasPrefix(a, "--") && !strings.HasPrefix(a, "-e") && strings.Contains(a, "i") {
			return true
		}
	}
	return false
}

// shellWords は 1 つの単純コマンドを語に分ける（'…' と "…" の中の空白は分けない・引用符は外す）。
func shellWords(seg string) []string {
	var out []string
	var cur strings.Builder
	quote := byte(0)
	has := false
	for i := 0; i < len(seg); i++ {
		c := seg[i]
		switch {
		case quote != 0:
			if c == quote {
				quote = 0
			} else {
				cur.WriteByte(c)
			}
		case c == '\'' || c == '"':
			quote = c
			has = true
		case c == ' ' || c == '\t':
			if has || cur.Len() > 0 {
				out = append(out, cur.String())
				cur.Reset()
				has = false
			}
		default:
			cur.WriteByte(c)
		}
	}
	if has || cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}

var (
	scriptAssign = regexp.MustCompile(`\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:Path\(\s*)?['"]([^'"\n]+)['"]`)
	scriptWrites = []*regexp.Regexp{
		regexp.MustCompile(`open\(\s*(?:['"]([^'"\n]+)['"]|([A-Za-z_][A-Za-z0-9_]*))\s*,\s*['"](?:w|wb|a|ab|w\+|r\+|x)['"]`),
		regexp.MustCompile(`Path\(\s*(?:['"]([^'"\n]+)['"]|([A-Za-z_][A-Za-z0-9_]*))\s*\)\.write_(?:text|bytes)`),
		regexp.MustCompile(`\b()([A-Za-z_][A-Za-z0-9_]*)\.write_(?:text|bytes)`),
		regexp.MustCompile(`\.save\(\s*(?:['"]([^'"\n]+)['"]|([A-Za-z_][A-Za-z0-9_]*))`),
		regexp.MustCompile(`writeFileSync\(\s*(?:['"]([^'"\n]+)['"]|([A-Za-z_][A-Za-z0-9_]*))`),
	}
)

func scriptWriteTargets(text string) []string {
	vars := map[string]string{}
	for _, m := range scriptAssign.FindAllStringSubmatch(text, -1) {
		vars[m[1]] = m[2]
	}
	var out []string
	for _, re := range scriptWrites {
		for _, m := range re.FindAllStringSubmatch(text, -1) {
			if m[1] != "" {
				out = append(out, m[1])
			} else if p, ok := vars[m[2]]; ok {
				out = append(out, p)
			}
		}
	}
	return out
}

// WholeCatTargets は、パイプにもリダイレクトにも繋がない `cat <ファイル...>` の引数を拾う。
// `cat x | grep` や `cat x > y`、`sed -n` は拾わない（丸ごと画面へ出す形だけが対象）。
func WholeCatTargets(cmd string, cats []string) []string {
	var out []string
	for _, seg := range shellSplit.Split(cmd, -1) {
		if strings.ContainsAny(seg, "|><`") || strings.Contains(seg, "$(") {
			continue
		}
		fields := strings.Fields(seg)
		// 先頭の VAR=値 は飛ばす。
		for len(fields) > 0 && strings.Contains(fields[0], "=") && !strings.HasPrefix(fields[0], "-") {
			fields = fields[1:]
		}
		if len(fields) < 2 || !contains(cats, filepath.Base(fields[0])) {
			continue
		}
		for _, a := range fields[1:] {
			a = strings.Trim(a, `"'`)
			if a != "" && !strings.HasPrefix(a, "-") {
				out = append(out, a)
			}
		}
	}
	return out
}

// projectBase はペイロードの cwd より root（CLAUDE_PROJECT_DIR）を優先した根。
func projectBase(p Payload, root string) string {
	if root != "" {
		return root
	}
	return p.str("cwd")
}

// relUnder は abs が base/dir の下なら dir からの相対パスを返す。
// WhyNot: 文字列の前方一致だけで見ないのは、/tmp と /private/tmp のような
// 別名のパスで取りこぼすため。symlink を解いた形でも見る。
func relUnder(base, abs, dir string) (string, bool) {
	bases := []string{base}
	if b, err := filepath.EvalSymlinks(base); err == nil && b != base {
		bases = append(bases, b)
	}
	targets := []string{abs}
	if d, err := filepath.EvalSymlinks(filepath.Dir(abs)); err == nil {
		targets = append(targets, filepath.Join(d, filepath.Base(abs)))
	}
	for _, b := range bases {
		for _, t := range targets {
			rel, err := filepath.Rel(filepath.Join(b, dir), t)
			if err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
				return rel, true
			}
		}
	}
	return "", false
}

// sameDir は a と b が同じディレクトリか（symlink を解いた形でも見る）。
func sameDir(a, b string) bool {
	if filepath.Clean(a) == filepath.Clean(b) {
		return true
	}
	ra, ea := filepath.EvalSymlinks(a)
	rb, eb := filepath.EvalSymlinks(b)
	return ea == nil && eb == nil && ra == rb
}

func hasAnySuffix(s string, suffixes []string) bool {
	for _, suf := range suffixes {
		if strings.HasSuffix(s, suf) {
			return true
		}
	}
	return false
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

func countLines(p string) (int, bool) {
	data, err := os.ReadFile(p)
	if err != nil {
		return 0, false
	}
	n := bytes.Count(data, []byte{'\n'})
	if len(data) > 0 && data[len(data)-1] != '\n' {
		n++
	}
	return n, true
}

// fill は {名前} を置き換える。
func fill(tmpl string, vars map[string]string) string {
	for k, v := range vars {
		tmpl = strings.ReplaceAll(tmpl, "{"+k+"}", v)
	}
	return tmpl
}
