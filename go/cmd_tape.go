package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/tape"
)

func init() {
	register("tape",
		"flow の動画に注釈を付ける頁を束ねる: tape --dir <フォルダ>（tape.json と video.mp4 → strip.jpg と index.html）・tape --group <フォルダ>…（分岐した複数のテープを分岐のカードでつなぐ）・tape publish <フォルダ>…（Pages の置き場へ置いて URL を出す）",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			var splash tape.Splash
			if len(rest) == 0 || rest[0] != "publish" {
				var warning string
				splash, warning = tapeSplash(engineDirOf(repoRoot()))
				if warning != "" {
					fmt.Fprintln(os.Stderr, "tape:", warning)
				}
			}
			return tape.Run(rest, splash, os.Stdout, os.Stderr)
		})
}

// tapeSplash はテープの頁が動画を取っている間に描く起動画面の材料を、ゲームのブラウザ版と同じ作り（buildWebSplash）で作る。
// WhyNot: テープのフォルダからゲームの project.json を辿らない — 起動画面で使うのはエンジンのロゴと字だけで、ゲームごとの値は要らない。
func tapeSplash(engine string) (tape.Splash, string) {
	s, warning := buildWebSplash(engine, "", nil)
	return tape.Splash{Logo: s.Logo, Font: s.Font, Glyphs: s.Glyphs, FontSize: s.FontSize,
		Ascent: s.Ascent, Descent: s.Descent, LineGap: s.LineGap, CellH: s.CellH}, warning
}
