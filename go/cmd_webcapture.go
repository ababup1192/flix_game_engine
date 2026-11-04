package main

import (
	"fmt"
	"image/png"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

const webCaptureUsage = "使い方: fge web-capture <URL> <出力.png> [--wait <秒>] [--size WxH]\n" +
	"  頁の約束（window.fgeCaptureReady と window.fgeCapture()）は docs/web-capture.md"

func init() {
	register("web-capture",
		"ヘッドレスの Chrome で頁を開き、頁が readPixels で返した canvas の画素を PNG に書く (docs/web-capture.md)",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			return cmdWebCapture(out, errOut, rest)
		})
}

func cmdWebCapture(out, errOut *strings.Builder, args []string) int {
	opt := cdp.Options{}
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch a {
		case "--wait", "--size":
			if i+1 >= len(args) {
				fmt.Fprintf(errOut, "%s の値がありません\n%s\n", a, webCaptureUsage)
				return 2
			}
			v := args[i+1]
			i++
			if a == "--wait" {
				sec, err := strconv.ParseFloat(v, 64)
				if err != nil || sec <= 0 {
					fmt.Fprintf(errOut, "--wait は正の秒数: %q\n", v)
					return 2
				}
				opt.Wait = time.Duration(sec * float64(time.Second))
				continue
			}
			w, h, ok := parseSize(v)
			if !ok {
				fmt.Fprintf(errOut, "--size は WxH (例 640x360): %q\n", v)
				return 2
			}
			opt.Width, opt.Height = w, h
		default:
			if strings.HasPrefix(a, "--") {
				fmt.Fprintf(errOut, "知らない旗: %s\n%s\n", a, webCaptureUsage)
				return 2
			}
			pos = append(pos, a)
		}
	}
	if len(pos) != 2 {
		fmt.Fprintln(errOut, webCaptureUsage)
		return 2
	}
	opt.URL = pos[0]
	dest := pos[1]

	res, err := cdp.Capture(opt)
	if err != nil {
		fmt.Fprintf(errOut, "web-capture: %v\n", err)
		return 1
	}
	if dir := filepath.Dir(dest); dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			fmt.Fprintf(errOut, "web-capture: %v\n", err)
			return 1
		}
	}
	f, err := os.Create(dest)
	if err != nil {
		fmt.Fprintf(errOut, "web-capture: %v\n", err)
		return 1
	}
	if err := png.Encode(f, res.Image); err != nil {
		f.Close()
		fmt.Fprintf(errOut, "web-capture: PNG を書けない: %v\n", err)
		return 1
	}
	if err := f.Close(); err != nil {
		fmt.Fprintf(errOut, "web-capture: %v\n", err)
		return 1
	}
	b := res.Image.Bounds()
	fmt.Fprintf(out, "[web-capture] %s %dx%d\n", dest, b.Dx(), b.Dy())
	fmt.Fprintf(out, "  chrome:   %s (%s)\n", res.Version, res.Chrome)
	if res.Renderer != "" {
		fmt.Fprintf(out, "  renderer: %s\n", res.Renderer)
	}
	return 0
}

func parseSize(s string) (int, int, bool) {
	ws, hs, ok := strings.Cut(strings.ToLower(s), "x")
	if !ok {
		return 0, 0, false
	}
	w, err1 := strconv.Atoi(ws)
	h, err2 := strconv.Atoi(hs)
	if err1 != nil || err2 != nil || w <= 0 || h <= 0 {
		return 0, 0, false
	}
	return w, h, true
}
