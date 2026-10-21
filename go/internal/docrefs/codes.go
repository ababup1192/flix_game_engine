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
	// CodeCaller は .flix のコメントに書いた呼び手（「名前 が呼ぶ」。callers.go）。
	CodeCaller = "doc-refs.caller"
)

var codes = []checkres.Code{
	{Name: CodeName, Level: checklevel.Gate, Metric: "missing_names", Unit: "count", Op: checkres.AtMost,
		Rule: "doc-refs.json sources・spansIndex", Summary: "文書の ` ` と表が指す Mod.name が src・test の宣言に無い（頭のモジュールがこのリポの物だけ）"},
	{Name: CodeFile, Level: checklevel.Gate, Metric: "missing_files", Unit: "count", Op: checkres.AtMost,
		Rule: "doc-refs.json pathSkipPrefixes", Summary: "文書が指すパス（src/…flix・docs/…md など / を含む物）が無い"},
	{Name: CodeLine, Level: checklevel.Gate, Metric: "missing_lines", Unit: "count", Op: checkres.AtMost,
		Rule: "doc-refs.json", Summary: "文書の path:行 の行がそのファイルの行数を超える"},
	{Name: CodeCaller, Level: checklevel.Gate, Metric: "stale_callers", Unit: "count", Op: checkres.AtMost,
		Rule: "doc-refs.json callersLimitFile", Summary: ".flix のコメント（/// と //）の「名前 が呼ぶ・から呼ぶ・が読む・が使う・が組む・が受け取る・で受け取る」（doc に書いた呼び手。関数を移すと古くなる）。上限で数える"},
}

func init() {
	for _, c := range codes {
		checkres.Register(c)
	}
}
