package checkres

// code の表: 全部の検査の code・重さ・測る物・単位・向きを 1 か所に並べる。
// px・snd はそれぞれの init で Register し、docs/check-codes.md はこの表から書き出す（Markdown）。
// テストは「表に無い code を出さない」「表の code に検査の実装がある」を見る。

import (
	"fmt"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
)

// Code は表の 1 行。
type Code struct {
	Name    string           // 変わらない名前（例 px.ground-contrast・snd.truepeak）
	Level   checklevel.Level // 既定の重さ（結果の側で軽くする物は Levels に並べる）
	Levels  []checklevel.Level
	Metric  string // 測る物の名前（例 edge_ground_dL）
	Unit    string // 単位（L・px・dBTP・LUFS・ms・count など）
	Op      Op     // 基準の向き
	Summary string // 1 行の説明
	Rule    string // 基準の出どころ（例 px.json groundContrastMin）
}

var table = map[string]Code{}

// Register は表に 1 行を載せる。同じ名前を 2 度載せたら panic。
func Register(c Code) {
	if _, dup := table[c.Name]; dup {
		panic("checkres: code を 2 度登録した: " + c.Name)
	}
	if !c.Level.Valid() || c.Metric == "" || c.Unit == "" || c.Op == "" {
		panic("checkres: code の行に level・metric・unit・op を書く: " + c.Name)
	}
	table[c.Name] = c
}

// Lookup は表の行を引く。
func Lookup(name string) (Code, bool) { c, ok := table[name]; return c, ok }

// All は表を名前の順で返す（prefix が "" でなければその道具だけ）。
func All(prefix string) []Code {
	var out []Code
	for _, c := range table {
		if prefix == "" || strings.HasPrefix(c.Name, prefix) {
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (c Code) levels() string {
	ls := []string{c.Level.String()}
	for _, l := range c.Levels {
		if l != c.Level {
			ls = append(ls, l.String())
		}
	}
	return strings.Join(ls, "・")
}

// Markdown は docs/check-codes.md の本文。
func Markdown() string {
	var b strings.Builder
	b.WriteString("# 検査の code の表\n\n")
	b.WriteString("bin/fge check codes --md が go/internal/checkres の表から書き出す（手で直さない）。\n")
	b.WriteString("1 件の形・status（pass/near/fail）・score・next・終了コードの決まりは docs/check-results.md。\n")
	b.WriteString("near の帯は bin/lint-rules/checkfmt.json の near（code ごと。無ければ nearRatio）。\n\n")
	b.WriteString("| code | level | metric | unit | want | 基準の出どころ | 説明 |\n|---|---|---|---|---|---|---|\n")
	for _, c := range All("") {
		fmt.Fprintf(&b, "| `%s` | %s | %s | %s | %s | %s | %s |\n", c.Name, c.levels(), c.Metric, c.Unit, c.Op, c.Rule, strings.ReplaceAll(c.Summary, "|", "／"))
	}
	return b.String()
}

// Text は 1 行ずつの一覧（bin/fge check codes）。
func Text(prefix string) string {
	var b strings.Builder
	for _, c := range All(prefix) {
		fmt.Fprintf(&b, "%-26s %-11s %s %s %s — %s\n", c.Name, c.levels(), c.Metric, c.Op, c.Unit, c.Summary)
	}
	return b.String()
}
