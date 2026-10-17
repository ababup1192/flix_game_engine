package apidiff

// apidiff — 2 つのバージョンの pub 面を突き合わせて、消えた・増えた・中身が変わった宣言を出す。
//
//	fge api-diff --from v0.28.0                 そのバージョンと作業ツリーを比べる
//	fge api-diff --from v0.28.0 --to v0.31.0    バージョンどうしを比べる
//	fge api-diff --from auto                    1 つ前のリリースと作業ツリーを比べる
//	fge api-diff --from none                    初リリース（比べる相手が無いと明示する）
//	fge api-diff --root DIR                     リポジトリのルートを差し替える
//
// ゲームを新しい engine へ載せ替えるとき、何が壊れたのかを機械が出す。
// 見るのは flixdecl.Packages の 3 本だけで、render_gl は入らない（GL の境界の内側で
// pub 面の決まりが違い、ゲームが直接呼ばない）。出力にもその旨を 1 行出す。
//
// WhyNot: docs/api-digest/*.md を diff しないのは、あれが doc コメントを含む見せ物で、
// コメントだけの書き直しが「API が変わった」に化けるため。
//
// WhyNot: git grep で 1 行ずつ拾わないのは、宣言が複数行にまたがるため。
// PxSpriteDoc.Sprite のようなレコードは 1 行目が `pub type alias Sprite = {` で、
// フィールドの増減が行に出ない。ソースを取り出して flixdecl に解かせる。

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/flixdecl"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

const usage = "使い方: fge api-diff --from <バージョン|auto|none> [--to <バージョン>] [--root DIR] [--json]"

// fetchTimeout は git fetch を諦めるまで。疎通しないリモートで固まらないための上限。
const fetchTimeout = 10 * time.Second

var (
	versionRe = regexp.MustCompile(`(?m)^VERSION\s*:=\s*(\S+)`)
	memberRe  = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_]*)\s*=`)
	variantRe = regexp.MustCompile(`^case\s+([A-Za-z_][A-Za-z0-9_]*)`)
	// tidyRe は比較用に空白を削る位置（区切り記号の隣）。
	tidyRe = regexp.MustCompile(`\s*([(){}\[\],:])\s*`)
)

// Key は宣言 1 つの居場所。名前だけだと engine_world に 2 つある `draw` を取り違える。
//
// WhyNot: mod を親から連ねないのは、flixdecl がいちばん内側の名前しか返さないため。
// 入れ子 mod が生えたら、別ファイルの同名の内側 mod と鍵がぶつかる（今は 0 件）。
type Key struct {
	Package string `json:"package"`
	Mod     string `json:"mod"`
	Name    string `json:"name"`
}

// Change は 1 つの宣言に起きたこと。
type Change struct {
	Key
	// Kind は "removed" / "added" / "changed" のどれか。
	Kind string `json:"kind"`
	// Before / After は 1 行にまとめた宣言（無い側は空）。
	Before string `json:"before,omitempty"`
	After  string `json:"after,omitempty"`
	// 中身の増減（type alias のフィールド・enum の variant）。changed のときだけ。
	MembersRemoved []string `json:"membersRemoved,omitempty"`
	MembersAdded   []string `json:"membersAdded,omitempty"`
	// GrowthOnly は中身が増えただけ（減っていない）とき真。
	//
	// WhyNot: 増えただけでも Breaking に置くのは、Flix ではレコードを組むとき全部の
	// フィールドが要り、enum の match も網羅が要り、eff の handler も全 op が要るため。
	// ただし下流（update-plan）が読む順を決められるよう、印だけは分けて渡す。
	GrowthOnly bool `json:"growthOnly,omitempty"`
}

// SchemaChange は Doc の schema 1 枚に起きたこと。
type SchemaChange struct {
	Name string `json:"name"`
	Kind string `json:"kind"`
}

// Result は突き合わせの全体。--json はこの形で出る。
//
// WhyNot: 終了コードを結果に持たないのは、この道具が裁かずに報告するだけのため。
// 壊れた宣言が何件あっても 0 で終わる（止めるかどうかは呼ぶ側 —— リリースのゲートや
// update-plan —— が決める）。
type Result struct {
	From string `json:"from"`
	To   string `json:"to"`
	// Breaking は呼ぶ側を直す必要がある物（消えた・中身が変わった・eff に op が増えた）。
	Breaking []Change `json:"breaking"`
	// Added は増えただけの宣言。読むだけでよい。
	Added []Change `json:"added"`
	// Schemas は docs/*.schema.json に起きたこと。
	Schemas []SchemaChange `json:"schemas"`
	// UndiagnosableDocs は schema を持たない Doc の種（診られないと明示するための一覧）。
	UndiagnosableDocs []string `json:"undiagnosableDocs"`
	// Notices は fail-open した事実の告知（黙って既定へ落ちたことを隠さない）。
	Notices []string `json:"notices"`
}

// Run は突き合わせを走らせて終了コードを返す。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	from, to := "", ""
	asJSON := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--json":
			asJSON = true
		case a == "--from" || a == "--to":
			// WhyNot: 次の引数が `--` で始まるときに弾くのは、`--from --json` のような
			// 打ち間違いでフラグをバージョン名として git へ渡してしまわないため。
			if i+1 >= len(args) || strings.HasPrefix(args[i+1], "--") {
				fmt.Fprintf(errOut, "error: %s にはバージョンを渡してください\n%s\n", a, usage)
				return 2, nil
			}
			if a == "--from" {
				from = args[i+1]
			} else {
				to = args[i+1]
			}
			i++
		case strings.HasPrefix(a, "--from="):
			from = strings.TrimPrefix(a, "--from=")
		case strings.HasPrefix(a, "--to="):
			to = strings.TrimPrefix(a, "--to=")
		default:
			fmt.Fprintf(errOut, "error: 知らない引数です: %s\n%s\n", a, usage)
			return 2, nil
		}
	}
	if from == "" {
		fmt.Fprintf(errOut, "error: --from を指定してください\n%s\n", usage)
		return 2, nil
	}

	notice := ""
	if from == "auto" {
		picked, said, err := fetchPreviousTag(root)
		if err != nil {
			// WhyNot: 何も知らせずに 0 で終わらないのは、「差分ゼロ」と区別が付かないため。
			// 無言で成功すると、非互換を配ったまま緑になる。
			return 2, err
		}
		from, notice = picked, said
	}

	res, err := Compute(root, from, to)
	if err != nil {
		return 2, err
	}
	if notice != "" {
		res.Notices = append(res.Notices, notice)
	}
	writeResult(out, errOut, res, asJSON)
	return 0, nil
}

// newResult は空の一覧を入れた結果を返す。
//
// WhyNot: nil のままにしないのは、JSON が経路によって null と [] に割れるため。
// 読む側（Studio / CI）に 2 通りの場合分けを強いる。
func newResult() Result {
	return Result{
		Breaking: []Change{}, Added: []Change{},
		Schemas: []SchemaChange{}, UndiagnosableDocs: []string{}, Notices: []string{},
	}
}

// versionLabelOf は「比べた相手」の表示名。--to が無ければ作業ツリーの VERSION。
func versionLabelOf(root, to string) string {
	if to != "" {
		return to
	}
	if v, ok := makefileVersion(root); ok {
		return v + " (作業ツリー)"
	}
	return "作業ツリー"
}

// makefileVersion は Makefile の `VERSION := x.y.z` を読む。
func makefileVersion(root string) (string, bool) {
	text, err := pxlib.LoadTextReplace(filepath.Join(root, "Makefile"))
	if err != nil {
		return "", false
	}
	if m := versionRe.FindStringSubmatch(text); m != nil {
		return m[1], true
	}
	return "", false
}

// fetchPreviousTag は Makefile の VERSION より小さい最大のタグを、告知の 1 行と共に返す。
//
// WhyNot: 先に fetch するのは、gh release create がリモートにタグを作るだけで手元へ
// 落ちてこないため。手元のタグが古いままだと、実際より何バージョンも前を「1 つ前」と読む。
func fetchPreviousTag(root string) (string, string, error) {
	notice := ""
	// WhyNot: fetch の失敗で止めないのは、ネットワークの無い所でも手元のタグで進めるため。
	// ただし黙らない —— 上の読み違えがそのまま起きるので、告知を 1 行返す。
	if err := runGitQuiet(root, "fetch", "--tags", "--quiet", "origin"); err != nil {
		notice = "fail-open: git fetch に失敗しました。手元のタグだけで「1 つ前」を選びます"
	}

	current, ok := makefileVersion(root)
	if !ok {
		return "", notice, fmt.Errorf("Makefile に VERSION := がありません")
	}
	currentVal := parseVersion(current)

	stdout, err := exec.Command("git", "-C", root, "tag", "--list", "v*").Output()
	if err != nil {
		return "", notice, fmt.Errorf("git tag を呼べません: %v", err)
	}
	best, bestVal, skipped := "", []int(nil), 0
	for _, line := range pxlib.SplitLines(string(stdout)) {
		tag := strings.TrimSpace(line)
		if tag == "" {
			continue
		}
		v := parseVersion(strings.TrimPrefix(tag, "v"))
		if v == nil {
			skipped++
			continue
		}
		if !versionLess(v, currentVal) {
			continue
		}
		if bestVal == nil || versionLess(bestVal, v) {
			best, bestVal = tag, v
		}
	}
	if skipped > 0 {
		notice = strings.TrimSpace(notice + fmt.Sprintf(
			"\n数として読めないタグ %d 個は見ていません（v0.31.0-rc1 のような形）", skipped))
	}
	if best == "" {
		return "", notice, fmt.Errorf(
			"v%s より前のタグが 1 つもありません（初リリースなら --from none）", current)
	}
	return best, notice, nil
}

// runGitQuiet は git を上限付きで走らせる。出力は捨てて成否だけ返す。
//
// WhyNot: GIT_TERMINAL_PROMPT=0 を渡すのは、認証の要るリモートで git が /dev/tty から
// 名前を聞きに行き、上限の外側で止まってしまうため。
func runGitQuiet(root string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), fetchTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", root}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	return cmd.Run()
}

// parseVersion は "0.31.0" を数の並びにする。読めなければ nil。
func parseVersion(s string) []int {
	parts := strings.Split(strings.TrimSpace(s), ".")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// versionLess はバージョンの大小。
//
// WhyNot: 字の順で比べないのは、それだと 0.10.0 < 0.9.0 になるため。
func versionLess(a, b []int) bool {
	for i := 0; i < len(a) || i < len(b); i++ {
		x, y := 0, 0
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y {
			return x < y
		}
	}
	return false
}

// wantedPaths はタグから取り出す物。pub 面と Doc の schema だけあれば足りる。
//
// WhyNot: パッケージの一覧を自分で持たないのは、flixdecl.Packages と食い違うと
// 取り出されなかったパッケージの宣言が丸ごと「増えた」に化けて、非互換を見落とす方向に
// 静かに壊れるため。
func wantedPaths(files []string) []string {
	var out []string
	for _, pkg := range flixdecl.Packages {
		if slices.ContainsFunc(files, func(f string) bool {
			return strings.HasPrefix(f, pkg.Root+"/")
		}) {
			out = append(out, pkg.Root)
		}
	}
	// WhyNot: docs を丸ごと取り出さないのは、あそこが 4.5MB あって要るのは schema
	// 数枚だけのため。
	for _, f := range files {
		if strings.HasPrefix(f, "docs/") && strings.HasSuffix(f, ".schema.json") {
			out = append(out, f)
		}
	}
	return out
}

// exportSources はタグ tag のソースをテンポラリへ取り出し、そのルートと後始末を返す。
//
// WhyNot: git worktree を使わないのは、.git を共有して .git/worktrees/ に残骸とロックを
// 残すため（途中で落ちると次の git 操作とぶつかる）。git archive は読み取りだけで、
// 後始末はテンポラリ 1 個を消すだけで済む。
func exportSources(root, tag string) (string, func(), error) {
	// WhyNot: 先に中身を数えるのは、古いタグに無いパスを git archive へ渡すと
	// 全体が落ちるため（このリポの v0.1.0〜v0.3.1 には docs/ が無い）。
	listed, err := exec.Command("git", "-C", root, "ls-tree", "-r", "--name-only", tag).Output()
	if err != nil {
		return "", func() {}, fmt.Errorf("%s のソースを取り出せません（そのタグはありますか）", tag)
	}
	paths := wantedPaths(pxlib.SplitLines(string(listed)))
	if len(paths) == 0 {
		return "", func() {}, fmt.Errorf("%s に engine のソースがありません", tag)
	}

	dir, err := os.MkdirTemp("", "fge-apidiff-")
	if err != nil {
		return "", func() {}, fmt.Errorf("テンポラリを作れません: %v", err)
	}
	cleanup := func() { _ = os.RemoveAll(dir) }

	args := append([]string{"-C", root, "archive", "--format=tar", tag, "--"}, paths...)
	archive := exec.Command("git", args...)
	untar := exec.Command("tar", "-x", "-C", dir)
	pipe, err := archive.StdoutPipe()
	if err != nil {
		cleanup()
		return "", func() {}, fmt.Errorf("%s のソースを取り出せません: %v", tag, err)
	}
	untar.Stdin = pipe
	if err := untar.Start(); err != nil {
		cleanup()
		return "", func() {}, fmt.Errorf("tar を起こせません: %v", err)
	}
	if err := archive.Run(); err != nil {
		_ = untar.Wait()
		cleanup()
		return "", func() {}, fmt.Errorf("%s のソースを取り出せません", tag)
	}
	if err := untar.Wait(); err != nil {
		cleanup()
		return "", func() {}, fmt.Errorf("%s のソースを展開できません", tag)
	}
	return dir, cleanup, nil
}

// declarationsIn は 1 つのソースの (パッケージ, mod, 名前) → 宣言の表を作る。
func declarationsIn(root string) map[Key]string {
	out := map[Key]string{}
	for _, pkg := range flixdecl.Packages {
		for _, file := range flixdecl.ScanPackage(root, pkg) {
			for _, md := range file.Mods {
				for _, d := range md.Decls {
					// WhyNot: doc コメント (d.Doc) を鍵にも値にも入れないのは、
					// コメントだけの書き直しを「API が変わった」と読ませないため。
					key := Key{Package: pkg.Name, Mod: md.Mod, Name: flixdecl.DeclName(d.Text)}
					out[key] = d.Text
				}
			}
		}
	}
	return out
}

// tidy は比較用に、区切り記号の隣の空白を落とした字面を返す。
//
// WhyNot: 元の字面のまま比べないのは、長い宣言を複数行へ折り返しただけで
// `( ` や `{ ` の空白が残り、意味が変わっていないのに「変わった」と鳴るため。
// 表示には元の字面を使う。
func tidy(decl string) string { return tidyRe.ReplaceAllString(decl, "$1") }

// hasMembers は中身の増減を見てよい宣言か（レコードと enum だけ）。
//
// WhyNot: def を外すのは、引数と戻り値の両方にレコードを持つ def で
// 別々の袋の名前が 1 つに混ざり、「どこが変わったか」を読み違えさせるため。
func hasMembers(decl string) bool {
	return strings.HasPrefix(decl, "pub type alias ") || strings.HasPrefix(decl, "pub enum ")
}

// fillDiff は 2 つのソースを突き合わせて結果を埋める。
func fillDiff(res *Result, beforeRoot, afterRoot string, docKinds []string) {
	before, after := declarationsIn(beforeRoot), declarationsIn(afterRoot)

	for key, oldText := range before {
		newText, still := after[key]
		if !still {
			res.Breaking = append(res.Breaking,
				Change{Key: key, Kind: "removed", Before: oldText})
			continue
		}
		if tidy(newText) == tidy(oldText) {
			continue
		}
		c := Change{Key: key, Kind: "changed", Before: oldText, After: newText}
		if hasMembers(oldText) && hasMembers(newText) {
			c.MembersRemoved, c.MembersAdded = diffMembers(oldText, newText)
			// 中身の並べ替えだけなら、呼ぶ側は直さなくてよい（レコードは行型で順に意味が無い）。
			if len(c.MembersRemoved) == 0 && len(c.MembersAdded) == 0 &&
				sameMembers(oldText, newText) {
				continue
			}
			c.GrowthOnly = len(c.MembersRemoved) == 0 && len(c.MembersAdded) > 0
		}
		res.Breaking = append(res.Breaking, c)
	}

	for key, newText := range after {
		if _, had := before[key]; had {
			continue
		}
		c := Change{Key: key, Kind: "added", After: newText}
		// WhyNot: eff の op が増えたのを「読むだけでよい」に入れないのは、Flix の
		// handler が全 op を書かないと通らず、既にある handler が必ず壊れるため。
		// flixdecl は op を "Audio.setVolume" の形で 1 宣言として返すので、名前の `.` で見分ける。
		if strings.Contains(key.Name, ".") {
			c.GrowthOnly = true
			res.Breaking = append(res.Breaking, c)
			continue
		}
		res.Added = append(res.Added, c)
	}
	sortChanges(res.Breaking)
	sortChanges(res.Added)
	res.Schemas = diffSchemas(beforeRoot, afterRoot)
	res.UndiagnosableDocs = undiagnosableDocs(afterRoot, docKinds)
}

func sortChanges(cs []Change) {
	sort.SliceStable(cs, func(i, j int) bool {
		a, b := cs[i], cs[j]
		if a.Package != b.Package {
			return a.Package < b.Package
		}
		if a.Mod != b.Mod {
			return a.Mod < b.Mod
		}
		return a.Name < b.Name
	})
}

// diffMembers はレコードのフィールド・enum の variant の増減を返す。
func diffMembers(before, after string) ([]string, []string) {
	old, next := membersOf(before), membersOf(after)
	var removed, added []string
	for _, m := range old {
		if !slices.Contains(next, m) {
			removed = append(removed, m)
		}
	}
	for _, m := range next {
		if !slices.Contains(old, m) {
			added = append(added, m)
		}
	}
	return removed, added
}

// sameMembers は中身の顔ぶれが同じか（並びは見ない）。
func sameMembers(before, after string) bool {
	old, next := slices.Clone(membersOf(before)), slices.Clone(membersOf(after))
	sort.Strings(old)
	sort.Strings(next)
	return slices.Equal(old, next)
}

// membersOf はレコードのフィールド名・enum の variant 名を、いちばん外側の `{ }` から拾う。
func membersOf(decl string) []string {
	open := strings.IndexByte(decl, '{')
	end := strings.LastIndexByte(decl, '}')
	if open < 0 || end < open {
		return nil
	}
	inner := decl[open+1 : end]

	var parts []string
	depth, start := 0, 0
	for i := 0; i < len(inner); i++ {
		switch inner[i] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case ',':
			// WhyNot: 深さを数えるのは、Map[String, Clip] の中のカンマで割らないため。
			if depth == 0 {
				parts = append(parts, inner[start:i])
				start = i + 1
			}
		}
	}
	parts = append(parts, inner[start:])

	var out []string
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if m := memberRe.FindStringSubmatch(p); m != nil {
			out = append(out, m[1])
			continue
		}
		if m := variantRe.FindStringSubmatch(p); m != nil {
			out = append(out, m[1])
		}
	}
	return out
}

// diffSchemas は docs/*.schema.json の増減と書き換わりを返す。
//
// WhyNot: after 側の名前だけで回さないのは、消えた schema を見落とすため。
// 見落とすと、その種は undiagnosableDocs へ移って「元々 schema が無い種」と同じ字面になり、
// 退行が「診られない物の報告」に化ける。
func diffSchemas(beforeRoot, afterRoot string) []SchemaChange {
	oldNames, newNames := schemaNames(beforeRoot), schemaNames(afterRoot)
	var out []SchemaChange
	for _, name := range oldNames {
		if !slices.Contains(newNames, name) {
			out = append(out, SchemaChange{Name: name, Kind: "removed"})
			continue
		}
		a, aErr := os.ReadFile(filepath.Join(afterRoot, "docs", name))
		b, bErr := os.ReadFile(filepath.Join(beforeRoot, "docs", name))
		if aErr == nil && bErr == nil && string(a) != string(b) {
			out = append(out, SchemaChange{Name: name, Kind: "changed"})
		}
	}
	for _, name := range newNames {
		if !slices.Contains(oldNames, name) {
			out = append(out, SchemaChange{Name: name, Kind: "added"})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// schemaNames は docs/ 直下の *.schema.json の名前。
func schemaNames(root string) []string {
	entries, err := os.ReadDir(filepath.Join(root, "docs"))
	if err != nil {
		return nil
	}
	out := []string{}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".schema.json") {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out
}

// undiagnosableDocs は schema を持たない Doc の種を返す。
//
// WhyNot: 空の一覧を返して済ませないのは、「schema の差分で全部拾える」と思わせないため。
// shader.json は知らない kind を何も知らせず fail-open するので、診られない物こそ名指しが要る。
func undiagnosableDocs(root string, docKinds []string) []string {
	have := map[string]bool{}
	for _, name := range schemaNames(root) {
		have[strings.TrimSuffix(name, ".schema.json")] = true
	}
	out := []string{}
	for _, kind := range docKinds {
		if !have[kind] {
			out = append(out, kind)
		}
	}
	return out
}

// writeResult は結果を書き出す。
func writeResult(out, errOut *strings.Builder, res Result, asJSON bool) {
	if asJSON {
		blob, err := json.MarshalIndent(res, "", "  ")
		if err != nil {
			fmt.Fprintf(errOut, "fail-open: JSON にできませんでした (%v)。文字で出します\n", err)
		} else {
			out.Write(blob)
			out.WriteByte('\n')
			return
		}
	}
	for _, n := range res.Notices {
		fmt.Fprintf(out, "[api-diff] %s\n", n)
	}
	fmt.Fprintf(out, "[api-diff] %s -> %s\n", res.From, res.To)
	if res.From == "none" {
		fmt.Fprintln(out, "  比べる相手がありません（初リリース）")
		return
	}
	if len(res.Breaking) == 0 {
		fmt.Fprintln(out, "  直す物: なし")
	} else {
		fmt.Fprintf(out, "  直す物 %d 件:\n", len(res.Breaking))
		for _, c := range res.Breaking {
			fmt.Fprintf(out, "    %s %s.%s (%s)\n", kindLabelOf(c), c.Mod, c.Name, c.Package)
			if len(c.MembersRemoved) > 0 {
				fmt.Fprintf(out, "        消えた中身: %s\n", strings.Join(c.MembersRemoved, ", "))
			}
			if len(c.MembersAdded) > 0 {
				fmt.Fprintf(out, "        増えた中身: %s\n", strings.Join(c.MembersAdded, ", "))
			}
			for _, line := range beforeAfterLines(c) {
				fmt.Fprintf(out, "        %s\n", line)
			}
		}
	}
	fmt.Fprintf(out, "  増えた宣言: %d 件（読むだけでよい）\n", len(res.Added))
	for _, c := range res.Added {
		fmt.Fprintf(out, "    %s.%s (%s)\n", c.Mod, c.Name, c.Package)
	}
	for _, s := range res.Schemas {
		fmt.Fprintf(out, "  %s schema: %s\n", schemaLabelOf(s.Kind), s.Name)
	}
	if len(res.UndiagnosableDocs) > 0 {
		fmt.Fprintf(out, "  診られない Doc の種（schema がありません）: %s\n",
			strings.Join(res.UndiagnosableDocs, ", "))
	}
	fmt.Fprintln(out, "  render_gl は見ていません（ゲームが直接呼ばない層）")
}

// beforeAfterLines は前後の宣言を、違う所が見える長さで返す。
//
// WhyNot: 頭から一定の長さで切らないのは、長い宣言だと前後が同じ文字列になって
// 何が変わったのか 1 つも読めなくなるため（切れていることすら分からない）。
func beforeAfterLines(c Change) []string {
	if c.Before == "" {
		return []string{"後: " + clip(c.After, 0)}
	}
	if c.After == "" {
		return []string{"前: " + clip(c.Before, 0)}
	}
	head := commonHeadLen(c.Before, c.After)
	// 違いの少し手前から出す。
	start := head - 20
	if start < 0 {
		start = 0
	}
	return []string{"前: " + clip(c.Before, start), "後: " + clip(c.After, start)}
}

// clip は start 文字目から 200 文字を返し、削った側に … を付ける。
func clip(s string, start int) string {
	runes := []rune(s)
	prefix, suffix := "", ""
	if start > 0 && start < len(runes) {
		runes = runes[start:]
		prefix = "…"
	}
	if len(runes) > 200 {
		runes = runes[:200]
		suffix = "…"
	}
	return prefix + string(runes) + suffix
}

// commonHeadLen は 2 つの字面が同じでいる長さ（文字数）。
func commonHeadLen(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	i := 0
	for i < len(ra) && i < len(rb) && ra[i] == rb[i] {
		i++
	}
	return i
}

func kindLabelOf(c Change) string {
	switch c.Kind {
	case "removed":
		return "消えた"
	case "added":
		return "増えた op（handler を直す）"
	default:
		return "変わった"
	}
}

func schemaLabelOf(kind string) string {
	switch kind {
	case "removed":
		return "消えた"
	case "added":
		return "増えた"
	default:
		return "変わった"
	}
}
