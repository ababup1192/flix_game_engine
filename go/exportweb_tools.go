package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

// webEncoders は見つかった変換の道具の道（空は無い）。Dwebp はアトラスの画素を戻して元と比べるのに使う。
type webEncoders struct {
	FFmpeg, Cwebp, Dwebp string
}

// findWebEncoders は PATH → engine の devbox → Homebrew・nix の profile の順に、使う種類の道具（ffmpeg は libopus 付き・cwebp・dwebp）を探す。
// WhyNot: images が false でも cwebp を探す — アトラスは劣化なしで、戻した画素が元とバイト一致した時だけ替えるので、絵の圧縮を止める理由が当たらない。
func findWebEncoders(engine string, c webCompress) webEncoders {
	var e webEncoders
	if p := findWebTool("ffmpeg", engine); c.Audio && p != "" && ffmpegHasLibopus(p) {
		e.FFmpeg = p
	}
	e.Cwebp = findWebTool("cwebp", engine)
	e.Dwebp = findWebTool("dwebp", engine)
	return e
}

func findWebTool(name, engine string) string {
	return findWebToolIn(name, engine, webToolDirs())
}

// findWebToolIn は PATH → engine の devbox → dirs の順に name を探す。
// WhyNot: PATH だけを見ない — Finder から開いた Studio の PATH には Homebrew も nix の profile も入っていない。
func findWebToolIn(name, engine string, dirs []string) string {
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	exe := name
	if os.PathSeparator == '\\' {
		exe += ".exe"
	}
	for _, dir := range append([]string{filepath.Join(engine, ".devbox", "nix", "profile", "default", "bin")}, dirs...) {
		if p := filepath.Join(dir, exe); fileExists(p) {
			return p
		}
	}
	return ""
}

// webToolDirs は Homebrew と nix の profile の bin。
func webToolDirs() []string {
	if runtime.GOOS == "windows" {
		return nil
	}
	dirs := []string{"/opt/homebrew/bin", "/usr/local/bin", "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin"}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, ".nix-profile", "bin"))
	}
	if u := os.Getenv("USER"); u != "" {
		dirs = append(dirs, filepath.Join("/etc/profiles/per-user", u, "bin"))
	}
	return dirs
}

func ffmpegHasLibopus(ffmpeg string) bool {
	out, err := exec.Command(ffmpeg, "-hide_banner", "-encoders").Output()
	return err == nil && regexp.MustCompile(`(?m)^\s*A\S*\s+libopus\s`).Match(out)
}

func runQuiet(name string, args ...string) error {
	c := exec.Command(name, args...)
	var stderr bytes.Buffer
	c.Stderr = &stderr
	if err := c.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if i := strings.IndexByte(msg, '\n'); i >= 0 {
			msg = msg[:i]
		}
		if msg == "" {
			return err
		}
		return fmt.Errorf("%v: %s", err, msg)
	}
	return nil
}
