package main

import "github.com/ababup1192/flix_game_engine/go/internal/selfexec"

// WhyNot: 一覧を写して渡さない — init の順で、まだ名乗っていないサブコマンドが落ちる。呼ばれた時に registry を見る。
func init() {
	selfexec.SetLookup(func(name string) bool {
		_, ok := registry[name]
		return ok
	})
}
