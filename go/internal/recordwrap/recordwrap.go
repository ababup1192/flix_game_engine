package recordwrap

// record-wrap — World が直接持つ大きな record を、名前付きの型 (1 case の enum) で包んでいるかを見る。
// あわせて World の形の 2 規則 (world-resource・world-fields。world.go) も見る。
//
//	fge-go record-wrap                       名指しが無ければ何も見ない
//	fge-go record-wrap --all                 リポの全パッケージを見る (古い除外もここで裁く)
//	fge-go record-wrap [path/to/X.flix ...]  そのファイルの属するパッケージを読み、そのファイルが関わる分だけ出す
//	fge-go record-wrap --warn ...            出す物は同じで、終了コードだけ 0 にする
//	fge-go record-wrap --root DIR ...        リポジトリのルートを差し替える
//
// record の型エイリアスは使われるたびに中身のまま展開される。World (roots) の欄にそのまま置くと、
// World を取る全 def で型の木が大きくなり、flix check の時間とメモリが伸びる。
// 大きさは欄の数ではなく、入れ子の record と List / Option などの型引数の中の record まで
// 展開した欄の総数で測る。欄が 3 つでも中身が大きければ同じだけ重い (合成で測った)。
//
// enum は展開されないので、包んだ所で数えるのが止まる。パッケージの外 (エンジン) の型は
// ソースが見えないので数えない。

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/flixdecl"
)

var (
	modRe      = regexp.MustCompile(`\bmod\s+([A-Z][A-Za-z0-9_.]*)\s*\{`)
	aliasRe    = regexp.MustCompile(`\btype\s+alias\s+([A-Z][A-Za-z0-9_]*)\s*(?:\[[^\]]*\])?\s*=\s*`)
	typeNameRe = regexp.MustCompile(`\b(?:([A-Z][A-Za-z0-9_]*)\.)?([A-Z][A-Za-z0-9_]*)\b`)
)

// Alias は型エイリアス 1 つ。
type Alias struct {
	Path string
	Mod  string
	Name string
	Body string
	// Offset は Body の先頭のファイル内の位置 (欄の行番号を出すのに使う)。
	Offset int
	Text   string
}

func (a Alias) key() string { return a.Mod + "." + a.Name }

// Field は record の欄 1 つ。
type Field struct {
	Name string
	Type string
	// At は Body の中の欄の位置。
	At int
}

// Hit は鳴らす 1 件。
type Hit struct {
	Path  string
	Line  int
	Root  string
	Field string
	Type  string
	// Size は大きさの規則では展開した欄の総数、world-fields では一番上の欄の数。
	Size int
	// Rule は "" (大きさの規則) か RuleWorldResource / RuleWorldFields。
	Rule string
	// Found は world-resource で当たった型の名前。
	Found []string
	// Sources は数えた record の宣言のあるファイル (名指しのファイルが関わるかを見るため)。
	Sources map[string]bool
}

// key は除外の鍵。大きさの規則は exempt の "モジュール.型::欄名"、World の形の規則は
// exemptRules の "根からのパス::規則の id"。
func (h Hit) key() string {
	if h.Rule != "" {
		return h.Path + "::" + h.Rule
	}
	return h.Root + "::" + h.Field
}

// stripComments は // から行末までを空白に置き換える (位置は変えない)。
func stripComments(text string) string {
	b := []byte(text)
	for i := 0; i+1 < len(b); i++ {
		if b[i] == '/' && b[i+1] == '/' {
			for i < len(b) && b[i] != '\n' {
				b[i] = ' '
				i++
			}
		}
	}
	return string(b)
}

// lastSegment は "A.B.C" の最後の名前。
func lastSegment(name string) string {
	if i := strings.LastIndex(name, "."); i >= 0 {
		return name[i+1:]
	}
	return name
}

// ParseAliases は 1 ファイルの型エイリアスを拾う。モジュールは宣言の手前で一番近い mod とみなす。
func ParseAliases(rel, text string) []Alias {
	code := stripComments(text)
	mods := modRe.FindAllStringSubmatchIndex(code, -1)
	var out []Alias
	for _, m := range aliasRe.FindAllStringSubmatchIndex(code, -1) {
		mod := ""
		for _, md := range mods {
			if md[0] < m[0] {
				mod = lastSegment(code[md[2]:md[3]])
			}
		}
		start := m[1]
		end := bodyEnd(code, start)
		out = append(out, Alias{
			Path: rel, Mod: mod, Name: code[m[2]:m[3]],
			Body: strings.TrimSpace(code[start:end]), Offset: start, Text: text,
		})
	}
	return out
}

// bodyEnd は型の式の終わり。{ で始まれば対応する } まで、それ以外は括弧の外の改行まで。
func bodyEnd(code string, start int) int {
	depth := 0
	brace := start < len(code) && code[start] == '{'
	for i := start; i < len(code); i++ {
		switch code[i] {
		case '{', '[', '(':
			depth++
		case '}', ']', ')':
			depth--
			if brace && depth == 0 {
				return i + 1
			}
		case '\n':
			if !brace && depth == 0 {
				return i
			}
		}
	}
	return len(code)
}

// Fields は record の本体 ({ a = T, ... }) の欄。record でなければ nil。
func Fields(body string) []Field {
	if !strings.HasPrefix(body, "{") || !strings.HasSuffix(body, "}") {
		return nil
	}
	inner := body[1 : len(body)-1]
	var out []Field
	depth, from := 0, 0
	flush := func(to int) {
		part := inner[from:to]
		if eq := strings.Index(part, "="); eq >= 0 {
			name := strings.TrimSpace(part[:eq])
			lead := len(part) - len(strings.TrimLeft(part, " \t\r\n"))
			out = append(out, Field{Name: name, Type: strings.TrimSpace(part[eq+1:]), At: 1 + from + lead})
		}
	}
	for i := 0; i < len(inner); i++ {
		switch inner[i] {
		case '{', '[', '(':
			depth++
		case '}', ']', ')':
			depth--
		case ',':
			if depth == 0 {
				flush(i)
				from = i + 1
			}
		}
	}
	flush(len(inner))
	return out
}

// sizer はパッケージの型エイリアスから展開した大きさを数える。
type sizer struct {
	aliases map[string]Alias
}

// size は型の式 t (モジュール mod の中で書かれた物) を展開した欄の総数と、数えた宣言のあるファイル。
func (s sizer) size(mod, t string, stack map[string]bool, sources map[string]bool) int {
	if fields := Fields(t); fields != nil {
		total := len(fields)
		for _, f := range fields {
			total += s.size(mod, f.Type, stack, sources)
		}
		return total
	}
	total := 0
	for _, m := range typeNameRe.FindAllStringSubmatch(t, -1) {
		owner := m[1]
		if owner == "" {
			owner = mod
		}
		key := owner + "." + m[2]
		a, ok := s.aliases[key]
		if !ok || stack[key] {
			continue
		}
		stack[key] = true
		sources[a.Path] = true
		total += s.size(a.Mod, a.Body, stack, sources)
		delete(stack, key)
	}
	return total
}

// PackageHits はパッケージの型エイリアスから、roots の欄で threshold 以上の物を返す。
func PackageHits(aliases []Alias, roots []string, threshold int) []Hit {
	s := sizer{aliases: map[string]Alias{}}
	for _, a := range aliases {
		s.aliases[a.key()] = a
	}
	var hits []Hit
	for _, root := range roots {
		a, ok := s.aliases[root]
		if !ok {
			continue
		}
		for _, f := range Fields(a.Body) {
			sources := map[string]bool{}
			n := s.size(a.Mod, f.Type, map[string]bool{root: true}, sources)
			if n < threshold {
				continue
			}
			line := 1 + strings.Count(a.Text[:a.Offset+strings.Index(a.Body, "{")+f.At], "\n")
			hits = append(hits, Hit{Path: a.Path, Line: line, Root: root, Field: f.Name,
				Type: f.Type, Size: n, Sources: sources})
		}
	}
	return hits
}

// packageOf は rel の属するパッケージ (flix.toml を持つ一番近いフォルダ)。見つからなければ "".
func packageOf(root, rel string) string {
	dir := filepath.Dir(filepath.FromSlash(rel))
	for dir != "." && dir != string(filepath.Separator) && dir != "" {
		if isFile(filepath.Join(root, dir, "flix.toml")) {
			return filepath.ToSlash(dir)
		}
		dir = filepath.Dir(dir)
	}
	return ""
}

func isFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

// packageFiles は pkg の .flix を並べる。入れ子のパッケージと skipDirNames の中には降りない。
func (r *Rules) packageFiles(root, pkg string) ([]string, error) {
	base := filepath.Join(root, filepath.FromSlash(pkg))
	pkgSkipped := r.hasSkipPrefix(pkg + "/")
	var files []string
	err := filepath.WalkDir(base, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel := flixdecl.RelTo(root, path)
		if d.IsDir() {
			if path == base {
				return nil
			}
			name := d.Name()
			if strings.HasPrefix(name, ".") || r.isSkipDirName(name) ||
				isFile(filepath.Join(path, "flix.toml")) ||
				(!pkgSkipped && r.hasSkipPrefix(rel+"/")) {
				return filepath.SkipDir
			}
			return nil
		}
		if r.IsFlix(rel) {
			files = append(files, rel)
		}
		return nil
	})
	sort.Strings(files)
	return files, err
}

// allPackages はリポの中の flix.toml を全部探す (ルートも含む)。
func (r *Rules) allPackages(root string) ([]string, error) {
	pkgs := []string{""}
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() || path == root {
			return nil
		}
		rel := flixdecl.RelTo(root, path)
		if strings.HasPrefix(d.Name(), ".") || r.isSkipDirName(d.Name()) || r.hasSkipPrefix(rel+"/") {
			return filepath.SkipDir
		}
		if isFile(filepath.Join(path, "flix.toml")) {
			pkgs = append(pkgs, rel)
		}
		return nil
	})
	return pkgs, err
}

func (r *Rules) scanPackage(root, pkg string, extra []string) ([]Hit, error) {
	files, err := r.packageFiles(root, pkg)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for _, f := range files {
		seen[f] = true
	}
	for _, f := range extra {
		if !seen[f] {
			files = append(files, f)
		}
	}
	var aliases []Alias
	var enums []Enum
	for _, f := range files {
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(f)))
		if err != nil {
			return nil, fmt.Errorf("読めません: %v", err)
		}
		aliases = append(aliases, ParseAliases(f, string(body))...)
		enums = append(enums, ParseEnums(f, string(body))...)
	}
	hits := PackageHits(aliases, r.Roots, r.Threshold)
	return append(hits, WorldHits(aliases, enums, r.Roots, r.ResourceTypes, r.MaxTopFields)...), nil
}

// Run は fge record-wrap の本体。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	all, warn := false, false
	var named []string
	for _, a := range args {
		switch {
		case a == "--all":
			all = true
		case a == "--warn":
			warn = true
		case strings.HasPrefix(a, "--"):
		default:
			named = append(named, a)
		}
	}

	var hits []Hit
	if all {
		pkgs, err := rules.allPackages(root)
		if err != nil {
			return 2, err
		}
		for _, pkg := range pkgs {
			found, err := rules.scanPackage(root, pkg, nil)
			if err != nil {
				return 2, err
			}
			hits = append(hits, found...)
		}
	} else {
		byPkg := map[string][]string{}
		want := map[string]bool{}
		for _, p := range named {
			abs := p
			if !filepath.IsAbs(abs) {
				abs = filepath.Join(root, p)
			}
			rel := flixdecl.RelTo(root, abs)
			if !rules.IsFlix(rel) {
				continue
			}
			pkg := packageOf(root, rel)
			byPkg[pkg] = append(byPkg[pkg], rel)
			want[rel] = true
		}
		if len(want) == 0 {
			fmt.Fprintln(out, "[lint-record-wrap] 見るファイルがありません")
			return 0, nil
		}
		pkgs := make([]string, 0, len(byPkg))
		for pkg := range byPkg {
			pkgs = append(pkgs, pkg)
		}
		sort.Strings(pkgs)
		for _, pkg := range pkgs {
			found, err := rules.scanPackage(root, pkg, byPkg[pkg])
			if err != nil {
				return 2, err
			}
			for _, h := range found {
				if want[h.Path] || touches(h.Sources, want) {
					hits = append(hits, h)
				}
			}
		}
	}
	return report(out, errOut, root, rules, hits, all, warn), nil
}

func touches(sources, want map[string]bool) bool {
	for p := range sources {
		if want[p] {
			return true
		}
	}
	return false
}

func report(out, errOut *strings.Builder, root string, rules *Rules, hits []Hit, all, warn bool) int {
	var big, resource, fields []Hit
	live := map[string]bool{}
	for _, h := range hits {
		live[h.key()] = true
		switch h.Rule {
		case "":
			if _, ok := rules.Exempt[h.key()]; !ok {
				big = append(big, h)
			}
		case RuleWorldResource:
			if _, ok := rules.ExemptRules.Why[h.key()]; !ok {
				resource = append(resource, h)
			}
		case RuleWorldFields:
			if _, ok := rules.ExemptRules.Why[h.key()]; !ok {
				fields = append(fields, h)
			}
		}
	}
	code := 0
	if all {
		code = reportStale(errOut, rules, live, root)
	}
	silenced := 0
	for key := range live {
		_, size := rules.Exempt[key]
		_, world := rules.ExemptRules.Why[key]
		if size || world {
			silenced++
		}
	}
	if len(big)+len(resource)+len(fields) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-record-wrap] OK (展開した大きさ %d 以上の欄なし・World の一番上の欄 %d 以下・Doc と描く元なし / 除外で黙らせた %d 件)\n",
				rules.Threshold, rules.MaxTopFields, silenced)
		}
		return finish(errOut, code, warn)
	}
	reportBig(errOut, rules, big)
	reportResource(errOut, rules, resource)
	reportFields(errOut, rules, fields)
	return finish(errOut, 1, warn)
}

func reportStale(errOut *strings.Builder, rules *Rules, live map[string]bool, root string) int {
	var stale []string
	for key := range rules.Exempt {
		if !live[key] {
			stale = append(stale, key)
		}
	}
	sort.Strings(stale)
	for _, key := range stale {
		fmt.Fprintf(errOut, "  %s は exempt に載っていますが、もう鳴る所がありません\n", key)
	}
	staleRules := rules.ExemptRules.Stale(root, live)
	for _, key := range staleRules {
		fmt.Fprintf(errOut, "  %s は %s の exemptRules に載っていますが、もう鳴る所がありません\n",
			key, rules.ExemptRules.From[key])
	}
	if len(stale)+len(staleRules) == 0 {
		return 0
	}
	fmt.Fprintf(errOut, "[lint-record-wrap] 古い除外 %d 件。載っているファイルから消してください\n", len(stale)+len(staleRules))
	return 1
}

func reportBig(errOut *strings.Builder, rules *Rules, bad []Hit) {
	if len(bad) == 0 {
		return
	}
	sort.SliceStable(bad, func(i, j int) bool { return bad[i].Size > bad[j].Size })
	fmt.Fprintf(errOut, "!! %s の欄が大きな record を包まずに持っています (展開した大きさ %d 以上)\n",
		strings.Join(rules.Roots, " / "), rules.Threshold)
	for _, h := range bad {
		fmt.Fprintf(errOut, "   %s:%d %s = %s (展開すると %d)\n", h.Path, h.Line, h.Field, h.Type, h.Size)
	}
	fmt.Fprintf(errOut, "[lint-record-wrap] %d 件。record の型エイリアスは使われるたびに中身のまま展開されるので、"+
		"World を取る全 def で型の木が大きくなり flix check の時間とメモリが伸びます。"+
		"\n  1 case の enum で包むと展開が止まります (docs/flix-conventions.md「型の設計」)。"+
		"\n  どうしても残すなら %sの exempt へ \"World.World::欄名\" と理由 1 行\n", len(bad), exemptFile)
}

// exemptFile は除外を書く所。
// WhyNot: エンジンのリポの根に local.json を置かないのは、bin/lint-rules を丸ごとゲームへ配るので
// ゲームの local を上書きしてしまうため。エンジン自身の除外は配る側の record-wrap.json に書く。
const exemptFile = "bin/lint-rules/record-wrap.local.json（エンジンのリポでは record-wrap.json）"

// worldShapeDoc は World の形の 2 規則の hint が指す文書の節。
const worldShapeDoc = "engine の docs/flix-conventions.md「型の設計」の「World は遊びの状態だけを持つ（Doc は Resources・画面は enum）」"

func reportResource(errOut *strings.Builder, rules *Rules, bad []Hit) {
	if len(bad) == 0 {
		return
	}
	fmt.Fprintf(errOut, "!! %s の欄が Doc や描く元を持っています (%s)\n", strings.Join(rules.Roots, " / "), RuleWorldResource)
	for _, h := range bad {
		fmt.Fprintf(errOut, "   %s:%d %s = %s (%s)\n", h.Path, h.Line, h.Field, h.Type, strings.Join(h.Found, ", "))
	}
	fmt.Fprintf(errOut, "[lint-record-wrap] %s %d 件。Doc と描く元は World の外へ"+
		"（engine の Resources・手本 engine の templates/game-starter と templates/tidepool-starter の src/Res.flix、"+
		"読み直しは Resources.reloadRow）。"+
		"\n  詳しくは %s。"+
		"\n  どうしても残すなら %sの exemptRules へ \"<パス>::%s\" と理由 1 行\n",
		RuleWorldResource, len(bad), worldShapeDoc, exemptFile, RuleWorldResource)
}

func reportFields(errOut *strings.Builder, rules *Rules, bad []Hit) {
	if len(bad) == 0 {
		return
	}
	fmt.Fprintf(errOut, "!! %s の一番上の欄が %d を超えています (%s)\n", strings.Join(rules.Roots, " / "), rules.MaxTopFields, RuleWorldFields)
	for _, h := range bad {
		fmt.Fprintf(errOut, "   %s:%d %s の欄 %d 個\n", h.Path, h.Line, h.Root, h.Size)
	}
	fmt.Fprintf(errOut, "[lint-record-wrap] %s %d 件。その画面だけの値は画面の enum の payload へ"+
		"（手本 engine の templates/tidepool-starter の Screen）。"+
		"\n  詳しくは %s。"+
		"\n  どうしても残すなら %sの exemptRules へ \"<パス>::%s\" と理由 1 行\n",
		RuleWorldFields, len(bad), worldShapeDoc, exemptFile, RuleWorldFields)
}

// finish は --warn のとき終了コードだけを 0 に倒す。
func finish(errOut *strings.Builder, code int, warn bool) int {
	if warn && code != 0 {
		fmt.Fprintln(errOut, "[lint-record-wrap] --warn なので止めません")
		return 0
	}
	return code
}
