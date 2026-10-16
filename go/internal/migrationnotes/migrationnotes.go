package migrationnotes

// migrationnotes — 1 つ前のリリースからの非互換と、engine 自身がそれをどう直したかを
// 1 枚の markdown へ書き出す。
//
//	fge migration-notes                  docs/migrations/<VERSION>.auto.md を書く
//	fge migration-notes --check          書かずに、生成し直しても同じかだけ見る
//	fge migration-notes --from v0.30.0   比べる相手を指定する（既定は 1 つ前のリリース）
//	fge migration-notes --root DIR       リポジトリのルートを差し替える
//
// ゲームを新しい engine へ載せ替えるとき、機械の差分だけでは「何が変わったか」しか
// 言えない。engine は templates/ を自分で追随させているので、その実際の差分を添えれば
// 「どう直すか」まで渡せる。人が書くのはここに追随例が 1 つも無かったときだけ。
//
// WhyNot: リリースの途中で書き出さずに bump で書き出すのは、release の中で作ると未コミットの
// 生成物が同梱の zip にだけ入り、タグの中身には入らないため。後からそのバージョンを
// 取り出しても材料が無い、という形になる。
//
// WhyNot: 追随例を裸の名前で探さないのは、draw や path のような一般語で全部の差分が
// 当たってしまうため。呼び出しの字面（Mod.名前）とフィールドの字面で絞る。

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"

	"github.com/ababup1192/flix_game_engine/go/internal/apidiff"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

const usage = "使い方: fge migration-notes [--check] [--from <タグ>] [--root DIR]"

// followUpDirs は engine 自身の追随を探す場所。
var followUpDirs = []string{"templates", "examples", "bench"}

// engineSrcRe はコミットが engine のソースを触ったかを見る。
var engineSrcRe = regexp.MustCompile(`^(engine|engine_world|engine_tools|render_gl)/src/`)

// maxHunksPerName は 1 つの名前あたりに載せる追随例の数。
//
// WhyNot: 上限を置くのは、当たりすぎた名前が 1 つあるだけで生成物が読めない量に
// 膨らむため。超えた分は「代表 1 件 + コミットの一覧」に落として、隠したことは言う。
const maxHunksPerName = 3

// maxHunkLines は 1 つの塊に載せる行数の上限。
//
// WhyNot: 上限を置くのは、まるごと新しいファイルのような巨大な塊が 1 つ混ざるだけで
// 生成物が読めなくなるため。
const maxHunkLines = 40

// maxTotalDiffLines は 1 枚の markdown 全体に載せる差分の行数の上限。
//
// WhyNot: 名前ごとの上限だけでは足りないのは、非互換が 81 件あると 3 件ずつでも
// 2,670 行になり、読む人がどこから手を付けるか分からなくなるため。
// 超えた分は宣言の前と後だけに落とし、落としたことは本文に書く。
const maxTotalDiffLines = 600

// Run は生成を走らせて終了コードを返す。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	check, from := false, ""
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--check":
			check = true
		case a == "--from":
			if i+1 >= len(args) || strings.HasPrefix(args[i+1], "--") {
				fmt.Fprintf(errOut, "error: --from にはタグを渡してください\n%s\n", usage)
				return 2, nil
			}
			from = args[i+1]
			i++
		case strings.HasPrefix(a, "--from="):
			from = strings.TrimPrefix(a, "--from=")
		default:
			fmt.Fprintf(errOut, "error: 知らない引数です: %s\n%s\n", a, usage)
			return 2, nil
		}
	}

	version, ok := apidiff.MakefileVersion(root)
	if !ok {
		return 2, fmt.Errorf("Makefile に VERSION := がありません")
	}

	notices := []string{}
	if from == "" {
		picked, notice, err := apidiff.PreviousTagOrNone(root)
		if err != nil {
			return 2, err
		}
		from = picked
		if notice != "" {
			notices = append(notices, notice)
		}
	}

	res, err := apidiff.Compute(root, from, "")
	if err != nil {
		return 2, err
	}
	// WhyNot: 告知を本文へ入れないのは、fetch できたときとできないときで本文が変わり、
	// --check が「材料が古い」と誤って落ちるため（オフラインでリリースが止まる）。
	notices = append(notices, res.Notices...)

	body, unexplained, said := build(root, version, res)
	notices = append(notices, said...)
	path := filepath.Join(root, "docs", "migrations", version+".auto.md")

	// WhyNot: 告知を --check より前に出すのは、release-guard が --check だけを呼ぶため。
	// 後ろに置くと、いちばん要る場所（リリースの直前）で fail-open が無音になる。
	for _, n := range notices {
		fmt.Fprintf(out, "[migration-notes] %s\n", n)
	}

	if check {
		old, readErr := os.ReadFile(path)
		if readErr != nil {
			fmt.Fprintf(errOut, "[migration-notes] NG: %s がありません（make bump で作ります）\n",
				relOf(root, path))
			return 1, nil
		}
		if string(old) != body {
			fmt.Fprintf(errOut, "[migration-notes] NG: %s が古いです（make bump で作り直してください）\n",
				relOf(root, path))
			return 1, nil
		}
		fmt.Fprintf(out, "[migration-notes] OK: %s は最新です\n", relOf(root, path))
		return 0, nil
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return 2, err
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		return 2, err
	}
	fmt.Fprintf(out, "[migration-notes] %s を書きました (%s -> %s / 直す物 %d 件)\n",
		relOf(root, path), from, version, len(res.Breaking))
	if unexplained > 0 {
		// WhyNot: ここでリリースを止めないのは、止めると人の手が要るため。
		// ただし黙りもしない —— engine の中で誰も使っていない API を壊したときだけ出る。
		fmt.Fprintf(out, "[migration-notes] 追随例の無い非互換 %d 件（%s を見て、"+
			"必要なら docs/migrations/%s.md に手当てを書いてください）\n",
			unexplained, relOf(root, path), version)
	}
	return 0, nil
}

// build は markdown 本文・追随例が 1 つも見つからなかった非互換の数・告知を返す。
func build(root, version string, res apidiff.Result) (string, int, []string) {
	var b strings.Builder
	fmt.Fprintf(&b, "<!-- 生成物: bin/fge migration-notes が作る。手で編集しない"+
		"（make bump で作り直す。手当てを足すなら docs/migrations/%s.md へ） -->\n\n", version)
	if res.From == "none" {
		fmt.Fprintf(&b, "# engine %s（初リリース）\n\n", version)
	} else {
		fmt.Fprintf(&b, "# engine %s → %s への追随\n\n", strings.TrimPrefix(res.From, "v"), version)
	}

	examples, notices := findFollowUps(root, res)
	unexplained := writeBreaking(&b, res, examples, handRowsOf(root, version))

	if len(res.Added) > 0 {
		fmt.Fprintf(&b, "## 増えた宣言（%d 件・読むだけでよい）\n\n", len(res.Added))
		for _, c := range res.Added {
			fmt.Fprintf(&b, "- `%s`（%s）\n", c.QualifiedName(), c.Package)
		}
		b.WriteString("\n")
	}

	if len(res.Schemas) > 0 {
		b.WriteString("## Doc の schema\n\n")
		for _, s := range res.Schemas {
			fmt.Fprintf(&b, "- %s: `%s`\n", schemaLabel(s.Kind), s.Name)
		}
		b.WriteString("\n")
	}

	if len(res.UndiagnosableDocs) > 0 {
		b.WriteString("## 診られない物\n\n")
		fmt.Fprintf(&b, "schema が無いので、この種の Doc の非互換はこの一覧に出ません: %s\n\n",
			strings.Join(res.UndiagnosableDocs, ", "))
	}
	b.WriteString("render_gl は見ていません（ゲームが直接呼ばない層）。\n")
	return b.String(), unexplained, notices
}

// writeBreaking は「直す物」の節を書いて、追随例が 1 つも無かった非互換の数を返す。
func writeBreaking(b *strings.Builder, res apidiff.Result, examples map[string][]string, hand []handRow) int {
	switch {
	case res.From == "none":
		b.WriteString("## 直す物\n\n初リリースなので、比べる相手がありません。\n\n")
		return 0
	case len(res.Breaking) == 0:
		b.WriteString("## 直す物\n\nありません。\n\n")
		return 0
	}
	trimmed := trimToBudget(res.Breaking, examples)
	fmt.Fprintf(b, "## 直す物（%d 件）\n\n", len(res.Breaking))
	if n := len(trimmed); n > 0 {
		fmt.Fprintf(b, "うち %d 件は追随例を省いて、宣言の前と後だけ載せています"+
			"（全体の差分が %d 行を超えるため）。\n\n", n, maxTotalDiffLines)
	}
	unexplained := 0
	for i, c := range res.Breaking {
		fmt.Fprintf(b, "### %d. %s（%s）\n\n", i+1, c.QualifiedName(), c.Package)
		writeChange(b, c)
		rows := handRowsFor(hand, c.QualifiedName())
		writeHandRows(b, rows)
		hunks := examples[c.QualifiedName()]
		switch {
		case len(hunks) == 0 && len(rows) > 0:
			// 手書きの表が手当てを言っているので、「自分で考えて」とは言わない。
		case len(hunks) == 0:
			unexplained++
			b.WriteString("engine の中に追随例がありません。手当ては自分で考えてください。\n\n")
		case trimmed[i]:
			b.WriteString("追随例は省きました（全体の量の上限）。" +
				"実物は git log で探してください。\n\n")
		default:
			b.WriteString("engine 自身はこう直しました:\n\n")
			for _, h := range hunks {
				fmt.Fprintf(b, "```diff\n%s\n```\n\n", h)
			}
		}
	}
	return unexplained
}

// trimToBudget は、差分の行数が全体の上限を超える非互換の番号を返す（真なら追随例を省く）。
//
// WhyNot: 先頭から順に配るのは、途中を飛ばして詰めると同じ材料でも並びで結果が変わり、
// --check が生成し直すたびに落ちるため。
func trimToBudget(breaking []apidiff.Change, examples map[string][]string) map[int]bool {
	trimmed := map[int]bool{}
	used := 0
	for i, c := range breaking {
		hunks := examples[c.QualifiedName()]
		if len(hunks) == 0 {
			continue
		}
		n := 0
		for _, h := range hunks {
			n += countLines(h)
		}
		// 1 件目だけは上限より大きくても載せる（1 つも例が無い markdown にしないため）。
		if used > 0 && used+n > maxTotalDiffLines {
			trimmed[i] = true
			continue
		}
		used += n
	}
	return trimmed
}

func writeChange(b *strings.Builder, c apidiff.Change) {
	switch c.Kind {
	case "removed":
		fmt.Fprintf(b, "消えました。\n\n- 前: `%s`\n\n", c.Before)
	case "added":
		fmt.Fprintf(b, "eff に op が増えました（handler は全 op を書かないと通りません）。\n\n"+
			"- 後: `%s`\n\n", c.After)
	default:
		if len(c.MembersRemoved) > 0 {
			fmt.Fprintf(b, "- 消えた中身: %s\n", strings.Join(c.MembersRemoved, ", "))
		}
		if len(c.MembersAdded) > 0 {
			fmt.Fprintf(b, "- 増えた中身: %s\n", strings.Join(c.MembersAdded, ", "))
		}
		fmt.Fprintf(b, "\n- 前: `%s`\n- 後: `%s`\n\n", c.Before, c.After)
	}
}

func schemaLabel(kind string) string {
	switch kind {
	case "removed":
		return "消えました"
	case "added":
		return "増えました"
	default:
		return "変わりました"
	}
}

// findFollowUps は非互換ごとの追随の差分（鍵は Mod.名前）と、告知を返す。
func findFollowUps(root string, res apidiff.Result) (map[string][]string, []string) {
	out := map[string][]string{}
	if len(res.Breaking) == 0 {
		return out, nil
	}
	commits, err := commitsBetween(root, res.From)
	if err != nil {
		// WhyNot: 「追随例がありません」と言い切らないのは、探せなかっただけだから。
		// 断定すると、読む人が本当は在る例を探しに行かなくなる。
		return out, []string{"fail-open: git log を呼べません。追随例は探せていません"}
	}
	// WhyNot: 差分を先に 1 度だけ取るのは、非互換ごとに取り直すと呼び出しが
	// 「非互換の数 × コミットの数」に膨らむため（実測でバージョン 10 個ぶんが 84 秒）。
	hunksOf := make([][]string, len(commits))
	for i, cm := range commits {
		hunksOf[i] = splitHunks(followUpDiff(root, cm.id))
	}
	for _, c := range res.Breaking {
		hunks, dropped := hunksFor(commits, hunksOf, c)
		if dropped > 0 {
			hunks = append(hunks, fmt.Sprintf("# ほか %d 件は載せていません（多すぎるため）", dropped))
		}
		if len(hunks) > 0 {
			out[c.QualifiedName()] = hunks
		}
	}
	return out, nil
}

// commit は 1 コミットの ID と、engine のソースを触ったかどうか。
type commit struct {
	id            string
	touchedEngine bool
}

// commitsBetween は from から HEAD までのコミットを新しい順に返す。
func commitsBetween(root, from string) ([]commit, error) {
	stdout, err := exec.Command("git", "-C", root, "log", "--format=%H", "--name-only",
		from+"..HEAD").Output()
	if err != nil {
		return nil, err
	}
	var out []commit
	cur := commit{}
	flush := func() {
		if cur.id != "" {
			out = append(out, cur)
		}
	}
	for _, line := range pxlib.SplitLines(string(stdout)) {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if isCommitID(line) {
			flush()
			cur = commit{id: line}
			continue
		}
		if engineSrcRe.MatchString(line) {
			cur.touchedEngine = true
		}
	}
	flush()
	return out, nil
}

func isCommitID(s string) bool {
	if len(s) != 40 {
		return false
	}
	for _, r := range s {
		if !strings.ContainsRune("0123456789abcdef", r) {
			return false
		}
	}
	return true
}

// hunksFor は 1 つの非互換に当たる追随の差分と、上限で落とした数を返す。
func hunksFor(commits []commit, hunksOf [][]string, c apidiff.Change) ([]string, int) {
	seen := map[string]bool{}
	var found []string
	for i, cm := range commits {
		for _, h := range hunksOf[i] {
			if !hunkMentions(h, c, cm.touchedEngine) || seen[h] {
				continue
			}
			seen[h] = true
			found = append(found, h)
		}
	}
	sortByTeachingPower(found, c)
	if len(found) > maxHunksPerName {
		return found[:maxHunksPerName], len(found) - maxHunksPerName
	}
	return found, 0
}

// sortByTeachingPower は追随例を「直し方がその場で読める順」に並べ替える。
//
// WhyNot: パス名の辞書順で採らないのは、その並びが教える力と何の関係も無いため。
// 呼び出しの直し方が見える例が落ちて、名前がかすっただけの例が残る。
//
// WhyNot: 最後にパス名で決めるのは、同じ点の並びが呼ぶたびに変わると
// --check が生成し直すたびに落ちるため。
func sortByTeachingPower(hunks []string, c apidiff.Change) {
	sort.SliceStable(hunks, func(i, j int) bool {
		si, sj := teachingScore(hunks[i], c), teachingScore(hunks[j], c)
		if si != sj {
			return si > sj
		}
		ci, cj := changedLines(hunks[i]), changedLines(hunks[j])
		if ci != cj {
			return ci < cj
		}
		return hunks[i] < hunks[j]
	})
}

// teachingScore は追随例の代表らしさ。名前が消えた行と足した行の両方に出れば 2、
// 置き換えが見えれば 1、それ以外は 0。
func teachingScore(hunk string, c apidiff.Change) int {
	name := c.QualifiedName()
	removed, added, nameRemoved, nameAdded := false, false, false, false
	for _, line := range bodyLines(hunk) {
		switch {
		case strings.HasPrefix(line, "-"):
			removed = true
			nameRemoved = nameRemoved || containsIdent(line, name)
		case strings.HasPrefix(line, "+"):
			added = true
			nameAdded = nameAdded || containsIdent(line, name)
		}
	}
	switch {
	case nameRemoved && nameAdded:
		return 2
	case removed && added:
		return 1
	default:
		return 0
	}
}

// changedLines は差分の塊のうち、消えた行と足した行の数。
func changedLines(hunk string) int {
	n := 0
	for _, line := range bodyLines(hunk) {
		if strings.HasPrefix(line, "-") || strings.HasPrefix(line, "+") {
			n++
		}
	}
	return n
}

// followUpDiff は 1 コミットの、追随を探す場所の差分だけを返す。
func followUpDiff(root, id string) string {
	args := []string{"-C", root, "show", "--format=", "--unified=3", id, "--"}
	args = append(args, followUpDirs...)
	stdout, err := exec.Command("git", args...).Output()
	if err != nil {
		return ""
	}
	return string(stdout)
}

// splitHunks は差分を @@ ごとの塊へ割る（どのファイルかの行を頭に残す）。
//
// WhyNot: ファイル名を `+++ b/` から取らないのは、消えたファイルだと `+++ /dev/null` に
// なって名前が更新されず、1 つ前のファイル名がそのまま貼られるため。
// 存在しないファイルを指す指示書になる。
func splitHunks(diff string) []string {
	var out []string
	var cur []string
	file := ""
	flush := func() {
		if len(cur) > 0 {
			out = append(out, strings.Join(cur, "\n"))
			cur = nil
		}
	}
	for _, line := range pxlib.SplitLines(diff) {
		switch {
		case strings.HasPrefix(line, "diff --git "):
			flush()
			file = fileOfDiffHeader(line)
		case strings.HasPrefix(line, "@@"):
			flush()
			if file == "" {
				continue
			}
			cur = append(cur, "# "+file, line)
		case len(cur) > 0 && strings.HasPrefix(line, "\\"):
			// WhyNot: `\ No newline at end of file` で塊を切らないのは、
			// そこで切ると直した後の行（+ 側）が丸ごと落ちるため。
			continue
		case len(cur) > 0 && (strings.HasPrefix(line, "+") || strings.HasPrefix(line, "-") ||
			strings.HasPrefix(line, " ")):
			cur = append(cur, line)
		case len(cur) > 0:
			flush()
		}
	}
	flush()
	return out
}

// fileOfDiffHeader は `diff --git a/X b/Y` から Y を取る。取れなければ空。
func fileOfDiffHeader(line string) string {
	rest := strings.TrimPrefix(line, "diff --git ")
	i := strings.Index(rest, " b/")
	if i < 0 {
		return ""
	}
	return rest[i+len(" b/"):]
}

// hunkMentions は差分の塊がこの非互換の追随か。
//
// WhyNot: 裸の名前で当てないのは、draw や path のような一般語で全部の塊が当たるため。
// しかも部分一致だと Sprite が withSpriteAtlases にも当たる。識別子の切れ目で見る。
//
// WhyNot: 削除行のある塊しか採らないのは、追随とは「今ある書き方を直す」ことだから。
// 足しただけの塊（新しいファイル・新しい関数）は、壊れた API の直し方を教えない。
func hunkMentions(hunk string, c apidiff.Change, sameCommitTouchedEngine bool) bool {
	if !hasRemovedLine(hunk) || countLines(hunk) > maxHunkLines {
		return false
	}
	if containsIdent(hunk, c.QualifiedName()) {
		return true
	}
	for _, m := range append(append([]string{}, c.MembersRemoved...), c.MembersAdded...) {
		// 型の名前が同じ塊に居るときだけ採る（`loop =` は他の物にも出る）。
		if strings.Contains(hunk, m+" =") && mentionsOwnType(hunk, c) {
			return true
		}
		// WhyNot: JSON では型の名前を求めないのは、Doc の実物に Flix の型名が
		// 1 つも書かれていないため（求めるとこの枝は永久に当たらない飾りになる）。
		// 代わりに、消えた行にそのフィールドが出ることを求めて雑音を落とす。
		if isJSONHunk(hunk) && removedLineHasText(hunk, `"`+m+`"`) {
			return true
		}
	}
	// WhyNot: 名前が 1 つも出ない追随を engine 側と同じコミットかどうかで拾うのは、
	// View を組み直すような書き替えが旧 API の字を 1 つも残さないため。
	// このリポは非互換とその追随を同じコミットに入れる習慣がある。
	return sameCommitTouchedEngine && mentionsOwnType(hunk, c) && removedLineHas(hunk, c)
}

// mentionsOwnType は塊に出てくる名前が、本当にこの mod の物か。
//
// WhyNot: 名前だけで見ないのは、Sprite のような一般名が別の mod にも居るため。
// 実測で PxSpriteDoc.Sprite の追随例に Render.Item.Sprite の差分が 2 件混ざり、
// 読む人を「flipX を消せ」と誤らせる形になっていた。
func mentionsOwnType(hunk string, c apidiff.Change) bool {
	if containsIdent(hunk, c.Mod+"."+c.Name) {
		return true
	}
	// 修飾なしで出るのは、その mod の中を直しているときだけ。
	for _, line := range bodyLines(hunk) {
		i := 0
		for {
			j := strings.Index(line[i:], c.Name)
			if j < 0 {
				break
			}
			at := i + j
			before := byte(' ')
			if at > 0 {
				before = line[at-1]
			}
			if before != '.' && !isIdentByte(before) {
				after := byte(' ')
				if end := at + len(c.Name); end < len(line) {
					after = line[end]
				}
				if !isIdentByte(after) {
					return true
				}
			}
			i = at + len(c.Name)
		}
	}
	return false
}

// removedLineHas は消えた行の側に名前が出るか（足しただけの言及を追随と読まない）。
func removedLineHas(hunk string, c apidiff.Change) bool {
	for _, line := range bodyLines(hunk) {
		if strings.HasPrefix(line, "-") && containsIdent(line, c.Name) {
			return true
		}
	}
	return false
}

// removedLineHasText は消えた行の側にその字面が出るか。
func removedLineHasText(hunk, text string) bool {
	for _, line := range bodyLines(hunk) {
		if strings.HasPrefix(line, "-") && strings.Contains(line, text) {
			return true
		}
	}
	return false
}

// bodyLines は差分の中身の行だけを返す。
//
// WhyNot: 見出し（`# <パス>`）を外すのは、こちらが自分で足した行だから。
// 含めると Sprite.flix のようなファイル名だけで「この型を直している」と読んでしまう。
func bodyLines(hunk string) []string {
	var out []string
	for _, line := range pxlib.SplitLines(hunk) {
		if strings.HasPrefix(line, "# ") {
			continue
		}
		out = append(out, line)
	}
	return out
}

// isJSONHunk は差分の塊が JSON のファイルの物か（見出しの字で見る）。
func isJSONHunk(hunk string) bool {
	for _, line := range pxlib.SplitLines(hunk) {
		if strings.HasPrefix(line, "# ") {
			return strings.HasSuffix(strings.TrimSpace(line), ".json")
		}
	}
	return false
}

// hasRemovedLine は差分の塊に消えた行があるか。
func hasRemovedLine(hunk string) bool {
	for _, line := range pxlib.SplitLines(hunk) {
		if strings.HasPrefix(line, "-") && !strings.HasPrefix(line, "---") {
			return true
		}
	}
	return false
}

func countLines(s string) int { return len(pxlib.SplitLines(s)) }

// containsIdent は識別子の切れ目で name が出てくるか（Sprite が SpriteAtlas に当たらない）。
func containsIdent(text, name string) bool {
	for i := 0; i+len(name) <= len(text); i++ {
		if text[i:i+len(name)] != name {
			continue
		}
		if i > 0 && isIdentByte(text[i-1]) {
			continue
		}
		if j := i + len(name); j < len(text) && isIdentByte(text[j]) {
			continue
		}
		return true
	}
	return false
}

func isIdentByte(b byte) bool {
	return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

func relOf(root, path string) string {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return path
	}
	return filepath.ToSlash(rel)
}

// ── 手書きの置き換え表 ───────────────────────────────────

// handRow は手書きの手当て（docs/migrations/<版>.md）の表の 1 行。
type handRow struct {
	names   []string // 左の列の `…` に書かれた名前（引数は除く）
	before  string   // 左の列そのまま
	after   string   // 右の列（「同上」は前の行の右の列に置き換え済み）
	file    string   // <版>.md
	section string   // 表のある節の見出し
}

// handCodeName は `Render.zShifted(d, 物)` の頭の名前（Render.zShifted）を取る。
var handCodeName = regexp.MustCompile("`([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z_][A-Za-z0-9_]*)*)")

// handRowsOf は docs/migrations/<version>.md の表の行を読む。無ければ空（手書きの手当ては任意）。
//
// WhyNot: 表の形（左の列 = 止まった名前・右の列 = 置き換え）だけを頼りに、節の名前で
// 絞らないのは、版ごとに見出しの言い回しが揺れても拾えるようにするため。左の列に
// `Mod.名前` の無い表（説明の表）は、どの非互換にも当たらないので混ざっても害が無い。
func handRowsOf(root, version string) []handRow {
	file := version + ".md"
	data, err := os.ReadFile(filepath.Join(root, "docs", "migrations", file))
	if err != nil {
		return nil
	}
	var rows []handRow
	section, prevAfter := "", ""
	for _, line := range pxlib.SplitLines(string(data)) {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "## ") {
			section, prevAfter = strings.TrimSpace(strings.TrimPrefix(line, "## ")), ""
			continue
		}
		cells := tableCells(line)
		if len(cells) < 2 || strings.Trim(cells[0], "-: ") == "" {
			continue // 表でない行と、見出しの下の |---|
		}
		after := cells[1]
		// WhyNot: 「同上」を前の行の右の列に置き換えるのは、1 行だけ抜き出すと
		// 何と同じなのかが読めなくなるため。
		if rest, ok := strings.CutPrefix(after, "同上"); ok && prevAfter != "" {
			after = prevAfter + rest
		} else {
			prevAfter = after
		}
		var names []string
		for _, m := range handCodeName.FindAllStringSubmatch(cells[0], -1) {
			names = append(names, m[1])
		}
		if len(names) == 0 {
			continue // 見出しの行（止まった名前 | 置き換え）
		}
		rows = append(rows, handRow{names: names, before: cells[0], after: after, file: file, section: section})
	}
	return rows
}

// tableCells は markdown の表の行（| a | b |）を列に切る。表でなければ nil。
// `\|`（列の中の縦棒）は切らずに `|` へ戻す。
func tableCells(line string) []string {
	if !strings.HasPrefix(line, "|") || !strings.HasSuffix(line, "|") || len(line) < 2 {
		return nil
	}
	var cells []string
	var cur strings.Builder
	body := line[1 : len(line)-1]
	for i := 0; i < len(body); i++ {
		switch {
		case body[i] == '\\' && i+1 < len(body) && body[i+1] == '|':
			cur.WriteByte('|')
			i++
		case body[i] == '|':
			cells = append(cells, strings.TrimSpace(cur.String()))
			cur.Reset()
		default:
			cur.WriteByte(body[i])
		}
	}
	return append(cells, strings.TrimSpace(cur.String()))
}

// handRowsFor は名前 name を左の列に書いた行を返す。
func handRowsFor(rows []handRow, name string) []handRow {
	var out []handRow
	for _, r := range rows {
		for _, n := range r.names {
			if n == name {
				out = append(out, r)
				break
			}
		}
	}
	return out
}

// writeHandRows は手書きの表の行を、その節へのリンクを添えて書く。
func writeHandRows(b *strings.Builder, rows []handRow) {
	if len(rows) == 0 {
		return
	}
	r := rows[0]
	where := r.file
	if r.section != "" {
		where = fmt.Sprintf("%s「%s」", r.file, r.section)
	}
	fmt.Fprintf(b, "手書きの置き換え（[%s](%s#%s)）:\n\n", where, r.file, headingAnchor(r.section))
	for _, r := range rows {
		fmt.Fprintf(b, "- %s → %s\n", r.before, r.after)
	}
	b.WriteString("\n")
}

// headingAnchor は見出しのリンク先（GitHub と同じ作り方: 小文字にし、記号を消し、空白を - に）。
func headingAnchor(heading string) string {
	var a strings.Builder
	for _, r := range strings.ToLower(heading) {
		switch {
		case r == ' ':
			a.WriteRune('-')
		case r == '-' || r == '_' || unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.Is(unicode.Mn, r):
			a.WriteRune(r)
		}
	}
	return a.String()
}
