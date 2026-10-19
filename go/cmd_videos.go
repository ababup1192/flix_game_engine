package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/videos"
)

func init() {
	register("videos",
		"撮った動画（debug/video/）の一覧と撮れたかの判定（status。Studio の動画のタブと同じ物を読む）",
		cmdVideos)
}

func cmdVideos(out, errOut *strings.Builder, rest []string, asJSON bool) int {
	root, rest := declValueFlagOr(rest, "--root")
	rest = dropJSONFlag(rest)
	if len(rest) != 1 || rest[0] != "status" {
		errOut.WriteString("使い方: bin/fge videos status [--root DIR] [--json]   （ゲームの根で）\n")
		return 2
	}
	list := videos.List(root, videos.PidAlive)
	if asJSON {
		emitJSON(out, map[string]any{"dir": videos.Dir, "videos": list})
		return 0
	}
	out.WriteString(videos.Text(list))
	return 0
}

// declValueFlagOr は `--name 値` を取り出す。無ければ今いる所（ゲームの根で流す道具の既定）。
func declValueFlagOr(args []string, name string) (string, []string) {
	value, rest, ok := declValueFlag(args, name)
	if ok {
		return value, rest
	}
	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	return cwd, rest
}
