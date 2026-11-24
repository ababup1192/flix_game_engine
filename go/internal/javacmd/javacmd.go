// Package javacmd は bin/fge が java を起こす時の java の決め方を 1 か所に持つ。bin/flix と bin/headless-run が読む
// bin/java-resolve.sh と同じ順（片方を直したらもう片方も直す）:
//
//	JAVA → PATH の java → engine の devbox の jdk → main の checkout の devbox の jdk（どれも java -version が通る物だけ）
//
// 配った engine（go/ が無く mk/jdk.mk がある）だけは JAVA → 置き場の JDK（mk/jdk.mk が決める 1 つ）で、無ければ誤り。
// WhyNot: 配った engine で PATH の java へ移らない — 何も言わずに別の JDK で描き、フォントの計測がずれて絵が変わる。
//
// WhyNot: PATH の java を在るかどうか（LookPath）で決めない。macOS には /usr/bin/java という「Java を入れてください」と
// 言うだけの入口が必ず在り、devbox の外（Studio の .app・素のターミナル・devbox の無い worktree）ではそれを掴んで止まる。
package javacmd

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

var versionChecked sync.Map

// javaWorks は cmd -version が通るか（同じ cmd は 1 つの走行で 1 度だけ起こす）。テストが替える。
var javaWorks = func(cmd string) bool {
	if v, ok := versionChecked.Load(cmd); ok {
		return v.(bool)
	}
	ok := exec.Command(cmd, "-version").Run() == nil
	versionChecked.Store(cmd, ok)
	return ok
}

// Resolve は engine（engine のルート。ゲームの根ではない）から見た java の呼び方。PATH の java なら "java"、ほかは絶対パス。
// どれも通らなければ、JAVA を名指していればそれを、無ければ誤りを返す。
func Resolve(engine string) (string, error) {
	named := os.Getenv("JAVA")
	spec, ok, err := bundleJDK(engine)
	if err != nil {
		return "", err
	}
	if ok {
		for _, c := range []string{named, spec.Java()} {
			if c != "" && javaWorks(c) {
				return c, nil
			}
		}
		if named != "" {
			return named, nil
		}
		v := engineVersion(engine)
		return "", fmt.Errorf("engine %s の JDK（%s）がありません → fge engines install %s", v, spec.Dir(), v)
	}
	cands := []string{named, "java"}
	for _, bin := range devboxBins(engine) {
		cands = append(cands, filepath.Join(bin, exe()))
	}
	for _, c := range cands {
		if c != "" && javaWorks(c) {
			return c, nil
		}
	}
	if named != "" {
		return named, nil
	}
	return "", errors.New("java が見つかりません（JAVA で名指すか、engine で devbox shell に入る）")
}

// BundleBin は配った engine の時、Resolve が返した java の居る bin（PATH の頭に足す物）。配った engine でなければ ok=false。
func BundleBin(engine string) (string, bool) {
	if !IsBundle(engine) {
		return "", false
	}
	java, err := Resolve(engine)
	if err != nil || !filepath.IsAbs(java) {
		return "", false
	}
	return filepath.Dir(java), true
}

// IsBundle は engine が配った engine で、JDK を mk/jdk.mk で決める物か。
func IsBundle(engine string) bool {
	_, ok, _ := bundleJDK(engine)
	return ok
}

// bundleJDK は配った engine の mk/jdk.mk。clone した engine・mk/jdk.mk の無い版は ok=false。
func bundleJDK(engine string) (fgehome.JDKSpec, bool, error) {
	if !fgehome.IsBundle(engine) {
		return fgehome.JDKSpec{}, false, nil
	}
	return fgehome.ReadJDKSpec(engine)
}

var versionLineRe = regexp.MustCompile(`(?m)^VERSION\s*:=\s*(\S+)`)

// engineVersion は engine の Makefile の VERSION（読めなければ engine のフォルダ名。置き場では engines/<版>）。
func engineVersion(engine string) string {
	if b, err := os.ReadFile(filepath.Join(engine, "Makefile")); err == nil {
		if m := versionLineRe.FindSubmatch(b); m != nil {
			return string(m[1])
		}
	}
	return filepath.Base(engine)
}

// PathWorks は PATH の java が -version で通るか（PATH を替えて flixlint などに java を渡す所が使う）。
func PathWorks() bool { return javaWorks("java") }

// devboxBins は java を探す devbox の bin を使う順に（engine の物・devbox.json が同じなら main の checkout の物）。
func devboxBins(engine string) []string {
	if engine == "" {
		return nil
	}
	out := []string{devboxBinPath(engine)}
	if main := MainCheckout(engine); main != "" && sameFile(filepath.Join(engine, "devbox.json"), filepath.Join(main, "devbox.json")) {
		out = append(out, devboxBinPath(main))
	}
	return out
}

func devboxBinPath(root string) string {
	return filepath.Join(root, ".devbox", "nix", "profile", "default", "bin")
}

// DevboxBin は java の居る devbox の bin（engine の物、無ければ main の checkout の物）。無ければ ""。
//
// main の checkout の物を見るのは、engine が git の worktree で、その devbox.json が main の checkout の物と同じ時だけ。
// WhyNot: worktree の .devbox を待たない。.devbox は checkout ごとの生成物（git に入らず、作るのに nix の取得が要る）で、
// エージェントの worktree には無い。devbox.json が同じなら jdk の版も同じなので、main の物を借りて違いは出ない。
// WhyNot: devbox.json が違う時は借りない。jdk の版を替えた枝で前の版の jdk を知らせずに使うと、フォントの計測がずれて
// 描き出しのスナップショットが崩れる。
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
	bin := devboxBinPath(root)
	if info, err := os.Stat(filepath.Join(bin, exe())); err == nil && !info.IsDir() {
		return bin
	}
	return ""
}

// MainCheckout は engine が git の worktree の時、main の checkout のルート（git の common dir の親）。worktree でなければ ""。
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
