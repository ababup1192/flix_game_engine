package main

import (
	"encoding/json"
	"fmt"
	"image/png"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

const webCaptureUsage = "使い方: fge web-capture <URL> <出力.png> [--wait <秒>] [--size WxH] [--dir <書き出したフォルダ>] [--dev <語,語…>]\n" +
	"  --dir はそのフォルダを 127.0.0.1 の使い捨ての口で配り、<URL> をその頁の道とクエリ（例 index.html）として読む\n" +
	"  --dev は頁の旗を頁より先に window.fgeDev で入れる（例 --dev capture:6,deferred:all,webgl2。語は ?fge= と同じ・docs/web-capture.md の「頁の旗」）\n" +
	"  --console-errors は頁を開いてから撮るまでの console.error と拾われなかった例外を数え、1 件でもあれば行を出して exit 1\n" +
	"  --console-allow <正規表現> は --console-errors で数えない行（何度でも書ける。例 '^WebFs fail-open: '）\n" +
	"  頁の約束（window.fgeCaptureReady と window.fgeCapture()）は docs/web-capture.md"

// webConsoleErrorsInit は頁のどの script よりも先に流し、console.error と拾われなかった例外を window.fgeConsoleErrors へ積む。
// WhyNot: CDP の Runtime.consoleAPICalled を購読しない — cdp の client は呼んだ答えを待つだけで、届いた知らせを溜める口を持たない。
// 頁の中で積めば Worker から頁へ送り直された行（[glb-worker]）も同じ所に入る。
const webConsoleErrorsInit = `(function () {
  var list = window.fgeConsoleErrors = [];
  var push = function (s) { if (list.length < 50) list.push(String(s).slice(0, 400)); };
  var orig = console.error;
  console.error = function () { push(Array.prototype.map.call(arguments, String).join(" ")); return orig.apply(console, arguments); };
  window.addEventListener("error", function (e) { push("error: " + ((e.error && (e.error.stack || e.error.message)) || e.message)); });
  window.addEventListener("unhandledrejection", function (e) { push("unhandledrejection: " + ((e.reason && e.reason.stack) || e.reason)); });
})();`

// webConsoleErrorsOf は頁が積んだ行（webConsoleErrorsInit）を読む。頁が積み場を持たない時は空。
func webConsoleErrorsOf(raw []byte) ([]string, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var lines []string
	if err := json.Unmarshal(raw, &lines); err != nil {
		return nil, fmt.Errorf("頁の window.fgeConsoleErrors の形が違う: %v", err)
	}
	return lines, nil
}

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
	serveDir := ""
	var dev *webPageSwitches
	consoleErrors := false
	var consoleAllow []*regexp.Regexp
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch a {
		case "--console-errors":
			consoleErrors = true
			continue
		case "--console-allow":
			if i+1 >= len(args) {
				fmt.Fprintf(errOut, "--console-allow の値がありません\n%s\n", webCaptureUsage)
				return 2
			}
			re, err := regexp.Compile(args[i+1])
			if err != nil {
				fmt.Fprintf(errOut, "--console-allow: %v\n", err)
				return 2
			}
			consoleAllow = append(consoleAllow, re)
			i++
			continue
		case "--dir":
			if i+1 >= len(args) {
				fmt.Fprintf(errOut, "--dir の値がありません\n%s\n", webCaptureUsage)
				return 2
			}
			serveDir = args[i+1]
			i++
			continue
		case "--dev":
			if i+1 >= len(args) {
				fmt.Fprintf(errOut, "--dev の値がありません\n%s\n", webCaptureUsage)
				return 2
			}
			sw, err := parseWebDevWords(args[i+1])
			if err != nil {
				fmt.Fprintf(errOut, "--dev: %v\n", err)
				return 2
			}
			opt.InitScript, dev = sw.initScript(), &sw
			i++
			continue
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
	if len(consoleAllow) > 0 && !consoleErrors {
		fmt.Fprintf(errOut, "--console-allow は --console-errors と一緒に使う\n%s\n", webCaptureUsage)
		return 2
	}
	if len(pos) != 2 {
		fmt.Fprintln(errOut, webCaptureUsage)
		return 2
	}
	opt.URL = pos[0]
	dest := pos[1]
	if serveDir != "" {
		listener, closeServer, err := serveLocalDir(serveDir)
		if err != nil {
			fmt.Fprintf(errOut, "web-capture: 配る口を開けない: %v\n", err)
			return 1
		}
		defer closeServer()
		opt.URL = "http://" + listener.Addr().String() + "/" + strings.TrimPrefix(pos[0], "/")
		if dev != nil {
			page, _, _ := strings.Cut(strings.TrimPrefix(pos[0], "/"), "?")
			url, initScript, err := dev.openURL(opt.URL, filepath.Join(serveDir, filepath.FromSlash(page)))
			if err != nil {
				fmt.Fprintf(errOut, "web-capture: --dev: %v（頁が頁の旗の読み手を持たない前の engine の書き出し）\n", err)
				return 2
			}
			opt.URL, opt.InitScript = url, initScript
		}
	}

	if consoleErrors {
		opt.InitScript = webConsoleErrorsInit + "\n" + opt.InitScript
		opt.Eval = "window.fgeConsoleErrors || null"
	}
	res, err := cdp.Capture(opt)
	if err != nil {
		fmt.Fprintf(errOut, "web-capture: %v\n", err)
		return 1
	}
	var consoleLines []string
	if consoleErrors {
		if consoleLines, err = webConsoleErrorsOf(res.Eval); err != nil {
			fmt.Fprintf(errOut, "web-capture: %v\n", err)
			return 1
		}
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
	if consoleErrors {
		bad, allowed := splitAllowedConsole(consoleLines, consoleAllow)
		fmt.Fprintf(out, "  console.error: %d 件（--console-allow で数えない %d 件）\n", len(bad), len(allowed))
		for _, l := range bad {
			fmt.Fprintf(out, "    %s\n", l)
		}
		for _, l := range allowed {
			fmt.Fprintf(out, "    数えない: %s\n", l)
		}
		if len(bad) > 0 {
			fmt.Fprintf(errOut, "web-capture: 頁が console.error か拾われなかった例外を %d 件出した\n", len(bad))
			return 1
		}
	}
	return 0
}

// splitAllowedConsole は頁の行を、数える物と allow のどれかに当たって数えない物に分ける。
func splitAllowedConsole(lines []string, allow []*regexp.Regexp) (bad, allowed []string) {
	for _, l := range lines {
		hit := false
		for _, re := range allow {
			if re.MatchString(l) {
				hit = true
				break
			}
		}
		if hit {
			allowed = append(allowed, l)
		} else {
			bad = append(bad, l)
		}
	}
	return bad, allowed
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

// serveLocalDir は dir を 127.0.0.1 の空いた口の使い捨ての http サーバーで配る（web-capture・web-bench・書き出しの確かめで共用）。
func serveLocalDir(dir string) (net.Listener, func(), error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, nil, err
	}
	srv := &http.Server{Handler: http.FileServer(http.Dir(dir)), ReadHeaderTimeout: 10 * time.Second}
	go srv.Serve(ln)
	return ln, func() { srv.Close() }, nil
}
