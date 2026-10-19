package main

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/rendercache"
)

func init() {
	register("render-cache",
		"塗った PNG の取り置き（RenderCache）の大きさを見る（status）・古い物から消す（prune [--max-mb N] [--quiet]）",
		cmdRenderCache)
}

func cmdRenderCache(out, errOut *strings.Builder, rest []string, _ bool) int {
	usage := "使い方: bin/fge render-cache status | prune [--max-mb N] [--quiet]\n"
	if len(rest) == 0 {
		errOut.WriteString(usage)
		return 2
	}
	dir := rendercache.Dir()
	switch rest[0] {
	case "status":
		rendercache.Status(out, dir)
		return 0
	case "prune":
		maxMB := rendercache.DefaultMaxMB
		quiet := false
		for i := 1; i < len(rest); i++ {
			switch rest[i] {
			case "--quiet":
				quiet = true
			case "--max-mb":
				if i+1 >= len(rest) {
					errOut.WriteString(usage)
					return 2
				}
				n, err := strconv.Atoi(rest[i+1])
				if err != nil || n < 0 {
					errOut.WriteString(usage)
					return 2
				}
				maxMB = n
				i++
			default:
				errOut.WriteString(usage)
				return 2
			}
		}
		removed, kept := rendercache.Prune(dir, int64(maxMB)<<20)
		if !quiet || removed > 0 {
			fmt.Fprintf(out, "render-cache: %d 枚を消しました（残り %d MB・上限 %d MB）\n", removed, kept>>20, maxMB)
		}
		return 0
	}
	errOut.WriteString(usage)
	return 2
}
