package refactor

// refactor の code の表（checkres に載せる）。docs/check-codes.md はこの表から書き出す。

import (
	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

const (
	CodeUsages          = "refactor.usages"
	CodeUnused          = "refactor.unused"
	CodeRefs            = "refactor.refs"
	CodeMatchSites      = "refactor.match-sites"
	CodeFieldSites      = "refactor.field-sites"
	CodeExpand          = "refactor.expand-wildcard"
	CodeRemoveDead      = "refactor.remove-dead"
	CodeAccessor        = "refactor.field-to-accessor"
	CodeRemoveField     = "refactor.remove-field"
	CodeFixConstruction = "refactor.fix-construction"
)

var codes = []checkres.Code{
	{Name: CodeUsages, Level: checklevel.Lint, Metric: "usages", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（無ければ一覧だけ）", Summary: "def・enum・case・型 alias・record の欄の使われ所の数（呼び出し・参照・読み・書き・組み立て・パターン・型の注記・use）"},
	{Name: CodeUnused, Level: checklevel.Lint, Metric: "unused", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（無ければ一覧だけ）", Summary: "外から使われない pub の def（参照 0・テストからだけ・同じ mod の中だけ）と、使っていない use の数"},
	{Name: CodeRefs, Level: checklevel.Lint, Metric: "refs", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（無ければ一覧だけ）", Summary: "def・enum・case の参照の数（宣言は数えない）"},
	{Name: CodeMatchSites, Level: checklevel.Lint, Metric: "match_sites", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（無ければ一覧だけ）", Summary: "enum（か case）への match の数。--catch-all なら `_`・変数の腕を持つ物だけ"},
	{Name: CodeFieldSites, Level: checklevel.Lint, Metric: "field_sites", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（欄の歯止めは --outside <口の mod> --max 0）", Summary: "record の欄の直の読み書きの数（受け手の型 alias で絞る）"},
	{Name: CodeExpand, Level: checklevel.Lint, Metric: "catch_all_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（書き出せない腕は fix）", Summary: "enum への match の `case _` を残りの case に書き出した後に、人へ回した腕の数"},
	{Name: CodeRemoveDead, Level: checklevel.Lint, Metric: "dead_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（決められない def は fix）", Summary: "テストからだけ・どこからも参照されない pub の def を消した後に、人へ回した数"},
	{Name: CodeAccessor, Level: checklevel.Lint, Metric: "field_sites_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（受け手の型が決まらない・読めない式・型の違う口は fix）", Summary: "record の欄の直の読み書きを口（読み・書き）へ替えた後に、人へ回した数"},
	{Name: CodeRemoveField, Level: checklevel.Lint, Metric: "construction_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（直の読み書きが残れば止める・欄の組が同じ別の型の組み立ては fix）", Summary: "record の型から欄を消し、組み立てからも消した後に、人へ回した数（止めた時は残っている直の読み書きの数）"},
	{Name: CodeFixConstruction, Level: checklevel.Lint, Metric: "construction_left", Unit: "count", Op: checkres.AtMost,
		Rule: "0（欄の組が同じ別の型の組み立ては fix）", Summary: "record を組み立てる式の欄を型に合わせた（足した・消した）後に、人へ回した数"},
}

func init() {
	for _, c := range codes {
		checkres.Register(c)
	}
}
