package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

const webPerfUsage = "使い方: fge web-perf <書き出したフォルダ|URL> [--query <a=1&b=2>] [--size WxH] [--cpu <倍>] [--settle <秒>] [--sample <秒>] [--uncapped] [--pagejs <式>] [--profile <file.cpuprofile>] [--top <数>] [--out <file>]\n" +
	"  書き出したゲーム（bin/fge export-web）か頁の URL をヘッドレスの Chrome で開き、settle 秒の後 sample 秒のあいだの\n" +
	"  rAF の間隔と rAF の中の CPU（中央値・p95・p99）を JSON で出す。ゲームの頁でもベンチの頁でもよい（window.__bench は要らない）\n" +
	"  --profile は sample の間の CPU プロファイル（Chrome の DevTools で開ける形）を書き、自分の時間の多い関数を --top 個（既定 30）出す\n" +
	"  --uncapped は vsync と fps の上限を外す・--pagejs は測り終えた時に頁で評価する式（結果は page に入る）。知らせるだけの測り（門ではない）"

func init() {
	register("web-perf",
		"書き出したゲームの頁を開き、rAF の間隔と rAF の中の CPU と CPU プロファイルを取る（固定費の測り・知らせるだけ）",
		func(out, errOut *strings.Builder, rest []string, _ bool) int {
			return cmdWebPerf(out, errOut, rest)
		})
}

type webPerfOptions struct {
	Target, Query, PageJS, Profile, Out string
	Width, Height, Top           int
	CPU                          float64
	Settle, Sample               time.Duration
	Uncapped                     bool
}

func parseWebPerfArgs(args []string) (webPerfOptions, error) {
	o := webPerfOptions{Width: 1280, Height: 720, Top: 30, Settle: 30 * time.Second, Sample: 10 * time.Second}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--uncapped" {
			o.Uncapped = true
			continue
		}
		switch a {
		case "--query", "--size", "--cpu", "--settle", "--sample", "--pagejs", "--profile", "--top", "--out":
			if i+1 >= len(args) {
				return o, fmt.Errorf("%s の値がありません", a)
			}
			v := args[i+1]
			i++
			switch a {
			case "--query":
				o.Query = strings.TrimPrefix(v, "?")
			case "--size":
				w, h, ok := parseSize(v)
				if !ok {
					return o, fmt.Errorf("--size は WxH (例 1280x720): %q", v)
				}
				o.Width, o.Height = w, h
			case "--cpu":
				rate, err := strconv.ParseFloat(v, 64)
				if err != nil || rate <= 0 {
					return o, fmt.Errorf("--cpu は正の倍数: %q", v)
				}
				o.CPU = rate
			case "--settle", "--sample":
				sec, err := strconv.ParseFloat(v, 64)
				if err != nil || sec <= 0 {
					return o, fmt.Errorf("%s は正の秒数: %q", a, v)
				}
				d := time.Duration(sec * float64(time.Second))
				if a == "--settle" {
					o.Settle = d
				} else {
					o.Sample = d
				}
			case "--top":
				n, err := strconv.Atoi(v)
				if err != nil || n < 0 {
					return o, fmt.Errorf("--top は 0 以上の数: %q", v)
				}
				o.Top = n
			case "--pagejs":
				o.PageJS = v
			case "--profile":
				o.Profile = v
			case "--out":
				o.Out = v
			}
		default:
			if strings.HasPrefix(a, "--") {
				return o, fmt.Errorf("知らない旗: %s", a)
			}
			if o.Target != "" {
				return o, fmt.Errorf("開く物は 1 つだけ: %s と %s", o.Target, a)
			}
			o.Target = a
		}
	}
	if o.Target == "" {
		return o, fmt.Errorf("書き出したフォルダか URL がありません")
	}
	return o, nil
}

// webPerfHook は rAF の callback を包み、測っている間だけ rAF の時刻ごとに callback の中の時間を足す（同じコマに callback が複数あっても 1 コマにまとまる）。
const webPerfHook = `(()=>{const raf=window.requestAnimationFrame.bind(window);window.__fgePerfRaf=raf;const P=window.__fgePerfCpu={on:false,cur:new Map()};
window.requestAnimationFrame=function(cb){return raf(function(ts){const a=performance.now();try{cb(ts)}finally{if(P.on){P.cur.set(ts,(P.cur.get(ts)||0)+performance.now()-a)}}})};})()`

const webPerfSample = `new Promise(res=>{const R=window.__fgePerfRaf||requestAnimationFrame;const P=window.__fgePerfCpu;if(P){P.cur.clear();P.on=true}const t=[];const end=performance.now()+%d;
function f(ts){t.push(ts);if(ts<end)R(f);else{if(P)P.on=false;const c=P?[...P.cur.values()].sort((a,b)=>a-b):[];const d=[];for(let i=1;i<t.length;i++)d.push(t[i]-t[i-1]);d.sort((a,b)=>a-b);
const q=(xs,p)=>xs.length?xs[Math.min(xs.length-1,Math.floor(p*xs.length))]:null;const over=x=>d.filter(v=>v>x).length;
res({frames:d.length,intervalMedian:q(d,0.5),intervalP95:q(d,0.95),intervalP99:q(d,0.99),intervalMax:d.length?d[d.length-1]:null,over10ms:over(10),over16ms:over(17.5),
cpuFrames:c.length,cpuMedian:q(c,0.5),cpuP95:q(c,0.95),cpuP99:q(c,0.99),cpuMean:c.length?c.reduce((a,b)=>a+b,0)/c.length:null})}}R(f)})`

// webPerfBoot は起動画面（押すまで待つ頁）が残っているか。
const webPerfBoot = `(() => { const b = document.getElementById("fge-boot"); return !!(b && b.style.display !== "none"); })()`

type cpuProfile struct {
	Nodes []struct {
		ID        int `json:"id"`
		CallFrame struct {
			FunctionName string `json:"functionName"`
			URL          string `json:"url"`
		} `json:"callFrame"`
	} `json:"nodes"`
	StartTime  float64 `json:"startTime"`
	EndTime    float64 `json:"endTime"`
	Samples    []int   `json:"samples"`
	TimeDeltas []int   `json:"timeDeltas"`
}

type selfTime struct {
	Name  string  `json:"name"`
	Ms    float64 `json:"ms"`
	Share float64 `json:"share"`
}

// readWasmNames は TeaVM が wasm の隣に書く classes.names（wasm の name の区画の関数の名前の部分と同じ形: 区画の番号 1・長さ・個数・(番号, 名前) の並び）を読む。
// 無い・読めない時は空（プロファイルの関数は wasm-function[番号] のまま出る）。
func readWasmNames(path string) map[int]string {
	data, err := os.ReadFile(path)
	names := map[int]string{}
	if err != nil {
		return names
	}
	at := 0
	uleb := func() (int, bool) {
		v, shift := 0, 0
		for at < len(data) {
			b := data[at]
			at++
			v |= int(b&0x7f) << shift
			if b&0x80 == 0 {
				return v, true
			}
			shift += 7
		}
		return 0, false
	}
	for at < len(data) {
		id := data[at]
		at++
		size, ok := uleb()
		if !ok {
			return names
		}
		end := at + size
		if id != 1 || end > len(data) {
			at = end
			continue
		}
		count, _ := uleb()
		for i := 0; i < count && at < end; i++ {
			idx, ok1 := uleb()
			n, ok2 := uleb()
			if !ok1 || !ok2 || at+n > end {
				return names
			}
			names[idx] = string(data[at : at+n])
			at += n
		}
		at = end
	}
	return names
}

// wasmNameOf は wasm-function[番号] を names の名前へ替える（無ければそのまま）。
func wasmNameOf(names map[int]string, name string) string {
	if !strings.HasPrefix(name, "wasm-function[") || !strings.HasSuffix(name, "]") {
		return name
	}
	idx, err := strconv.Atoi(name[len("wasm-function[") : len(name)-1])
	if err != nil {
		return name
	}
	if n, ok := names[idx]; ok {
		return n
	}
	return name
}

// topSelfTimes は関数ごとの自分の時間（標本の間の時間を次の標本の関数へ付ける）を多い順に返す。idle と program は数えない。
func topSelfTimes(p cpuProfile, wasmNames map[int]string, top int) ([]selfTime, float64) {
	names := map[int]string{}
	for _, n := range p.Nodes {
		name := n.CallFrame.FunctionName
		if name == "" {
			name = "(anonymous " + filepath.Base(n.CallFrame.URL) + ")"
		}
		names[n.ID] = wasmNameOf(wasmNames, name)
	}
	byName := map[string]float64{}
	total := 0.0
	for i, id := range p.Samples {
		if i+1 >= len(p.TimeDeltas) {
			break
		}
		name := names[id]
		if name == "(idle)" || name == "(program)" {
			continue
		}
		ms := float64(p.TimeDeltas[i+1]) / 1000
		byName[name] += ms
		total += ms
	}
	rows := make([]selfTime, 0, len(byName))
	for n, ms := range byName {
		rows = append(rows, selfTime{n, ms, 0})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Ms > rows[j].Ms })
	if len(rows) > top {
		rows = rows[:top]
	}
	for i := range rows {
		if total > 0 {
			rows[i].Share = rows[i].Ms / total
		}
	}
	return rows, total
}

func cmdWebPerf(out, errOut *strings.Builder, args []string) int {
	o, err := parseWebPerfArgs(args)
	if err != nil {
		fmt.Fprintf(errOut, "web-perf: %v\n%s\n", err, webPerfUsage)
		return 2
	}
	url := o.Target
	if !strings.HasPrefix(url, "http://") && !strings.HasPrefix(url, "https://") {
		if _, err := os.Stat(filepath.Join(o.Target, "index.html")); err != nil {
			fmt.Fprintf(errOut, "web-perf: %s に index.html が無い。\n  次: bin/fge export-web <ゲーム> で書き出す\n", o.Target)
			return 2
		}
		listener, closeServer, err := serveLocalDir(o.Target)
		if err != nil {
			fmt.Fprintf(errOut, "web-perf: 配る口を開けない: %v\n", err)
			return 1
		}
		defer closeServer()
		url = "http://" + listener.Addr().String() + "/index.html"
	}
	if o.Query != "" {
		sep := "?"
		if strings.Contains(url, "?") {
			sep = "&"
		}
		url += sep + o.Query
	}
	var extra []string
	if o.Uncapped {
		extra = []string{"--disable-gpu-vsync", "--disable-frame-rate-limit"}
	}
	page, err := cdp.OpenPage(cdp.PageOptions{Width: o.Width, Height: o.Height, CPUThrottle: o.CPU, InitScript: webPerfHook, ExtraArgs: extra})
	if err != nil {
		fmt.Fprintf(errOut, "web-perf: %v\n", err)
		return 1
	}
	defer page.Close()
	start := time.Now()
	if err := page.Navigate(url); err != nil {
		fmt.Fprintf(errOut, "web-perf: %v\n", err)
		return 1
	}
	for time.Since(start) < o.Settle {
		var booting bool
		// 起動画面は押すまで待つので、消えるまでキーを送り続ける（頁が聞き始める前の押しは届かない）。
		if page.Eval(webPerfBoot, &booting) == nil && booting {
			_ = page.PressKey("Enter", 0)
		}
		time.Sleep(250 * time.Millisecond)
	}
	if o.Profile != "" {
		for _, step := range []struct {
			m string
			p any
		}{{"Profiler.enable", nil}, {"Profiler.setSamplingInterval", map[string]any{"interval": 100}}, {"Profiler.start", nil}} {
			if _, err := page.Call(step.m, step.p, 10*time.Second); err != nil {
				fmt.Fprintf(errOut, "web-perf: %v\n", err)
				return 1
			}
		}
	}
	var raf json.RawMessage
	if err := page.EvalFor(fmt.Sprintf(webPerfSample, o.Sample.Milliseconds()), &raf, o.Sample+30*time.Second); err != nil {
		fmt.Fprintf(errOut, "web-perf: rAF を測れない: %v\n", err)
		return 1
	}
	var top []selfTime
	profiledMs := 0.0
	if o.Profile != "" {
		raw, err := page.Call("Profiler.stop", nil, 60*time.Second)
		if err != nil {
			fmt.Fprintf(errOut, "web-perf: %v\n", err)
			return 1
		}
		var res struct {
			Profile json.RawMessage `json:"profile"`
		}
		var prof cpuProfile
		if err := json.Unmarshal(raw, &res); err == nil {
			err = json.Unmarshal(res.Profile, &prof)
		}
		if err != nil {
			fmt.Fprintf(errOut, "web-perf: プロファイルを読めない: %v\n", err)
			return 1
		}
		if err := writeFileMkdir(o.Profile, res.Profile); err != nil {
			fmt.Fprintf(errOut, "web-perf: %v\n", err)
			return 1
		}
		top, profiledMs = topSelfTimes(prof, readWasmNames(filepath.Join(o.Target, "classes.names")), o.Top)
	}
	var pageVal json.RawMessage
	if o.PageJS != "" {
		if err := page.Eval(o.PageJS, &pageVal); err != nil {
			fmt.Fprintf(errOut, "web-perf: --pagejs が失敗した: %v\n", err)
		}
	}
	text, err := json.MarshalIndent(struct {
		URL        string          `json:"url"`
		Chrome     string          `json:"chrome"`
		Viewport   string          `json:"viewport"`
		CPU        float64         `json:"cpuThrottle"`
		Uncapped   bool            `json:"uncapped"`
		Raf        json.RawMessage `json:"raf"`
		Page       json.RawMessage `json:"page,omitempty"`
		ProfiledMs float64         `json:"profiledBusyMs,omitempty"`
		Top        []selfTime      `json:"selfTop,omitempty"`
	}{url, page.Version, fmt.Sprintf("%dx%d", o.Width, o.Height), cpuRateOf(o.CPU), o.Uncapped, raf, pageVal, profiledMs, top}, "", " ")
	if err != nil {
		fmt.Fprintf(errOut, "web-perf: %v\n", err)
		return 1
	}
	if o.Out != "" {
		if err := writeFileMkdir(o.Out, append(text, '\n')); err != nil {
			fmt.Fprintf(errOut, "web-perf: %v\n", err)
			return 1
		}
	}
	fmt.Fprintln(out, string(text))
	return 0
}

func writeFileMkdir(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
