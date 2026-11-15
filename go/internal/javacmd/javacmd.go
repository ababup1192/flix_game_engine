// Package javacmd は bin/fge が java を起こす時の java の決め方（bin/flix と同じ順）を 1 か所に持つ。
//
//	JAVA（名指し）→ PATH の java（-version が通る物）→ engine の devbox の jdk → main の checkout の devbox の jdk → java
//
// WhyNot: PATH の java を在るかどうか（LookPath）で決めない。macOS には /usr/bin/java という「Java を入れてください」と
// 言うだけの入口が必ず在り、devbox の外（Studio の .app・素のターミナル・devbox の無い worktree）ではそれを掴んで止まる。
package javacmd

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
)

// pathJavaWorks は PATH の java が -version で通るか（1 つの走行で 1 度だけ起こす）。テストが替える。
var pathJavaWorks = sync.OnceValue(func() bool {
	return exec.Command("java", "-version").Run() == nil
})

// Resolve は engine（engine の根）から見た java の呼び方。PATH の java が通れば "java"、devbox の jdk なら絶対パス。
// どれも無ければ "java"（起こした所で止まり、誤りはそこで出る）。
func Resolve(engine string) string {
	if j := os.Getenv("JAVA"); j != "" {
		return j
	}
	if pathJavaWorks() {
		return "java"
	}
	if bin := DevboxBin(engine); bin != "" {
		return filepath.Join(bin, exe())
	}
	return "java"
}

// PathWorks は PATH の java が -version で通るか（PATH を替えて flixlint などに java を渡す所が使う）。
func PathWorks() bool { return pathJavaWorks() }

// DevboxBin は java の居る devbox の bin（engine の物、無ければ main の checkout の物）。無ければ ""。
//
// main の checkout の物を見るのは、engine が git の worktree で、その devbox.json が main の checkout の物と同じ時だけ。
// WhyNot: worktree の .devbox を待たない。.devbox は checkout ごとの生成物（git に入らず、作るのに nix の取得が要る）で、
// エージェントの worktree には無い。devbox.json が同じなら jdk の版も同じなので、main の物を借りて違いは出ない。
// WhyNot: devbox.json が違う時は借りない。jdk の版を替えた枝で前の版の jdk を黙って使うと、フォントの計測がずれて
// 描き出しのスナップショットが崩れる（bin/flix が jdk を固定する理由と同じ）。
func DevboxBin(engine string) string {
	if engine == "" {
		return ""
	}
	if bin := devboxBinOf(engine); bin != "" {
		return bin
	}
	main := MainCheckout(engine)
	if main == "" || !sameFile(filepath.Join(engine, "devbox.json"), filepath.Join(main, "devbox.json")) {
		return ""
	}
	return devboxBinOf(main)
}

func devboxBinOf(root string) string {
	bin := filepath.Join(root, ".devbox", "nix", "profile", "default", "bin")
	if info, err := os.Stat(filepath.Join(bin, exe())); err == nil && !info.IsDir() {
		return bin
	}
	return ""
}

// MainCheckout は engine が git の worktree の時、main の checkout の根（git の common dir の親）。worktree でなければ ""。
// git を起こさず .git のファイル（gitdir:）と commondir を読む。
func MainCheckout(engine string) string {
	b, err := os.ReadFile(filepath.Join(engine, ".git"))
	if err != nil {
		return ""
	}
	gitdir, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir:")
	if !ok {
		return ""
	}
	gitdir = strings.TrimSpace(gitdir)
	if !filepath.IsAbs(gitdir) {
		gitdir = filepath.Join(engine, gitdir)
	}
	c, err := os.ReadFile(filepath.Join(gitdir, "commondir"))
	if err != nil {
		return ""
	}
	common := strings.TrimSpace(string(c))
	if !filepath.IsAbs(common) {
		common = filepath.Join(gitdir, common)
	}
	main := filepath.Dir(filepath.Clean(common))
	if main == filepath.Clean(engine) {
		return ""
	}
	return main
}

func sameFile(a, b string) bool {
	x, err := os.ReadFile(a)
	if err != nil {
		return false
	}
	y, err := os.ReadFile(b)
	return err == nil && bytes.Equal(x, y)
}

func exe() string {
	if runtime.GOOS == "windows" {
		return "java.exe"
	}
	return "java"
}
