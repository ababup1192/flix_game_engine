package ztable

// z-table — 重なり順の z を数で決める所が、パッケージ (flix.toml の単位) に 1 か所かを見る。
//
//	fge-go z-table                       ステージ前の手で: 名指しが無ければ何も見ない
//	fge-go z-table --all                 リポの全パッケージを見る (古い除外もここで裁く)
//	fge-go z-table [path/to/X.flix ...]  そのファイルの属するパッケージを読み、そのファイルの分だけ出す
//	fge-go z-table --warn ...            出す物は同じで、終了コードだけ 0 にする
//	fge-go z-table --root DIR ...        リポジトリのルートを差し替える
//
// 表のファイルは、名前が tableFileNames にあるか、本文 (コメントを除く) に表の宣言
// (tablePattern。instance SortingLayer[Layer] { ... }) があるファイル。
//
// 規則。初めの 2 つは「z を数で決める 1 行」(def zXxx(): Int32 = 数) だけを見る:
//   - 表のファイルがあるパッケージ: 表の外で数を書いたら鳴る。ただし葉の中の小さな z
//     (leafZRange・0..31) は鳴らさない
//   - 表のファイルが無いパッケージ: 数を書くファイルが 2 本以上あったら全部鳴る
//   - 表のファイルの中: 葉の中の z (0..31) の外の数を書いたら鳴る。表に置くのは層の enum と
//     zRange の範囲 (case の行) と、いくつもの View が分け合う葉の中の段だけ
//   - 付け替え: 表を持つパッケージで、表の外から zMapped・zShifted・zShiftedAll・raiseZ・
//     Depth.place・Depth.placeOne で z を付け替える (remap.go)
//   - 移行の口: 表を持つパッケージで、表の外から SortingLayer.z・ZStack.leafAbsolute を呼ぶ (migration.go)
//
// 除外はエンジンの z-table.json の exempt と、ゲームの z-table.local.json の exempt を足した物。
//
// 数を足し引きした z (zBoard() + 2) と、z を引数で渡す所の数は見ない。帯の中の段として
// 正しい用法が大半で、行だけでは正しい物と区別できないため。範囲の外れは描き出しの後で
// 実物の z を見る監査の仕事。

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/flixdecl"
)

// Def は z を数で決める 1 行。
type Def struct {
	Path  string
	Line  int
	Name  string
	Value string
}

func (d Def) key() string { return d.Path + "::" + d.Name }

// Hit は鳴らす 1 件。
type Hit struct {
	Def
	// Table は表のファイル (無ければ空)。Scatter は数を書いているファイルの一覧 (表が無いときだけ)。
	Table   string
	Scatter []string
	// Same は同じパッケージの別のファイルで同じ数を持つ宣言 ("zGround (src/ViewRoad.flix)")。
	Same []string
	// Remap は付け替えのとき true。Name は呼んだ関数の名前。
	Remap bool
	// Migration は表の外から移行の口を呼んだとき true。Name は呼んだ口の名前。
	Migration bool
	// InTable は表のファイルの中で 0..31 の外の数を書いたとき true。
	InTable bool
}

// DefsOf は 1 ファイルの本文から z を数で決める行を拾う。
func (r *Rules) DefsOf(rel, text string) []Def {
	var defs []Def
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for n := 1; sc.Scan(); n++ {
		if m := r.Const.FindStringSubmatch(sc.Text()); m != nil {
			defs = append(defs, Def{Path: rel, Line: n, Name: m[1], Value: m[2]})
		}
	}
	return defs
}

// PackageHits は 1 パッケージ分の defs (ファイルごと) から鳴らす物を決める。
// files はパッケージの .flix 全部、tables はそのうちの表のファイル (TablesOf)。
// 表が 2 本以上あれば、並びで先の 1 本を表として扱う。
func (r *Rules) PackageHits(files []string, defs map[string][]Def, tables map[string]bool) []Hit {
	var table string
	for _, f := range files {
		if tables[f] && (table == "" || f < table) {
			table = f
		}
	}
	var withDefs []string
	for _, f := range files {
		if len(defs[f]) > 0 {
			withDefs = append(withDefs, f)
		}
	}
	sort.Strings(withDefs)

	var hits []Hit
	for _, f := range withDefs {
		if table != "" && f == table {
			for _, d := range defs[f] {
				if !r.isLeafZ(d.Value) {
					hits = append(hits, Hit{Def: d, Table: table, InTable: true})
				}
			}
			continue
		}
		if table == "" && len(withDefs) < 2 {
			continue
		}
		for _, d := range defs[f] {
			if table != "" && r.isLeafZ(d.Value) {
				continue
			}
			h := Hit{Def: d, Table: table, Same: sameValue(d, withDefs, defs)}
			if table == "" {
				h.Scatter = withDefs
			}
			hits = append(hits, h)
		}
	}
	return hits
}

// isLeafZ は数が葉の中の小さな z の範囲 (LeafZLow..LeafZHigh) にあるか。
func (r *Rules) isLeafZ(value string) bool {
	n, err := strconv.Atoi(value)
	return err == nil && n >= r.LeafZLow && n <= r.LeafZHigh
}

// z を数で決めるファイルが 1 本だけのときのそのファイル。
func (r *Rules) tableFiles(files []string, defs map[string][]Def, found map[string]bool) map[string]bool {
	tables := map[string]bool{}
	var withDefs []string
	for _, f := range files {
		if found[f] {
			tables[f] = true
		}
		if len(defs[f]) > 0 {
			withDefs = append(withDefs, f)
		}
	}
	if len(tables) == 0 && len(withDefs) == 1 {
		tables[withDefs[0]] = true
	}
	return tables
}

func sameValue(d Def, files []string, defs map[string][]Def) []string {
	var same []string
	for _, f := range files {
		if f == d.Path {
			continue
		}
		for _, o := range defs[f] {
			if o.Value == d.Value {
				same = append(same, fmt.Sprintf("%s (%s)", o.Name, o.Path))
			}
		}
	}
	return same
}

// packageOf は rel の属するパッケージ (flix.toml を持つ一番近いフォルダ) を返す。
// 見つからなければルート ("")。
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

// packageFiles は pkg の .flix を全部並べる。入れ子のパッケージの中には降りない。
// WhyNot: git ls-files でなくフォルダを歩くのは、見本 (testdata/) の偽パッケージも
// 同じ道で読めるようにするため。
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

func (r *Rules) hasSkipPrefix(rel string) bool {
	for _, p := range r.SkipPrefixes {
		if strings.HasPrefix(rel, p) {
			return true
		}
	}
	return false
}

func (r *Rules) isSkipDirName(name string) bool {
	for _, n := range r.SkipDirNames {
		if name == n {
			return true
		}
	}
	return false
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

// packageScan は 1 パッケージを読んだ結果。
type packageScan struct {
	hits      []Hit
	defCount int
	tables   map[string]bool
}

// scanPackage は 1 パッケージを読んで鳴らす物を返す。extra は名指しで渡されたファイル
// (歩いても出てこない所にあっても読む)。
func (r *Rules) scanPackage(root, pkg string, extra []string) (packageScan, error) {
	files, err := r.packageFiles(root, pkg)
	if err != nil {
		return packageScan{}, err
	}
	seen := map[string]bool{}
	for _, f := range files {
		seen[f] = true
	}
	for _, f := range extra {
		if !seen[f] {
			files = append(files, f)
			seen[f] = true
		}
	}
	defs := map[string][]Def{}
	bodies := map[string]string{}
	count := 0
	for _, f := range files {
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(f)))
		if err != nil {
			return packageScan{}, fmt.Errorf("読めません: %v", err)
		}
		bodies[f] = string(body)
		defs[f] = r.DefsOf(f, bodies[f])
		count += len(defs[f])
	}
	tables := r.TablesOf(bodies)
	hits := append(r.PackageHits(files, defs, tables), r.RemapHits(bodies, tables)...)
	return packageScan{
		hits:     append(hits, r.MigrationHits(bodies, tables)...),
		defCount: count,
		tables:   tables,
	}, nil
}

// Run は fge z-table の本体。
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
	defCount, pkgCount := 0, 0
	if all {
		pkgs, err := rules.allPackages(root)
		if err != nil {
			return 2, err
		}
		for _, pkg := range pkgs {
			scan, err := rules.scanPackage(root, pkg, nil)
			if err != nil {
				return 2, err
			}
			hits = append(hits, scan.hits...)
			defCount += scan.defCount
		}
		pkgCount = len(pkgs)
	} else {
		byPkg := map[string][]string{}
		want := map[string]bool{}
		for _, p := range named {
			rel := flixdecl.RelTo(root, absOf(root, p))
			if !rules.IsFlix(rel) {
				continue
			}
			pkg := packageOf(root, rel)
			byPkg[pkg] = append(byPkg[pkg], rel)
			want[rel] = true
		}
		if len(want) == 0 {
			fmt.Fprintln(out, "[lint-z-table] 見るファイルがありません")
			return 0, nil
		}
		pkgs := make([]string, 0, len(byPkg))
		for pkg := range byPkg {
			pkgs = append(pkgs, pkg)
		}
		sort.Strings(pkgs)
		for _, pkg := range pkgs {
			scan, err := rules.scanPackage(root, pkg, byPkg[pkg])
			if err != nil {
				return 2, err
			}
			for _, h := range scan.hits {
				if want[h.Path] {
					hits = append(hits, h)
				}
			}
			defCount += scan.defCount
		}
		pkgCount = len(pkgs)
	}
	return report(out, errOut, rules, hits, all, warn, pkgCount, defCount), nil
}

func absOf(root, path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(root, path)
}

func report(out, errOut *strings.Builder, rules *Rules, hits []Hit, all, warn bool, pkgCount, defCount int) int {
	exempt := rules.Exempt
	var bad []Hit
	live := map[string]bool{}
	for _, h := range hits {
		live[h.key()] = true
		if _, ok := exempt[h.key()]; !ok {
			bad = append(bad, h)
		}
	}
	var stale []string
	if all {
		for key := range exempt {
			if !live[key] {
				stale = append(stale, key)
			}
		}
		sort.Strings(stale)
	}

	code := 0
	for _, key := range stale {
		from := rules.ExemptFrom[key]
		if from == "" {
			from = filepath.ToSlash(RulesPath)
		}
		fmt.Fprintf(errOut, "  %s は %s の exempt に載っていますが、もう鳴る所がありません\n", key, from)
	}
	if len(stale) > 0 {
		fmt.Fprintf(errOut, "[lint-z-table] 古い除外 %d 件。"+
			"宿題の一覧として読めなくなるので、書いてあるファイル (z-table.local.json か z-table.json) の exempt から消してください\n", len(stale))
		code = 1
	}
	if len(bad) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-z-table] OK (パッケージ %d / z を数で決める行 %d / 除外 %d 件)\n",
				pkgCount, defCount, len(exempt))
		}
		return finish(errOut, code, warn)
	}
	lastReason := ""
	for _, h := range bad {
		reason := fmt.Sprintf("表 (%s) の外で z を数で決めています", h.Table)
		switch {
		case h.Migration:
			reason = "表の外で移行の口 (SortingLayer.z・ZStack.leafAbsolute) を呼んでいます (層の中の順は ZStack の木に積み、z の数は葉の中だけで書いてください)"
		case h.InTable:
			reason = fmt.Sprintf("表 (%s) に z の数 (葉の中の 0..31 の外) を足しています。"+
				"新しい層は enum に case を足して zRange に範囲を書き、層の中の順は ZStack の木に積んでください"+
				" (必ず手前に出す物は ZStack.topLayer。葉の中の段だけ 0..31 で名前を置けます)", h.Table)
		case h.Remap:
			reason = "表の外で z を関数で付け替えています (付け替えた後の z がどの層に入るかは表から読めません)"
		case h.Table == "":
			reason = fmt.Sprintf("z を数で決めるファイルが %d 本に散っています: %s",
				len(h.Scatter), strings.Join(h.Scatter, " / "))
		}
		if reason != lastReason {
			fmt.Fprintf(errOut, "!! %s\n", reason)
			lastReason = reason
		}
		if h.Remap || h.Migration {
			fmt.Fprintf(errOut, "   %s:%d %s\n", h.Path, h.Line, h.Name)
			continue
		}
		fmt.Fprintf(errOut, "   %s:%d %s = %s", h.Path, h.Line, h.Name, h.Value)
		if len(h.Same) > 0 {
			fmt.Fprintf(errOut, "  (同じ数: %s)", strings.Join(h.Same, " / "))
		}
		fmt.Fprintln(errOut)
	}
	fmt.Fprintf(errOut, "[lint-z-table] %d 件。z の数が散ると、別のファイルどうしで同じ数を取り合い、"+
		"どちらが手前かが描き順まかせになります。"+
		"\n  代わりに: 部品の並びは ZStack.of に奥 → 手前で積み、必ず手前の物は ZStack.topLayer(層, …)、新しい層は表の enum に case を足す。"+
		"z の数を書くのは葉の中の前後 (0..31) だけ。表がまだ無ければ 1 ファイルに集めてください"+
		" (範囲の地図は engine の docs/z-bands.md)。"+
		"\n  どうしても残すなら bin/lint-rules/z-table.local.json (ゲーム) か z-table.json (エンジン) の exempt へ"+
		" \"パス::名前\" と理由 1 行\n", len(bad))
	return finish(errOut, 1, warn)
}

// finish は --warn のとき終了コードだけを 0 に倒す。
func finish(errOut *strings.Builder, code int, warn bool) int {
	if warn && code != 0 {
		fmt.Fprintln(errOut, "[lint-z-table] --warn なので止めません")
		return 0
	}
	return code
}
