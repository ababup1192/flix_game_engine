package refactor

// refactor の code の表（checkres に載せる）。docs/check-codes.md はこの表から書き出す。

import (
	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

const (
	CodeRefs       = "refactor.refs"
	CodeMatchSites = "refactor.match-sites"
	CodeFieldSites = "refactor.field-sites"
	CodeExpand     = "refactor.expand-wildcard"
	CodeRemoveDead = "refactor.remove-dead"
	CodeAccessor   = "refactor.field-to-accessor"
)

var codes = []checkres.Code{
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
}

func init() {
	for _, c := range codes {
		checkres.Register(c)
	}
}
