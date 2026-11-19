package main

import (
	"fmt"
	"io/fs"
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
	cmd.Env = withoutMakeVars(os.Environ())
	cmd.Stdout = exportWebLog
	cmd.Stderr = exportWebLog
	return cmd.Run()
}

// withoutMakeVars は env から親の make が子へ渡す物（コマンド行の変数・jobserver・段の深さ）を外す。
// WhyNot: 親の make（ゲームの make tape）の MAKEFLAGS を engine の make へ渡さない — ゲームのコマンド行の変数（FLOW= など）や -j の口が engine の sync に混ざる。
func withoutMakeVars(env []string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		name, _, _ := strings.Cut(kv, "=")
		if name == "MAKEFLAGS" || name == "MFLAGS" || name == "MAKELEVEL" || name == "MAKEOVERRIDES" {
			continue
		}
		out = append(out, kv)
	}
	return out
}

// fullWebSourceDirs は engine_full_web を組む元（engine_full の 4 つと engine_full にだけある物と engine_web）。
var fullWebSourceDirs = []string{"engine/src", "render_gl/src", "render_gl/java", "engine_world/src", "engine_tools/src", "engine_full/src/full", "engine_web"}

// newerFullWebSource は engine_full_web の元のうち、built より新しい物を 1 つ（無ければ空）。
// WhyNot: 版の名前だけで新しさを決めない — タグの後のコミットは同じ版の名前のまま中身が変わり、古い束では新しい def が無くて書き出しの型検査で止まる。
func newerFullWebSource(engine, built string) string {
	info, err := os.Stat(built)
	if err != nil {
		return ""
	}
	found := ""
	for _, dir := range fullWebSourceDirs {
		_ = filepath.WalkDir(filepath.Join(engine, dir), func(path string, d fs.DirEntry, err error) error {
			if err != nil || found != "" {
				return filepath.SkipDir
			}
			ext := filepath.Ext(path)
			if d.IsDir() || (ext != ".flix" && ext != ".java") {
				return nil
			}
			if fi, err := d.Info(); err == nil && fi.ModTime().After(info.ModTime()) {
				found, _ = filepath.Rel(engine, path)
			}
			return nil
		})
	}
	return found
}

// fullWebBuiltAt は entry の束を組んだ時刻を持つファイル: build/engine_full_web の束が entry と同じ中身ならそれ、違えば entry の物。
// WhyNot: entry の時刻だけを見ない — 中身が同じなら置き場は前のエントリを残すので、ソースに触っただけで組み直した後も古く見え続ける。
func fullWebBuiltAt(engine, entry string) string {
	inEntry := filepath.Join(entry, "package.fpkg")
	built := filepath.Join(engine, "build", "engine_full_web", "artifact", "package.fpkg")
	a, errA := fpkgstore.Sha256File(inEntry)
	b, errB := fpkgstore.Sha256File(built)
	if errA == nil && errB == nil && a == b {
		return built
	}
	return inEntry
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
	if newer := newerFullWebSource(engine, fullWebBuiltAt(engine, entry)); newer != "" {
		return fmt.Sprintf("置き場の今のエントリ（%s）より新しいソースがある（%s）", base, newer)
	}
	return ""
}

// ensureFullWebFresh は、ゲームの版と engine の版がそろっているかを見て、置き場の engine_full_web が古ければ
// 作業コピー（go/ と Makefile がある engine）に限り make sync-engine-full-web を流して入れ直す（FGE_NO_AUTO_SYNC=1 で流さない）。止める時は終わりの番号と理由。
// WhyNot: 版のずれたゲームを書き出さない — 頁の js（engine_web/js）は engine の今の物で、ゲームの lib の engine と食い違う。
// WhyNot: 配った版（go/ が無い）では組み直さない — 置き場を作る道具（Makefile の sync）を持たず、同梱の束をそのまま読む。
func ensureFullWebFresh(engine, gameVersion string) (int, error) {
	if ev := status.ReadEngineVersion(engine); ev != "" && ev != gameVersion {
		return 2, fmt.Errorf("ゲームは v%s・engine は v%s で版がずれている（書き出しは engine の今の engine_web を使うので、そろえないと組めない）。\n"+
			"  次: ゲームのフォルダで make engine-upgrade（Studio なら engine の版を上げる操作）を流してから書き出す", gameVersion, ev)
	}
	if !dirExists(filepath.Join(engine, "go")) || !fileExists(filepath.Join(engine, "Makefile")) || os.Getenv("FGE_NO_AUTO_SYNC") == "1" {
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
