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
)

var codes = []checkres.Code{
	{Name: CodeRefs, Level: checklevel.Lint, Metric: "refs", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（無ければ一覧だけ）", Summary: "def・enum・case の参照の数（宣言は数えない）"},
	{Name: CodeMatchSites, Level: checklevel.Lint, Metric: "match_sites", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（無ければ一覧だけ）", Summary: "enum（か case）への match の数。--catch-all なら `_`・変数の腕を持つ物だけ"},
	{Name: CodeFieldSites, Level: checklevel.Lint, Metric: "field_sites", Unit: "count", Op: checkres.AtMost,
		Rule: "--max（欄の歯止めは --outside <口の mod> --max 0）", Summary: "record の欄の直の読み書きの数（受け手の型 alias で絞る）"},
}

func init() {
	for _, c := range codes {
		checkres.Register(c)
	}
}
