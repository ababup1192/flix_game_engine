package main

import (
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/talk"
)

func init() {
	register("talk",
		"会話のシナリオ（.yarn）の行から本物の画面へ: goto（起動中のゲームを飛ばす）・shot（窓なしで 1 枚撮る）・where（行のノード）",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			// WhyNot: repoRoot を使わない — ゲームの根（.yarn のパスを数える所）で流す道具。
			root, _ := os.Getwd()
			return talk.Run(out, errOut, root, rest)
		})
}
