package checkrefs

// check-refs — 文書やスクリプトが名指ししているパスが実在するかの検査。
//
//	fge-go check-refs                    リポ自身を検査
//	fge-go check-refs --root DIR         見に行く先を差し替える（見本から呼ぶため）
//	fge-go check-refs --bundle DIR       ステージ済みバンドルに必須物が揃っているか
//	fge-go check-refs --bundle DIR --windows
//
// 語彙と一覧は bin/lint-rules/check-refs.json が持つ。

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// checker は 1 回ぶんの検査。out が stdout・errOut が stderr。
type checker struct {
	rules       *Rules
	root        string
	out, errOut *strings.Builder
}

// ------------------------------------------------------------ パスの小物

// joinPath は base の下の rel を / 区切りの字面でつなぐ。
func joinPath(base, rel string) string {
	if base == "" {
		return pxlib.PosixPath(rel)
	}
	b := pxlib.PosixPath(base)
	if strings.HasSuffix(b, "/") {
		return pxlib.PosixPath(b + rel)
	}
	return pxlib.PosixPath(b + "/" + rel)
}

// parentsOf は p の親を、近い方から根へ向かって並べて返す。
func parentsOf(p string) []string {
	anchor, parts := pxlib.PathParts(p)
	var out []string
	for i := len(parts) - 1; i >= 1; i-- {
		out = append(out, anchor+strings.Join(parts[:i], "/"))
	}
	switch {
	case anchor != "":
		out = append(out, anchor)
	case len(parts) >= 1:
		out = append(out, ".")
	}
	return out
}

// pathLess はパスどうしの大小（/ で切った要素ごとに比べる）。
//
// WhyNot: 文字列そのものを比べないのは、区切りの / (0x2f) より小さい字が名前に入ると
// 並びが入れ替わるため（rpg/Makefile と rpg-starter/Makefile）。
func pathLess(a, b string) bool {
	as, bs := strings.Split(a, "/"), strings.Split(b, "/")
	for i := 0; i < len(as) && i < len(bs); i++ {
		if as[i] != bs[i] {
			return as[i] < bs[i]
		}
	}
	return len(as) < len(bs)
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func isFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

func joinDir(dir, name string) string {
	switch {
	case dir == "":
		return name
	case strings.HasSuffix(dir, "/"):
		return dir + name
	default:
		return dir + "/" + name
	}
}

func hasMagic(s string) bool { return strings.ContainsAny(s, "*?[") }

// fnmatchPy は fnmatch と同じ当て方（* と ? だけ。名前全体に当てる）。
// 既知の制限: [] の範囲指定は字面として扱う（PATH_RE の文字集合に [ が入らないため）。
func fnmatchPy(name, pat string) bool {
	n, p := []rune(name), []rune(pat)
	i, j, star, mark := 0, 0, -1, 0
	for i < len(n) {
		switch {
		case j < len(p) && (p[j] == '?' || p[j] == n[i]):
			i++
			j++
		case j < len(p) && p[j] == '*':
			star, mark = j, i
			j++
		case star >= 0:
			mark++
			i, j = mark, star+1
		default:
			return false
		}
	}
	for j < len(p) && p[j] == '*' {
		j++
	}
	return j == len(p)
}

// globAny は glob.glob(pattern) が 1 つでも拾うかを返す。
// glob は名前の頭の . を * に当てない（pathlib の glob とはここが違う）。
func globAny(pattern string) bool {
	comps := strings.Split(pattern, "/")
	base := ""
	if comps[0] == "" {
		base = "/"
		comps = comps[1:]
	}
	if len(comps) == 0 {
		return false
	}
	return globRec(base, comps)
}

func globRec(base string, comps []string) bool {
	c, rest := comps[0], comps[1:]
	if !hasMagic(c) {
		p := joinDir(base, c)
		if len(rest) == 0 {
			_, err := os.Lstat(p)
			return err == nil
		}
		return globRec(p, rest)
	}
	dir := base
	if dir == "" {
		dir = "."
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") && !strings.HasPrefix(c, ".") {
			continue
		}
		if !fnmatchPy(name, c) {
			continue
		}
		if len(rest) == 0 {
			return true
		}
		if globRec(joinDir(base, name), rest) {
			return true
		}
	}
	return false
}

// pathlibGlob は Path(base).glob(pattern) と同じ物を base からの相対で返す（並べ替えない）。
// WhyNot: glob.glob と分けているのは、pathlib の glob は名前の頭の . を * に当てるため。
func pathlibGlob(base, pattern string) []string {
	comps := strings.Split(pattern, "/")
	var out []string
	var rec func(dir string, rel []string, comps []string)
	rec = func(dir string, rel []string, comps []string) {
		c, rest := comps[0], comps[1:]
		last := len(rest) == 0
		if !hasMagic(c) {
			p := joinDir(dir, c)
			next := append(append([]string{}, rel...), c)
			switch {
			case last && exists(p):
				out = append(out, strings.Join(next, "/"))
			case !last:
				rec(p, next, rest)
			}
			return
		}
		dirName := dir
		if dirName == "" {
			dirName = "."
		}
		entries, err := os.ReadDir(dirName)
		if err != nil {
			return
		}
		for _, e := range entries {
			name := e.Name()
			if !fnmatchPy(name, c) {
				continue
			}
			p := joinDir(dir, name)
			next := append(append([]string{}, rel...), name)
			switch {
			case last:
				out = append(out, strings.Join(next, "/"))
			case isDir(p):
				rec(p, next, rest)
			}
		}
	}
	rec(base, nil, comps)
	return out
}

func readText(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("読めません: %v", err)
	}
	return string(data), nil
}

// ------------------------------------------------------------ 文字列の取り出し

// existsIn は base の下に rel があるか。* が入っていれば glob で見る。
func (c *checker) existsIn(base, rel string) bool {
	p := joinPath(base, rel)
	if strings.Contains(rel, "*") {
		return globAny(p)
	}
	return exists(p)
}

// extractPaths は文章・Makefile から拾ったパス片を並べ替えて返す（重複は 1 つ）。
func (c *checker) extractPaths(text string) []string {
	seen := map[string]bool{}
	var found []string
	for _, sp := range c.rules.Path.FindAll(text) {
		tok := strings.TrimRight(text[sp.start:sp.end], c.rules.TrimChars)
		skip := false
		for _, s := range c.rules.SkipMarks {
			if strings.Contains(tok, s) {
				skip = true
				break
			}
		}
		if skip || seen[tok] {
			continue
		}
		seen[tok] = true
		found = append(found, tok)
	}
	sort.Strings(found)
	return found
}

// stripMkComments は # 以降の説明文と、echo/printf の文字列の中身を落とす。
func (c *checker) stripMkComments(text string) string {
	lines := pxlib.SplitLines(text)
	out := make([]string, 0, len(lines))
	for _, ln := range lines {
		ln = c.rules.Comment.ReplaceAllString(ln, "${1}")
		ln = c.subEcho(ln)
		out = append(out, ln)
	}
	return strings.Join(out, "\n")
}

// subEcho は echo/printf が画面へ出す文字列を空文字に置き換える。
func (c *checker) subEcho(ln string) string {
	spans := c.rules.Echo.FindAll(ln)
	if len(spans) == 0 {
		return ln
	}
	var b strings.Builder
	prev := 0
	for _, sp := range spans {
		b.WriteString(ln[prev:sp.start])
		b.WriteString(c.rules.Echo.Group1(ln, sp))
		b.WriteString(" ''")
		prev = sp.end
	}
	b.WriteString(ln[prev:])
	return b.String()
}

// ------------------------------------------------------------ 4 面の検査

// syncAgentsDist は sync-agents が実際にゲームへ配るパスの集合を返す。
func (c *checker) syncAgentsDist() map[string]bool {
	dist := map[string]bool{}
	data, err := os.ReadFile(joinPath(joinPath(c.root, "agents-pack"), "manifest.json"))
	if err != nil {
		return dist
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(data, &m); err != nil {
		return dist
	}
	for _, key := range c.rules.ManifestKeys {
		raw, ok := m[key]
		if !ok {
			continue
		}
		var entries []map[string]any
		if err := json.Unmarshal(raw, &entries); err != nil {
			continue
		}
		for _, e := range entries {
			for _, field := range []string{"src", "dst"} {
				rel, _ := e[field].(string)
				if rel == "" {
					continue
				}
				dist[rel] = true
				parent := c.rules.LastSegment.ReplaceAllString(rel, "")
				for strings.Contains(parent, "/") {
					dist[parent] = true
					parent = c.rules.LastSegment.ReplaceAllString(parent, "")
				}
			}
		}
	}
	return dist
}

func (c *checker) checkMakefile(problems *[]string) (map[string]bool, error) {
	raw, err := readText(joinPath(c.root, "Makefile"))
	if err != nil {
		return nil, err
	}
	text := c.stripMkComments(raw)
	for _, rel := range c.extractPaths(text) {
		if !c.existsIn(c.root, rel) {
			*problems = append(*problems, fmt.Sprintf("Makefile: %s が実在しません", rel))
		}
	}
	dist := c.syncAgentsDist()
	if len(dist) == 0 {
		*problems = append(*problems,
			"agents-pack/manifest.json が読み取れません"+
				" (配布リストの照合ができない — 形を変えたなら"+
				" go/internal/checkrefs の syncAgentsDist を追随)")
	}
	return dist, nil
}

func (c *checker) checkTemplates(problems *[]string, dist map[string]bool) error {
	var targets []string
	for _, pattern := range c.rules.TemplateGlobs {
		found := pathlibGlob(c.root, pattern)
		sort.Slice(found, func(i, j int) bool { return pathLess(found[i], found[j]) })
		targets = append(targets, found...)
	}
	for _, relMk := range targets {
		raw, err := readText(joinPath(c.root, relMk))
		if err != nil {
			return err
		}
		text := c.stripMkComments(raw)
		// $(ENGINE)/bin/... や $(ENGINE)/docs/... は engine リポの実体を指す。
		for _, sp := range c.rules.EnginePath.FindAll(text) {
			rel := strings.TrimRight(c.rules.EnginePath.Group1(text, sp), c.rules.TrimChars)
			if c.rules.EnginePathSkip[rel] {
				continue
			}
			if !c.existsIn(c.root, rel) {
				*problems = append(*problems,
					fmt.Sprintf("%s: $(ENGINE)/%s が engine に実在しません", relMk, rel))
			}
		}
		for _, rel := range c.extractPaths(text) {
			if !strings.HasPrefix(rel, "bin/") {
				continue
			}
			switch {
			case !c.existsIn(c.root, rel):
				*problems = append(*problems,
					fmt.Sprintf("%s: %s が engine に実在しません", relMk, rel))
			case !c.rules.DistExempt[rel] && !dist[rel]:
				*problems = append(*problems, fmt.Sprintf(
					"%s: %s は sync-agents の配布リスト (engine Makefile の cp 行) に"+
						"見当たりません — 産まれたゲームに配られず参照が宙に浮きます", relMk, rel))
			}
		}
	}
	return nil
}

func (c *checker) checkAgentsPack(problems *[]string, dist map[string]bool) error {
	core := joinPath(joinPath(c.root, "agents-pack"), "AGENTS.core.md")
	text, err := readText(core)
	if err != nil {
		return err
	}
	relCore := "agents-pack/AGENTS.core.md"
	for _, rel := range c.extractPaths(text) {
		switch {
		case strings.HasPrefix(rel, "docs/"):
			// 「engine リポの docs/...」の決まり。バンドル欠損の主犯だった参照。
			if !c.existsIn(c.root, rel) {
				*problems = append(*problems,
					fmt.Sprintf("%s: %s が engine に実在しません", relCore, rel))
			}
		case strings.HasPrefix(rel, "bin/"):
			switch {
			case !c.existsIn(c.root, rel):
				*problems = append(*problems,
					fmt.Sprintf("%s: %s が engine に実在しません", relCore, rel))
			case !dist[rel]:
				*problems = append(*problems, fmt.Sprintf(
					"%s: %s が sync-agents の配布リスト (cp 行) に"+
						"見当たりません", relCore, rel))
			}
		}
	}
	// rules の決まり (.claude/rules/xxx.md) は agents-pack/rules が実体。
	for _, sp := range c.rules.Rule.FindAll(text) {
		name := c.rules.Rule.Group1(text, sp)
		if !exists(joinPath(joinPath(joinPath(c.root, "agents-pack"), "rules"), name)) {
			*problems = append(*problems, fmt.Sprintf(
				"%s: .claude/rules/%s の実体が agents-pack/rules にありません", relCore, name))
		}
	}
	// settings.json の決まりと、そのフックの実体。
	settings := joinPath(joinPath(c.root, "agents-pack"), "settings.json")
	if strings.Contains(text, ".claude/settings.json") && !exists(settings) {
		*problems = append(*problems,
			fmt.Sprintf("%s: agents-pack/settings.json がありません", relCore))
	}
	if exists(settings) {
		body, err := readText(settings)
		if err != nil {
			return err
		}
		for _, sp := range c.rules.Hook.FindAll(body) {
			hook := ".claude/hooks/" + c.rules.Hook.Group1(body, sp)
			switch {
			case !exists(joinPath(c.root, hook)):
				*problems = append(*problems,
					fmt.Sprintf("agents-pack/settings.json: %s が実在しません", hook))
			case !dist[hook]:
				*problems = append(*problems, fmt.Sprintf(
					"agents-pack/settings.json: %s が sync-agents の配布リスト (cp 行) に"+
						"見当たりません", hook))
			}
		}
	}
	return nil
}

// checkTemplatesShape は base/templates/*/ の 1 本ずつが複製元として成り立つかを見る。
func (c *checker) checkTemplatesShape(problems *[]string, base, label string) []string {
	templates := joinPath(base, "templates")
	var dirs []string
	for _, name := range pathlibGlob(templates, "*") {
		if isDir(joinPath(templates, name)) {
			dirs = append(dirs, name)
		}
	}
	sort.Slice(dirs, func(i, j int) bool { return pathLess(dirs[i], dirs[j]) })
	if len(dirs) == 0 {
		*problems = append(*problems,
			fmt.Sprintf("%s: templates/ にテンプレが 1 本もありません", label))
		return dirs
	}
	for _, name := range dirs {
		dir := joinPath(templates, name)
		for _, rel := range c.rules.TemplateRequired {
			if !exists(joinPath(dir, rel)) {
				*problems = append(*problems,
					fmt.Sprintf("%s: templates/%s/%s がありません", label, name, rel))
			}
		}
		if len(pathlibGlob(dir, "src/*.flix")) == 0 {
			*problems = append(*problems,
				fmt.Sprintf("%s: templates/%s/src に .flix がありません", label, name))
		}
	}
	return dirs
}

// findGenesis はバンドルの置き場所から Studio の Genesis.flix を探す。
func findGenesis(base string) (string, bool) {
	cands := append([]string{pxlib.PosixPath(base)}, parentsOf(base)...)
	if len(cands) > 7 {
		cands = cands[:7]
	}
	for _, parent := range cands {
		cand := joinPath(joinPath(joinPath(parent, "server"), "src"), "Genesis.flix")
		if isFile(cand) {
			return cand, true
		}
	}
	return "", false
}

// checkGenesisStarters は Studio のジャンルカードの starter と同梱テンプレを両方向で見る。
func (c *checker) checkGenesisStarters(problems *[]string, base string, templateDirs []string) error {
	genesis, ok := findGenesis(base)
	if !ok {
		fmt.Fprintln(c.out, "[check-refs] Genesis 対照は飛ばしました (Studio の外のバンドル)")
		return nil
	}
	text, err := readText(genesis)
	if err != nil {
		return err
	}
	declared := map[string]bool{}
	for _, sp := range c.rules.GenesisStarter.FindAll(text) {
		if g := c.rules.GenesisStarter.Group1(text, sp); g != "" {
			declared[g] = true
		}
	}
	present := map[string]bool{}
	for _, name := range templateDirs {
		present["templates/"+name] = true
	}
	if sameSet(declared, present) {
		fmt.Fprintf(c.out, "[check-refs] Genesis 対照 OK: starter %d 件 = テンプレ %d 本 (%s)\n",
			len(declared), len(present), genesis)
		return nil
	}
	for _, rel := range sortedDiff(declared, present) {
		*problems = append(*problems, fmt.Sprintf(
			"%s: starter = \"%s\" のテンプレがバンドルにありません"+
				" (Studio でそのジャンルを選ぶと複製が転びます)", genesis, rel))
	}
	for _, rel := range sortedDiff(present, declared) {
		*problems = append(*problems, fmt.Sprintf(
			"%s: %s がどのジャンルの starter にもなっていません"+
				" (Studio から選べないテンプレです)", genesis, rel))
	}
	return nil
}

func sameSet(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

func sortedDiff(a, b map[string]bool) []string {
	var out []string
	for k := range a {
		if !b[k] {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// hooksInSettings は base/agents-pack/settings.json が名指しするフックの実体パス。
func (c *checker) hooksInSettings(base string) []string {
	text, err := readText(joinPath(joinPath(base, "agents-pack"), "settings.json"))
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	for _, sp := range c.rules.Hook.FindAll(text) {
		hook := ".claude/hooks/" + c.rules.Hook.Group1(text, sp)
		if seen[hook] {
			continue
		}
		seen[hook] = true
		out = append(out, hook)
	}
	sort.Strings(out)
	return out
}

// checkBundleManifest は必須一覧そのものの書き損じ（リポに無い物を必須と言う）を止める。
// 組み立てで名前を付け替えて作る物は、付け替える前の元 (stage-engine.json の src) がリポにあればよい。
func (c *checker) checkBundleManifest(problems *[]string) {
	srcOf := c.bundleSources()
	for _, rel := range c.rules.BundleRequired {
		if c.existsIn(c.root, rel) {
			continue
		}
		if src, ok := srcOf[rel]; ok && src != rel && c.existsIn(c.root, src) {
			continue
		}
		*problems = append(*problems, fmt.Sprintf(
			"BUNDLE_REQUIRED: %s がこのリポにありません (一覧の書き損じ?)", rel))
	}
}

// bundleSources は同梱の組み立て (bin/lint-rules/stage-engine.json) の、行き先 → 元。
// WhyNot: リポの中だけで探さないのは、engine_full/artifact/engine_full.fpkg のように
// 組み立てのときに名前を付け替えて作る物は、リポには別の名前 (package.fpkg) でしか無いため。
// 古い作業コピーには昔の名前の物が残っていて通り、新しい clone でだけ止まっていた。
// stageengine の LoadRules を使わないのは、stageengine が checkrefs を読み込んでいて循環するため。
// 読めないときは空にする (その場合はリポにある物だけを書き損じでないとみなす、元の判定になる)。
// 元がリポに無い物は今までどおり止める (同梱の組み立ても、その元が無ければ失敗する)。
func (c *checker) bundleSources() map[string]string {
	srcOf := map[string]string{}
	data, err := os.ReadFile(joinPath(c.root, "bin/lint-rules/stage-engine.json"))
	if err != nil {
		return srcOf
	}
	var stage struct {
		Items []struct {
			Src         string `json:"src"`
			Dest        string `json:"dest"`
			DestWindows string `json:"destWindows"`
		} `json:"items"`
	}
	if json.Unmarshal(data, &stage) != nil {
		return srcOf
	}
	for _, it := range stage.Items {
		srcOf[it.Dest] = it.Src
		if it.DestWindows != "" {
			srcOf[it.DestWindows] = it.Src
		}
	}
	return srcOf
}

func (c *checker) checkBundle(bundleDir string, windows bool) (int, error) {
	base := pxlib.PosixPath(bundleDir)
	if !isDir(base) {
		fmt.Fprintf(c.errOut, "バンドルが見つかりません: %s\n", bundleDir)
		return 1, nil
	}
	var required []string
	for _, r := range c.rules.BundleRequired {
		if windows && c.rules.BundleSkipOnWindows[r] {
			continue
		}
		required = append(required, r)
	}
	if windows {
		required = append(required, c.rules.BundleWindowsExtra...)
	}
	// フックの実体は settings.json が名指しする分だけ要る。一覧を減らす向きには効かない。
	for _, rel := range c.hooksInSettings(base) {
		if !containsString(required, rel) {
			required = append(required, rel)
		}
	}
	var missing []string
	for _, rel := range required {
		if !c.existsIn(base, rel) {
			missing = append(missing, rel)
		}
	}
	if len(missing) > 0 {
		fmt.Fprintf(c.errOut, "[check-refs] バンドル欠損 %d 件 (%s):\n", len(missing), bundleDir)
		for _, rel := range missing {
			fmt.Fprintf(c.errOut, "  %s\n", rel)
		}
		fmt.Fprintln(c.errOut, "運ぶ物の一覧 bin/lint-rules/stage-engine.json に足してください。"+
			"必須一覧は bin/lint-rules/check-refs.json の bundleRequired。")
		return 1, nil
	}
	var problems []string
	dirs := c.checkTemplatesShape(&problems, base, bundleDir)
	if err := c.checkGenesisStarters(&problems, base, dirs); err != nil {
		return 2, err
	}
	if len(problems) > 0 {
		for _, p := range problems {
			fmt.Fprintln(c.errOut, p)
		}
		return 1, nil
	}
	win := ""
	if windows {
		win = " / Windows"
	}
	fmt.Fprintf(c.out, "OK: バンドルに必須 %d 点が揃っています (%s%s・テンプレ %d 本)\n",
		len(required), bundleDir, win, len(dirs))
	return 0, nil
}

func containsString(items []string, s string) bool {
	for _, it := range items {
		if it == s {
			return true
		}
	}
	return false
}

// ------------------------------------------------------------ 入口

// Run は検査を走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（規約を読めないまま緑にしない）。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	c := &checker{rules: rules, root: root, out: out, errOut: errOut}

	for i, a := range args {
		if a != "--bundle" {
			continue
		}
		if i+1 >= len(args) {
			fmt.Fprintln(errOut, "usage: fge check-refs --bundle DIR [--windows]")
			return 2, nil
		}
		return c.checkBundle(args[i+1], containsString(args, "--windows"))
	}

	var problems []string
	dist, err := c.checkMakefile(&problems)
	if err != nil {
		return 2, err
	}
	if err := c.checkTemplates(&problems, dist); err != nil {
		return 2, err
	}
	if err := c.checkAgentsPack(&problems, dist); err != nil {
		return 2, err
	}
	c.checkTemplatesShape(&problems, c.root, "engine")
	c.checkBundleManifest(&problems)

	if len(problems) > 0 {
		for _, p := range problems {
			fmt.Fprintln(errOut, p)
		}
		fmt.Fprintln(errOut, "\n参照した先を実在させるか、参照の方を直してください。")
		return 1, nil
	}
	fmt.Fprintln(out, "OK: Makefile / templates / agents-pack の参照は全て実在します")
	return 0, nil
}
