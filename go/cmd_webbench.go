package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

const webBenchUsage = "使い方: fge web-bench <書き出したフォルダ> [--query <a=1&b=2>] [--wait <秒>] [--size WxH] [--cpu <倍>] [--out <file>] [--jsonl <file>]\n" +
	"  ベンチのブラウザ版（make bench-web-export の出力）をヘッドレスの Chrome で開き、頁の window.__bench を JSON で出す\n" +
	"  --out は出した JSON をファイルにも書く・--jsonl は区間ごとの結果を 1 行ずつファイルの終わりへ足す\n" +
	"  --cpu は CPU を何倍遅くするか（4・6 でスマホの代わり。1 以下は絞らない。出す JSON の cpuThrottle に入る）"

func init() {
	register("web-bench",
		"ベンチのブラウザ版をヘッドレスの Chrome で開き、測り終えた頁の window.__bench を JSON で出す (make bench-web)",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			return cmdWebBench(out, errOut, rest)
		})
}

type webBenchOptions struct {
	Dir, Query, Out, JSONL string
	Wait                   time.Duration
	Width, Height          int
	CPU                    float64
}

func parseWebBenchArgs(args []string) (webBenchOptions, error) {
	o := webBenchOptions{Wait: 300 * time.Second, Width: 960, Height: 540}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch a {
		case "--query", "--wait", "--size", "--out", "--jsonl", "--cpu":
			if i+1 >= len(args) {
				return o, fmt.Errorf("%s の値がありません", a)
			}
			v := args[i+1]
			i++
			switch a {
			case "--query":
				o.Query = strings.TrimPrefix(v, "?")
			case "--out":
				o.Out = v
			case "--jsonl":
				o.JSONL = v
			case "--wait":
				sec, err := strconv.ParseFloat(v, 64)
				if err != nil || sec <= 0 {
					return o, fmt.Errorf("--wait は正の秒数: %q", v)
				}
				o.Wait = time.Duration(sec * float64(time.Second))
			case "--cpu":
				rate, err := strconv.ParseFloat(v, 64)
				if err != nil || rate <= 0 {
					return o, fmt.Errorf("--cpu は正の倍数: %q", v)
				}
				o.CPU = rate
			case "--size":
				w, h, ok := parseSize(v)
				if !ok {
					return o, fmt.Errorf("--size は WxH (例 960x540): %q", v)
				}
				o.Width, o.Height = w, h
			}
		default:
			if strings.HasPrefix(a, "--") {
				return o, fmt.Errorf("知らない旗: %s", a)
			}
			if o.Dir != "" {
				return o, fmt.Errorf("フォルダは 1 つだけ: %s と %s", o.Dir, a)
			}
			o.Dir = a
		}
	}
	if o.Dir == "" {
		return o, fmt.Errorf("書き出したフォルダがありません")
	}
	return o, nil
}

// webBenchProbe は頁の今の様子（測り終えたか・何区間終えたか・止まった理由・起動画面が残っているか）。
const webBenchProbe = `(() => {
  const b = window.__bench;
  const err = document.getElementById("fge-error");
  const boot = document.getElementById("fge-boot");
  return {
    overlay: !!b, done: !!(b && b.done), results: b ? b.results.length : 0,
    error: (b && b.error) || (err && err.style.display !== "none" ? err.textContent : ""),
    booting: !!(boot && boot.style.display !== "none")
  };
})()`

type webBenchState struct {
	Overlay bool   `json:"overlay"`
	Done    bool   `json:"done"`
	Results int    `json:"results"`
	Error   string `json:"error"`
	Booting bool   `json:"booting"`
}

func cmdWebBench(out, errOut *strings.Builder, args []string) int {
	o, err := parseWebBenchArgs(args)
	if err != nil {
		fmt.Fprintf(errOut, "web-bench: %v\n%s\n", err, webBenchUsage)
		return 2
	}
	if _, err := os.Stat(filepath.Join(o.Dir, "index.html")); err != nil {
		fmt.Fprintf(errOut, "web-bench: %s に index.html が無い。\n  次: make bench-web-export BENCH=<名前> で書き出す\n", o.Dir)
		return 2
	}
	listener, closeServer, err := serveLocalDir(o.Dir)
	if err != nil {
		fmt.Fprintf(errOut, "web-bench: 配る口を開けない: %v\n", err)
		return 1
	}
	defer closeServer()

	url := "http://" + listener.Addr().String() + "/index.html"
	if o.Query != "" {
		url += "?" + o.Query
	}
	page, err := cdp.OpenPage(cdp.PageOptions{Width: o.Width, Height: o.Height, CPUThrottle: o.CPU})
	if err != nil {
		fmt.Fprintf(errOut, "web-bench: %v\n", err)
		return 1
	}
	defer page.Close()
	if err := page.Navigate(url); err != nil {
		fmt.Fprintf(errOut, "web-bench: %v\n", err)
		return 1
	}

	deadline := time.Now().Add(o.Wait)
	var state webBenchState
	for {
		// WhyNot: 頁の移り変わりの途中は評価が失敗することがあるので、読めない回は失敗にせず次を待つ。
		if page.Eval(webBenchProbe, &state) == nil {
			if state.Error != "" {
				fmt.Fprintf(errOut, "web-bench: 頁が止まった: %s\n", state.Error)
				return 1
			}
			if state.Done {
				break
			}
			// 起動画面は押すまで待つので、消えるまでキーを送り続ける（頁が聞き始める前の押しは届かない）。
			if state.Booting {
				_ = page.PressKey("Enter", 0)
			}
		}
		if time.Now().After(deadline) {
			hint := "window.__bench.done が true にならない"
			if !state.Overlay {
				hint = "頁に window.__bench が無い（bench-overlay.js が index.html に入っていない。make bench-web-export で書き出す）"
			}
			fmt.Fprintf(errOut, "web-bench: %s 待っても%s（終えた区間 %d）。\n  次: --wait を延ばすか、query の frames を減らす\n", o.Wait, hint, state.Results)
			return 1
		}
		time.Sleep(200 * time.Millisecond)
	}

	// WhyNot: map へ読んで書き直さない — 鍵が字の順に並び替わり、つまみが先・集計が後という頁の並びが崩れる。
	var bench struct {
		Query   string            `json:"query"`
		Env     json.RawMessage   `json:"env"`
		Results []json.RawMessage `json:"results"`
	}
	var raw string
	err = page.Eval("JSON.stringify(window.__bench)", &raw)
	if err == nil {
		err = json.Unmarshal([]byte(raw), &bench)
	}
	if err != nil {
		fmt.Fprintf(errOut, "web-bench: 結果を読めない: %v\n", err)
		return 1
	}
	text, err := json.Marshal(struct {
		Chrome      string            `json:"chrome"`
		Viewport    string            `json:"viewport"`
		CPUThrottle float64           `json:"cpuThrottle"`
		Query       string            `json:"query"`
		Env         json.RawMessage   `json:"env"`
		Results     []json.RawMessage `json:"results"`
	}{page.Version, fmt.Sprintf("%dx%d", o.Width, o.Height), cpuRateOf(o.CPU), bench.Query, bench.Env, bench.Results})
	if err != nil {
		fmt.Fprintf(errOut, "web-bench: %v\n", err)
		return 1
	}
	if o.JSONL != "" {
		if err := appendWebBenchRows(o.JSONL, bench.Results); err != nil {
			fmt.Fprintf(errOut, "web-bench: %v\n", err)
			return 1
		}
	}
	if o.Out != "" {
		if err := os.MkdirAll(filepath.Dir(o.Out), 0o755); err != nil {
			fmt.Fprintf(errOut, "web-bench: %v\n", err)
			return 1
		}
		if err := os.WriteFile(o.Out, append(text, '\n'), 0o644); err != nil {
			fmt.Fprintf(errOut, "web-bench: %v\n", err)
			return 1
		}
	}
	fmt.Fprintln(out, string(text))
	return 0
}

// cpuRateOf は頁に掛けた CPU の倍率（絞らない時は 1）。
func cpuRateOf(rate float64) float64 {
	if rate > 1 {
		return rate
	}
	return 1
}

func appendWebBenchRows(path string, rows []json.RawMessage) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	for _, row := range rows {
		if _, err := f.Write(append(append([]byte{}, row...), '\n')); err != nil {
			f.Close()
			return err
		}
	}
	return f.Close()
}
