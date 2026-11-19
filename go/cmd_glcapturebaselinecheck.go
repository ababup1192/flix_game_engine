package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/compare"
)

func init() {
	register("gl-capture-baseline-check",
		"gl-capture の撮り物を基準の SHA と比べ、違うコマだけ手元の基準の絵と画素で比べて小さい差なら通す (make gl-capture-check)",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			return compare.RunCaptureBaseline(rest, out, errOut)
		})
}
