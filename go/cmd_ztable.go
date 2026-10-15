package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/ztable"
)

func init() {
	// WhyNot: engineOnly にしないのは、z の表を散らして同じ数を取り合うのは
	// 画面の多いゲームの側で起きるため。
	register("z-table",
		"重なり順の z を数で決める所がパッケージに 1 か所か (散ると別のファイルどうしで同じ数を取り合う)",
		cmdZTable)
}

func cmdZTable(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := ztable.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
