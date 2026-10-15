package main

import (
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/useengine"
)

func init() {
	register("use-engine",
		"この作業場の local.mk と lib をその版（かパス）のエンジンへそろえる。--status / --restore",
		func(out, errOut *strings.Builder, rest []string, asJSON bool) int {
			// WhyNot: out に貯めないのは、版を組む間 (make sync) の進み具合を流すため。
			return useengine.Run(rest, asJSON, useengine.Options{})
		})
}
