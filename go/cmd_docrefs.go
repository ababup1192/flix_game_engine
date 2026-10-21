package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/docrefs"
)

func init() {
	// WhyNot: engineOnly にしないのは、消えた関数・無いファイルを指す文書がゲームの docs と NOTES.md で起きるため。
	register("doc-refs",
		"文書 (docs/**/*.md・NOTES.md・AGENTS.local.md) と .flix のコメントが指す Mod.name・パス・path:行 が実在するか",
		cmdDocRefs)
}

func cmdDocRefs(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	root, rest := declRootFlag(rest)
	rest = dropJSONFlag(rest)
	if asJSON {
		rest = append(rest, "--json")
	}
	code, err := docrefs.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
