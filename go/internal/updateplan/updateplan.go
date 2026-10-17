package updateplan

// updateplan — 1 本のゲームを新しい engine へ載せ替えるための指示書を書く。
//
//	fge update-plan --game DIR              ゲームの今のバージョンから engine の今へ
//	fge update-plan --game DIR --to 0.32.0  上げ先を指定する
//	fge update-plan --game DIR --out FILE    書き出す先（既定は標準出力）
//	fge update-plan --game DIR --root DIR    engine のリポを差し替える
//
// 壊れた API の一覧そのものは fge api-diff が出す。ここがやるのは
// **そのゲームで実際に当たる物だけに絞る**こと。全部貼ると読めない量になる。
//
// WhyNot: 自分で直しにいかないのは、当たり所を読み違えたときに何も知らせずに壊すため。
// 直すのはこれを読むエージェントの仕事にして、こちらは材料を渡すことに徹する。
//
// WhyNot: 追随例を git から取り直さないのは、ゲームの手元にも Studio が同梱しているソースにも
// .git が無いため。リリースのときに生成した docs/migrations/*.auto.md から持ってくる。

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/apidiff"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

const usage = "使い方: fge update-plan --game /path/to/game [--to <バージョン>] [--out FILE] [--root DIR]"

// depRe はゲームの flix.toml が指す engine のバージョン。
var depRe = regexp.MustCompile(
	`"github:ababup1192/flix_game_engine"\s*=\s*\{[^}]*version\s*=\s*"([^"]+)"`)

// sectionRe は生成した材料の見出し（### 1. Mod.名前（パッケージ））。
var sectionRe = regexp.MustCompile(`^### \d+\. (\S+?)（`)

// scanSuffixes はゲームの中で当たり所を探すファイル。
var scanSuffixes = []string{".flix", ".json"}

// skipDirs は探さない場所（生成物と取り込んだ物）。
var skipDirs = map[string]bool{
	"lib": true, "build": true, "gallery": true, "reference": true, ".git": true,
	// WhyNot: bin と .claude と agents-pack を外すのは、そこが engine から配られた
	// 道具と規約データで、ゲームが直す物ではないため（直せと言われても直せない）。
	"bin": true, ".claude": true, ".agents": true, "agents-pack": true,
}

// Hit は当たり所 1 つ。
type Hit struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Text string `json:"text"`
}

// Item は直す物 1 つ。
type Item struct {
	Name    string         `json:"name"`
	Package string         `json:"package"`
	Change  apidiff.Change `json:"-"`
	Hits    []Hit          `json:"hits"`
	Example string         `json:"example,omitempty"`
}

// Run は指示書を書き出して終了コードを返す。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	game, to, outPath := "", "", ""
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--game" || a == "--to" || a == "--out":
			if i+1 >= len(args) || strings.HasPrefix(args[i+1], "--") {
				fmt.Fprintf(errOut, "error: %s には値を渡してください\n%s\n", a, usage)
				return 2, nil
			}
			switch a {
			case "--game":
				game = args[i+1]
			case "--to":
				to = args[i+1]
			default:
				outPath = args[i+1]
			}
			i++
		case strings.HasPrefix(a, "--game="):
			game = strings.TrimPrefix(a, "--game=")
		case strings.HasPrefix(a, "--to="):
			to = strings.TrimPrefix(a, "--to=")
		case strings.HasPrefix(a, "--out="):
			outPath = strings.TrimPrefix(a, "--out=")
		default:
			fmt.Fprintf(errOut, "error: 知らない引数です: %s\n%s\n", a, usage)
			return 2, nil
		}
	}
	if game == "" {
		fmt.Fprintf(errOut, "error: --game を指定してください\n%s\n", usage)
		return 2, nil
	}
	if info, err := os.Stat(game); err != nil || !info.IsDir() {
		return 2, fmt.Errorf("ゲームのフォルダが見つかりません: %s", game)
	}

	plan, err := Build(root, game, to)
	if err != nil {
		return 2, err
	}

	if outPath != "" {
		if err := os.WriteFile(outPath, []byte(plan.Body), 0o644); err != nil {
			return 2, err
		}
		fmt.Fprintf(out, "[update-plan] %s を書きました（直す物 %d 件）\n", outPath, plan.Count)
		return 0, nil
	}
	out.WriteString(plan.Body)
	return 0, nil
}

// Plan は 1 本のゲーム向けの指示書と、そこに載った直す物の数。
type Plan struct {
	From  string
	To    string
	Count int
	Body  string
}

// Build は指示書を組む。upgrade-game が巻き戻すかどうかを Count で決める。
func Build(root, game, to string) (Plan, error) {
	from, err := gameEngineVersion(game)
	if err != nil {
		return Plan{}, err
	}
	res, err := apidiff.Compute(root, "v"+from, versionTag(to))
	if err != nil {
		// WhyNot: ここで諦めないのは、Studio が同梱している engine には .git が無く、
		// pub 面を古いタグから取り出せないため。そこで諦めると Studio から呼んだときは
		// 常に「数えられません」になり、当たる非互換の数で赤の意味を分ける仕組みが
		// まるごと働かない。同梱している材料には名前が載っているので、そちらで数える。
		return buildFromMaterials(root, game, from, to, err)
	}
	items, missed := narrow(game, res)
	// 生成した材料から、名前ごとの追随例を貼る（新しいバージョンの物が勝つ）。
	examples, notice := FollowUpExamples(root, from, to)
	for i := range items {
		items[i].Example = examples[items[i].Name]
	}
	return Plan{
		From:  from,
		To:    strings.TrimPrefix(res.To, "v"),
		Count: len(items),
		Body:  build(from, res, items, missed, notice),
	}, nil
}

// buildFromMaterials は pub 面を突き合わせられないときに、同梱している
// docs/migrations の材料だけで指示書を組む。
//
// WhyNot: 名前でしか当てないのは、材料に載っているのが「どの名前が変わったか」と
// engine 自身の追随例だけで、レコードの中身の増減までは書かれていないため。
// JSON の Doc は名前が出てこないので、この経路では当たらない（その旨を本文に書く）。
func buildFromMaterials(root, game, from, to string, cause error) (Plan, error) {
	examples, notice := FollowUpExamples(root, from, to)
	if notice != "" {
		return Plan{}, fmt.Errorf("%v（材料も見つかりません）", cause)
	}
	names := make([]string, 0, len(examples))
	for name := range examples {
		names = append(names, name)
	}
	sort.Strings(names)

	files := scanFiles(game)
	var items []Item
	missed := 0
	for _, name := range names {
		hits := hitsForName(game, files, name)
		if len(hits) == 0 {
			missed++
			continue
		}
		items = append(items, Item{Name: name, Hits: hits, Example: examples[name]})
	}
	to = strings.TrimPrefix(to, "v")
	if to == "" {
		to = "新しいバージョン"
	}
	return Plan{
		From: from, To: to, Count: len(items),
		Body: buildFromNames(from, to, items, missed),
	}, nil
}

// hitsForName は名前だけで当たり所を探す。
func hitsForName(game string, files []string, name string) []Hit {
	var hits []Hit
	for _, path := range files {
		text, err := pxlib.LoadTextReplace(path)
		if err != nil {
			continue
		}
		for i, line := range pxlib.SplitLines(text) {
			if strings.HasPrefix(strings.TrimSpace(line), "//") {
				continue
			}
			if !containsIdent(line, name) {
				continue
			}
			rel, relErr := filepath.Rel(game, path)
			if relErr != nil {
				rel = path
			}
			hits = append(hits, Hit{
				File: filepath.ToSlash(rel), Line: i + 1, Text: strings.TrimSpace(line),
			})
		}
	}
	return hits
}

// buildFromNames は材料だけで組んだときの本文。
func buildFromNames(from, to string, items []Item, missed int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# engine %s → %s への追随\n\n", from, to)
	b.WriteString("> 宣言そのものを突き合わせられなかったので（engine のソースに .git がありません）、" +
		"リリースのときに生成した材料の名前だけで探しています。" +
		"JSON の Doc の中身の変更は、この出し方では出ません。\n\n")
	if len(items) == 0 {
		b.WriteString("## 直す物\n\nこのゲームで当たる名前はありません。\n\n")
	} else {
		fmt.Fprintf(&b, "## 直す物（このゲームで当たる %d 件）\n\n", len(items))
		for i, it := range items {
			fmt.Fprintf(&b, "### %d. %s\n\n", i+1, it.Name)
			writeHits(&b, it.Hits)
			if it.Example != "" {
				fmt.Fprintf(&b, "engine 自身はこう直しました:\n\n%s\n\n", it.Example)
			}
		}
	}
	if missed > 0 {
		fmt.Fprintf(&b, "engine 側の非互換は他に %d 件ありますが、"+
			"このゲームでは使っていないので直す必要はありません。\n\n", missed)
	}
	b.WriteString("## 確かめ方\n\n```\nmake check\nmake test\nmake reference-check\n```\n")
	return b.String()
}

// versionTag は --to をタグの形にする（空なら作業ツリーのまま）。
func versionTag(to string) string {
	if to == "" {
		return ""
	}
	if strings.HasPrefix(to, "v") {
		return to
	}
	return "v" + to
}

// gameEngineVersion はゲームの flix.toml が指す engine のバージョン。
func gameEngineVersion(game string) (string, error) {
	text, err := pxlib.LoadTextReplace(filepath.Join(game, "flix.toml"))
	if err != nil {
		return "", fmt.Errorf("%s/flix.toml を読めません", game)
	}
	m := depRe.FindStringSubmatch(text)
	if m == nil {
		return "", fmt.Errorf("%s/flix.toml に flix_game_engine の依存行がありません", game)
	}
	return m[1], nil
}

// narrow は壊れた API のうち、このゲームで実際に当たる物だけを返す。
// 2 つ目の戻り値は、当たらなかった非互換の数。
func narrow(game string, res apidiff.Result) ([]Item, int) {
	files := scanFiles(game)
	var items []Item
	missed := 0
	for _, c := range res.Breaking {
		hits := hitsFor(game, files, c)
		// WhyNot: eff の op が増えたのを当たり所ゼロで落とさないのは、handler が
		// `def opName` と修飾なしで書かれ、機械では当たり所を出せないため。
		// 確実にコンパイルが落ちる変更なのに「使っていません」に埋もれる。
		if len(hits) == 0 && c.Kind != "added" {
			missed++
			continue
		}
		items = append(items, Item{
			Name: c.QualifiedName(), Package: c.Package, Change: c, Hits: hits,
		})
	}
	return items, missed
}

// scanFiles はゲームの中の探す対象のファイル（リポからの相対パス）。
func scanFiles(game string) []string {
	var out []string
	_ = filepath.Walk(game, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			if skipDirs[info.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		for _, s := range scanSuffixes {
			if strings.HasSuffix(info.Name(), s) {
				out = append(out, path)
				return nil
			}
		}
		return nil
	})
	sort.Strings(out)
	return out
}

// maxHitsPerItem は 1 件あたりに載せる当たり所の数。
//
// WhyNot: 上限を置くのは、よく使う API だと当たり所が何十個も出て、
// 直す物の一覧が当たり所の一覧に埋もれるため。数は全部言う。
const maxHitsPerItem = 12

// hitsFor は 1 つの非互換の当たり所を返す。
func hitsFor(game string, files []string, c apidiff.Change) []Hit {
	var hits []Hit
	for _, path := range files {
		text, err := pxlib.LoadTextReplace(path)
		if err != nil {
			continue
		}
		isJSON := isDocFile(path, c)
		for i, line := range pxlib.SplitLines(text) {
			if !lineMentions(line, c, isJSON) {
				continue
			}
			rel, relErr := filepath.Rel(game, path)
			if relErr != nil {
				rel = path
			}
			hits = append(hits, Hit{
				File: filepath.ToSlash(rel), Line: i + 1, Text: strings.TrimSpace(line),
			})
		}
	}
	return hits
}

// lineMentions は 1 行がこの非互換に当たるか。
//
// WhyNot: 裸の名前で当てないのは、draw や path のような一般語で全部の行が当たるため。
// Flix は呼び出しを修飾して書くので `Mod.名前` の識別子の切れ目で見る。
func lineMentions(line string, c apidiff.Change, isJSON bool) bool {
	// WhyNot: コメント行を外すのは、当たり所を読むエージェントがそこを直しにいくため。
	// 説明や注記を「壊れた呼び出し」と読んで書き替えてしまう。
	if t := strings.TrimSpace(line); strings.HasPrefix(t, "//") {
		return false
	}
	if containsIdent(line, c.QualifiedName()) {
		return true
	}
	if !isJSON {
		return false
	}
	// WhyNot: JSON だけフィールド名で見るのは、Doc の実物に Flix の型名が
	// 1 つも書かれていないため。型名を求めるとゲームの sprite.json は永久に当たらない。
	// WhyNot: `"名前"` でなく `"名前":` で見るのは、値の側に同じ字が並ぶだけの行まで
	// 当たるため（配った規約データの `"rules": [... "loop" ...]` が実際に当たっていた）。
	for _, m := range c.MembersRemoved {
		if strings.Contains(line, `"`+m+`":`) {
			return true
		}
	}
	return false
}

// isDocFile はその非互換の Doc を書くファイルか（PxSpriteDoc なら *.sprite.json）。
//
// WhyNot: どの JSON にもフィールド名で当てないのは、ゲームが自分で作った無関係な JSON の
// `"loop": true` 1 行で「直す物」が丸ごと 1 件でっち上がるため（実測でそうなった）。
func isDocFile(path string, c apidiff.Change) bool {
	if !strings.HasSuffix(path, ".json") || !strings.HasSuffix(c.Mod, "Doc") {
		return false
	}
	// WhyNot: mod の名前から種を作らずファイル名から取るのは、PxSpriteDoc が
	// sprite.json を読むように、mod の名前に前置きが付くため（接尾辞を削るだけでは出ない）。
	parts := strings.Split(strings.ToLower(filepath.Base(path)), ".")
	if len(parts) < 3 {
		return false
	}
	kind := parts[len(parts)-2]
	return strings.Contains(strings.ToLower(c.Mod), kind)
}

// containsIdent は識別子の切れ目で name が出てくるか。
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

// clip は長い行を切り詰める（切ったら … を付ける）。
func clip(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n]) + "…"
}

func isIdentByte(b byte) bool {
	return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

// build は指示書の本文を組む。
func build(from string, res apidiff.Result, items []Item, missed int, notice string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# engine %s → %s への追随\n\n", from, strings.TrimPrefix(res.To, "v"))
	if notice != "" {
		fmt.Fprintf(&b, "> %s\n\n", notice)
	}

	if len(items) == 0 {
		b.WriteString("## 直す物\n\nこのゲームで当たる非互換はありません。\n\n")
	} else {
		fmt.Fprintf(&b, "## 直す物（このゲームで当たる %d 件）\n\n", len(items))
		for i, it := range items {
			fmt.Fprintf(&b, "### %d. %s（%s）\n\n", i+1, it.Name, it.Package)
			writeChange(&b, it.Change)
			writeHits(&b, it.Hits)
			if it.Example != "" {
				fmt.Fprintf(&b, "engine 自身はこう直しました:\n\n%s\n", it.Example)
			}
		}
	}

	// WhyNot: 当たらなかった数まで書くのは、「差分は 20 件あったのに 2 件しか
	// 書いていない」を読む側が読み違えないため（隠したのでなく当たらなかった）。
	if missed > 0 {
		fmt.Fprintf(&b, "engine 側の非互換は他に %d 件ありますが、"+
			"このゲームでは使っていないので直す必要はありません。\n\n", missed)
	}

	if len(res.Added) > 0 {
		fmt.Fprintf(&b, "## 増えた宣言（%d 件・読むだけでよい）\n\n", len(res.Added))
		for _, c := range res.Added {
			fmt.Fprintf(&b, "- `%s`（%s）\n", c.QualifiedName(), c.Package)
		}
		b.WriteString("\n")
	}

	if len(res.UndiagnosableDocs) > 0 {
		b.WriteString("## 診られない物\n\n")
		fmt.Fprintf(&b, "schema が無いので、この種の Doc の非互換は上に出ません: %s\n\n",
			strings.Join(res.UndiagnosableDocs, ", "))
	}

	b.WriteString("## 確かめ方\n\n")
	b.WriteString("```\nmake check\nmake test\nmake reference-check\n```\n\n")
	b.WriteString("`reference-check` の差は絵が変わった印です。" +
		"変わってよい差かは人が見て決めます（自動で基準の絵を作り直さないこと）。\n")
	return b.String()
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

func writeHits(b *strings.Builder, hits []Hit) {
	if len(hits) == 0 {
		b.WriteString("当たる場所は機械では出せません" +
			"（handler は修飾なしで書くため）。自分の handler を見てください。\n\n")
		return
	}
	fmt.Fprintf(b, "当たる場所（%d か所・候補です）:\n\n", len(hits))
	shown := hits
	if len(shown) > maxHitsPerItem {
		shown = shown[:maxHitsPerItem]
	}
	for _, h := range shown {
		fmt.Fprintf(b, "- `%s:%d` — `%s`\n", h.File, h.Line, clip(h.Text, 100))
	}
	if len(hits) > len(shown) {
		fmt.Fprintf(b, "- ほか %d か所（同じ直し方です）\n", len(hits)-len(shown))
	}
	b.WriteString("\n")
}

// FollowUpExamples は生成した材料から、名前ごとの追随例を読む。
//
// WhyNot: 新しいバージョンの物を勝てるようにするのは、改名が連鎖したときに
// 途中で死んだ書き方へ直させないため（A→B で clips、B→C で animations なら C を渡す）。
func FollowUpExamples(root, from, to string) (map[string]string, string) {
	out := map[string]string{}
	dir := filepath.Join(root, "docs", "migrations")
	entries, err := os.ReadDir(dir)
	if err != nil {
		// WhyNot: 空を返して済ませないのは、「例が無いバージョンだった」のと
		// 「材料そのものが無かった」のを読む側が見分けられないため。
		return out, "追随例の材料 (docs/migrations) が見つかりませんでした。" +
			"例が無いのでなく、探せていません"
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".auto.md") {
			names = append(names, e.Name())
		}
	}
	sort.Slice(names, func(i, j int) bool {
		return versionOfFile(names[i]) < versionOfFile(names[j])
	})
	for _, name := range names {
		v := versionOfFile(name)
		if !inRange(v, from, to) {
			continue
		}
		text, readErr := pxlib.LoadTextReplace(filepath.Join(dir, name))
		if readErr != nil {
			continue
		}
		for key, body := range sectionsOf(text) {
			out[key] = body
		}
	}
	return out, ""
}

// versionOfFile は "0.31.0.auto.md" を数の並びで比べられる形にする。
func versionOfFile(name string) string {
	return padVersion(strings.TrimSuffix(name, ".auto.md"))
}

// padVersion は "0.9.0" を "00000.00009.00000" にして字の順で比べられるようにする。
func padVersion(v string) string {
	parts := strings.Split(strings.TrimPrefix(v, "v"), ".")
	for i, p := range parts {
		for len(p) < 5 {
			p = "0" + p
		}
		parts[i] = p
	}
	return strings.Join(parts, ".")
}

func inRange(padded, from, to string) bool {
	if padded <= padVersion(from) {
		return false
	}
	return to == "" || padded <= padVersion(to)
}

// sectionsOf は生成した材料から「名前 → 追随例の本文」を取る。
func sectionsOf(text string) map[string]string {
	out := map[string]string{}
	name, keep := "", false
	var body []string
	flush := func() {
		if name != "" && len(body) > 0 {
			out[name] = strings.TrimSpace(strings.Join(body, "\n"))
		}
		name, keep, body = "", false, nil
	}
	for _, line := range pxlib.SplitLines(text) {
		if m := sectionRe.FindStringSubmatch(line); m != nil {
			flush()
			name = m[1]
			continue
		}
		if strings.HasPrefix(line, "## ") {
			flush()
			continue
		}
		if strings.HasPrefix(line, "engine 自身はこう直しました") {
			keep = true
			continue
		}
		if keep {
			body = append(body, line)
		}
	}
	flush()
	return out
}
