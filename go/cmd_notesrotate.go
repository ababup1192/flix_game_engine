package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/notesrotate"
)

func init() {
	register("notes-rotate",
		"NOTES.md の先頭が長すぎたら古い項を notes/<年-月>.md へ送る (--check は止めるだけ・--dry-run は出すだけ)",
		cmdNotesRotate)
}

func cmdNotesRotate(out, errOut *strings.Builder, rest []string, _ bool) int {
	root, rest := declRootFlag(rest)
	code, err := notesrotate.Run(out, errOut, root, rest)
	return orAbort(errOut, code, err)
}
