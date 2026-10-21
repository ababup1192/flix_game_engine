package docrefs

// doc-refs の code の表（checkres に載せる）。docs/check-codes.md はこの表から書き出す。

import (
	"github.com/ababup1192/flix_game_engine/go/internal/checklevel"
	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

const (
	CodeName = "doc-refs.name"
	CodeFile = "doc-refs.file"
	CodeLine = "doc-refs.line"
)

var codes = []checkres.Code{
	{Name: CodeName, Level: checklevel.Gate, Metric: "missing_names", Unit: "count", Op: checkres.AtMost,
		Rule: "doc-refs.json sources・spansIndex", Summary: "文書の ` ` と表が指す Mod.name が src・test の宣言に無い（頭のモジュールがこのリポの物だけ）"},
	{Name: CodeFile, Level: checklevel.Gate, Metric: "missing_files", Unit: "count", Op: checkres.AtMost,
		Rule: "doc-refs.json pathSkipPrefixes", Summary: "文書が指すパス（src/…flix・docs/…md など / を含む物）が無い"},
	{Name: CodeLine, Level: checklevel.Gate, Metric: "missing_lines", Unit: "count", Op: checkres.AtMost,
		Rule: "doc-refs.json", Summary: "文書の path:行 の行がそのファイルの行数を超える"},
}

func init() {
	for _, c := range codes {
		checkres.Register(c)
	}
}
