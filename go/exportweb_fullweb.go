package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/fpkgstore"
	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// syncFullWeb は engine の根で make sync-engine-full-web を流す。テストは差し替える。
var syncFullWeb = func(engine string) error {
	makeCmd := os.Getenv("MAKE")
	if makeCmd == "" {
		makeCmd = "make"
	}
	cmd := exec.Command(makeCmd, "-C", engine, "--no-print-directory", "sync-engine-full-web")
	cmd.Stdout = exportWebLog
	cmd.Stderr = exportWebLog
	return cmd.Run()
}

// fullWebEntryStaleness は置き場の engine_full_web が版 v の書き出しに使えない理由（使えるなら空）。
func fullWebEntryStaleness(engine, v string) string {
	entry, ok := fpkgstore.Current(engine, fpkgstore.EngineFullWeb)
	if !ok {
		return "置き場に engine_full_web が無い"
	}
	base := filepath.Base(entry)
	if !strings.HasPrefix(base, fpkgstore.EngineFullWeb+"-"+v+"-") {
		return fmt.Sprintf("置き場の今のエントリ（%s）が v%s の物ではない", base, v)
	}
	for _, name := range []string{"package.fpkg", "flix.toml", "fge-web-" + v + ".jar", "fge-web-tools-" + v + ".jar"} {
		if !fileExists(filepath.Join(entry, name)) {
			return fmt.Sprintf("置き場の今のエントリ（%s）に %s が無い", base, name)
		}
	}
	return ""
}

// ensureFullWebFresh は、ゲームの版と engine の版がそろっているかを見て、置き場の engine_full_web が古ければ
// 作業コピー（go/ と Makefile がある engine）に限り make sync-engine-full-web を流して入れ直す。止める時は終わりの番号と理由。
// WhyNot: 版のずれたゲームを書き出さない — 頁の js（engine_web/js）は engine の今の物で、ゲームの lib の engine と食い違う。
// WhyNot: 配った版（go/ が無い）では組み直さない — 置き場を作る道具（Makefile の sync）を持たず、同梱の束をそのまま読む。
func ensureFullWebFresh(engine, gameVersion string) (int, error) {
	if ev := status.ReadEngineVersion(engine); ev != "" && ev != gameVersion {
		return 2, fmt.Errorf("ゲームは v%s・engine は v%s で版がずれている（書き出しは engine の今の engine_web を使うので、そろえないと組めない）。\n"+
			"  次: ゲームのフォルダで make engine-upgrade を流してから書き出す", gameVersion, ev)
	}
	if !dirExists(filepath.Join(engine, "go")) || !fileExists(filepath.Join(engine, "Makefile")) {
		return 0, nil
	}
	why := fullWebEntryStaleness(engine, gameVersion)
	if why == "" {
		return 0, nil
	}
	ewLogf("%s。engine の根で make sync-engine-full-web を流して入れ直す", why)
	if err := syncFullWeb(engine); err != nil {
		return 1, fmt.Errorf("make sync-engine-full-web が通らない（%v）。\n  次: engine の根で make sync-engine-full-web を流して赤を読む", err)
	}
	if why := fullWebEntryStaleness(engine, gameVersion); why != "" {
		return 1, fmt.Errorf("make sync-engine-full-web の後も %s。\n  次: engine の VERSION とゲームの flix.toml の版を確かめる", why)
	}
	return 0, nil
}
