package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
)

// webEncoders は見つかった変換の道具の道（空は無い）。Dwebp はアトラスの画素を戻して元と比べるのに使う。
type webEncoders struct {
	FFmpeg, Cwebp, Dwebp, Brotli string
}

// findWebEncoders は PATH → engine の devbox → Homebrew・nix の profile の順に、使う種類の道具（ffmpeg は libopus 付き・cwebp・dwebp・brotli）を探す。
// WhyNot: images が false でも cwebp を探す — アトラスは劣化なしで、戻した画素が元とバイト一致した時だけ替えるので、絵の圧縮を止める理由が当たらない。
func findWebEncoders(engine string, c webCompress) webEncoders {
	var e webEncoders
	if p := findWebTool("ffmpeg", engine); c.Audio && p != "" && ffmpegHasLibopus(p) {
		e.FFmpeg = p
	}
	e.Cwebp = findWebTool("cwebp", engine)
	e.Dwebp = findWebTool("dwebp", engine)
	if c.WasmBrotli {
		e.Brotli = findBrotli(engine)
	}
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

// findBrotli は findWebTool で見つからなければ nix の store にある brotli の CLI を使う。
// WhyNot: store を探すのは brotli だけ — ffmpeg は libopus の有無が物ごとに違い、cwebp は包みの名前（libwebp）が違うので、名前で拾うと外れる。
func findBrotli(engine string) string {
	if p := findWebTool("brotli", engine); p != "" {
		return p
	}
	return newestNixStoreTool("/nix/store", "brotli", "brotli")
}

var nixStoreEntry = regexp.MustCompile(`^[0-9a-z]{32}-(.+)-([0-9][0-9.]*)$`)

// newestNixStoreTool は store の <hash>-<pkg>-<版> のうち bin/<exe> を持つ物で、版の最も新しい物の道（無ければ空）。
// 版が同じなら道の字の順で後ろの物を取り、同じ store からは毎回同じ物を選ぶ。
func newestNixStoreTool(store, pkg, exe string) string {
	entries, err := os.ReadDir(store)
	if err != nil {
		return ""
	}
	best, bestVer := "", ""
	for _, e := range entries {
		m := nixStoreEntry.FindStringSubmatch(e.Name())
		if m == nil || m[1] != pkg {
			continue
		}
		p := filepath.Join(store, e.Name(), "bin", exe)
		if !fileExists(p) {
			continue
		}
		c := compareDottedVersion(m[2], bestVer)
		if best == "" || c > 0 || (c == 0 && p > best) {
			best, bestVer = p, m[2]
		}
	}
	return best
}

// compareDottedVersion は "1.2.0" の形を数の並びとして比べる（a が大きければ正・同じなら 0）。
func compareDottedVersion(a, b string) int {
	as, bs := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(as) || i < len(bs); i++ {
		var x, y int
		if i < len(as) {
			x, _ = strconv.Atoi(as[i])
		}
		if i < len(bs) {
			y, _ = strconv.Atoi(bs[i])
		}
		if x != y {
			return x - y
		}
	}
	return 0
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
