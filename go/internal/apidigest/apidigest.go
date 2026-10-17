package apidigest

// api-digest — engine 系パッケージの pub API を 1 枚のダイジェストにまとめる。
//
//	fge-go api-digest              docs/api-digest.md と docs/api-digest/*.md を書く
//	fge-go api-digest --check      書かずに、ソースとずれていないかだけ見る
//	fge-go api-digest --out DIR    docs/ の代わりに DIR へ書く
//	fge-go api-digest --root DIR   リポジトリのルートを差し替える
//
// AI エージェントが「この関数、型はどんな形だっけ」を調べるたびにソースを grep して
// 丸読みすると、トークンも時間も食う。宣言だけを 1 ファイルにまとめておけば足りる。

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/flixdecl"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

var (
	versionRe   = regexp.MustCompile(`(?m)^VERSION\s*:=\s*(\S+)`)
	stampDateRe = regexp.MustCompile(`生成: \d{4}-\d{2}-\d{2}`)
)

const packageBanner = "<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->\n"

const indexHeader = `<!-- 生成物: bin/fge api-digest が作る。手で編集しない（make api-digest で作り直す） -->

# API ダイジェスト

engine / engine_world / engine_tools が公開している ` + "`pub def`" + ` / ` + "`pub enum`" + ` /
` + "`pub type alias`" + ` の一覧。**API の型・引数を調べる時は、ソースを grep する前に
まずここを読む。** 実装や WhyNot コメントまでは載っていないので、シグネチャだけで
足りないときにだけ元ファイルを開く。

パッケージごとに分けている（1 ファイルが大きくなりすぎると、それ自体を読むのが
grep 代わりの重い作業になってしまうため）。調べたいモジュールがどのパッケージに
あるか分からないときは ` + "`make module Q=<やりたいこと>`" + `（目次は [module-index.md](module-index.md)）を先に引く。

`

// engineVersion は Makefile の VERSION := を読む。読めなければ "?"。
func engineVersion(root string) string {
	data, err := os.ReadFile(filepath.Join(root, "Makefile"))
	if err != nil {
		return "?"
	}
	if m := versionRe.FindSubmatch(data); m != nil {
		return string(m[1])
	}
	return "?"
}

// stampLine は「いつの engine の姿か」を刻む先頭行を返す。
// WhyNot: 日付を内容が変わった時だけ進めるのは、毎回進めると --check の差分ゼロ検査が
// 壊れるため。
func stampLine(root string, today time.Time) string {
	return fmt.Sprintf("<!-- engine v%s / 生成: %s -->\n", engineVersion(root), today.Format("2006-01-02"))
}

// Dateless はスタンプの日付だけを均した本文を返す（差分比較は日付を見ない）。
func Dateless(text string) string {
	return stampDateRe.ReplaceAllString(text, "生成: 0000-00-00")
}

// stats は索引の表に出す 1 行。
type stats struct {
	pkg       string
	modCount  int
	declCount int
}

// modEntry は 1 モジュール分の宣言と、最初に見つかったファイル。
type modEntry struct {
	rel   string
	decls []flixdecl.Decl
}

// buildPackageDigest は 1 パッケージ分の Markdown 本文と、モジュール数・宣言数を返す。
func buildPackageDigest(root string, pkg flixdecl.Package) (string, int, int) {
	lines := []string{
		strings.TrimRight(packageBanner, "\n"),
		"",
		fmt.Sprintf("# API ダイジェスト — %s", pkg.Name),
		"",
		fmt.Sprintf("`%s` 配下の `pub def` / `pub enum` / `pub type alias` の一覧。"+
			"索引は [api-digest.md](../api-digest.md)。", pkg.Root),
	}

	// ファイル単位で走査し、モジュール名 -> (ファイル相対パス, 宣言リスト) に集約。
	// 1 ファイルに複数 mod があってもモジュール単位の見出しに分ける。
	modules := map[string]*modEntry{}
	for _, file := range flixdecl.ScanPackage(root, pkg) {
		for _, md := range file.Mods {
			entry, seen := modules[md.Mod]
			if !seen {
				entry = &modEntry{rel: file.Rel}
				modules[md.Mod] = entry
			}
			entry.decls = append(entry.decls, md.Decls...)
		}
	}

	names := make([]string, 0, len(modules))
	for name := range modules {
		names = append(names, name)
	}
	sort.Strings(names)

	declCount := 0
	for _, mod := range names {
		entry := modules[mod]
		if len(entry.decls) == 0 {
			continue
		}
		lines = append(lines, "", fmt.Sprintf("## %s — `%s`", mod, entry.rel))
		for _, d := range entry.decls {
			declCount++
			if d.Doc != "" {
				lines = append(lines, fmt.Sprintf("- %s", d.Doc), fmt.Sprintf("  `%s`", d.Text))
			} else {
				lines = append(lines, fmt.Sprintf("- `%s`", d.Text))
			}
		}
	}
	lines = append(lines, "")
	return strings.Join(lines, "\n"), len(modules), declCount
}

func buildIndex(all []stats) string {
	lines := []string{
		strings.TrimRight(indexHeader, "\n"),
		"| パッケージ | モジュール数 | 宣言数 | ファイル |",
		"|---|---|---|---|",
	}
	for _, s := range all {
		lines = append(lines, fmt.Sprintf("| %s | %d | %d | [api-digest/%s.md](api-digest/%s.md) |",
			s.pkg, s.modCount, s.declCount, s.pkg, s.pkg))
	}
	lines = append(lines, "")
	return strings.Join(lines, "\n")
}

// Target は書き出す 1 ファイル。
type Target struct {
	Path    string
	Content string
}

// Build は書き出すファイルの一覧（パスと中身）を作る。
func Build(root, docsDir string, today time.Time) []Target {
	stamp := strings.TrimRight(stampLine(root, today), "\n")
	digestDir := filepath.Join(docsDir, "api-digest")
	var targets []Target
	var all []stats
	for _, pkg := range flixdecl.Packages {
		content, modCount, declCount := buildPackageDigest(root, pkg)
		targets = append(targets, Target{filepath.Join(digestDir, pkg.Name+".md"), content})
		all = append(all, stats{pkg.Name, modCount, declCount})
	}
	targets = append(targets, Target{filepath.Join(docsDir, "api-digest.md"), buildIndex(all)})
	for i := range targets {
		targets[i].Content = stamp + "\n" + targets[i].Content
	}
	return targets
}

// Run は生成（または --check）を走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（書けないまま緑にしない）。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	check := false
	docsDir := filepath.Join(root, "docs")
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--check":
			check = true
		case args[i] == "--out" && i+1 < len(args):
			docsDir = args[i+1]
			i++
		case strings.HasPrefix(args[i], "--out="):
			docsDir = strings.TrimPrefix(args[i], "--out=")
		}
	}

	targets := Build(root, docsDir, time.Now())

	if check {
		ok := true
		for _, t := range targets {
			current, err := pxlib.LoadTextReplace(t.Path)
			if err != nil || Dateless(current) != Dateless(t.Content) {
				ok = false
				fmt.Fprintf(errOut, "[gen-api-digest] NG: %s がソースとずれています。"+
					" make api-digest で作り直してください\n", flixdecl.RelTo(root, t.Path))
			}
		}
		if ok {
			fmt.Fprintln(out, "OK: docs/api-digest.md / docs/api-digest/*.md は最新です")
			return 0, nil
		}
		return 1, nil
	}

	for _, t := range targets {
		if err := os.MkdirAll(filepath.Dir(t.Path), 0o755); err != nil {
			return 2, fmt.Errorf("書き出し先を作れません: %v", err)
		}
		current, err := pxlib.LoadTextReplace(t.Path)
		if err == nil && Dateless(current) == Dateless(t.Content) {
			continue // 内容が同じなら日付も進めない (git の空騒ぎを作らない)
		}
		if err := os.WriteFile(t.Path, []byte(t.Content), 0o644); err != nil {
			return 2, fmt.Errorf("書き出せません: %v", err)
		}
		fmt.Fprintf(out, "[gen-api-digest] wrote %s\n", flixdecl.RelTo(root, t.Path))
	}
	return 0, nil
}
