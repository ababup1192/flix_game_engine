package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// webPageSwitches は道具が開く頁に入れる頁の旗（window.fgeDev）。欄と値は engine_web/js/fge-switches.js の FGE_SWITCHES と同じ
// （docs/web-capture.md の「頁の旗」）。既定の値の欄は JSON に出さない。
// WhyNot: 道具の旗を URL のクエリで渡さない — WebLayer.devTools のゲームはクエリを Start の名前と引数に読むので、旗を足すたびに混ざる。
// WhyNot: 字（"capture:6,usedassets"）のまま渡さない — 欄の名前の打ち間違いを Go の型で止められない。
type webPageSwitches struct {
	Fps         bool   `json:"fps,omitempty"`
	Backend     string `json:"backend,omitempty"`
	Net         string `json:"net,omitempty"`
	Sw          *bool  `json:"sw,omitempty"`
	Input       string `json:"input,omitempty"`
	Orientation string `json:"orientation,omitempty"`
	Size        string `json:"size,omitempty"`
	Glcheck     bool   `json:"glcheck,omitempty"`
	Loadtime    bool   `json:"loadtime,omitempty"`
	Capture     int    `json:"capture,omitempty"`
	Deferred    string `json:"deferred,omitempty"`
	UsedAssets  bool   `json:"usedAssets,omitempty"`
	WebgpuFail  string `json:"webgpuFail,omitempty"`
}

// initScript は頁のどの script より先に流す、window.fgeDev を置く script。
// WhyNot: 前に置かれた window.fgeDev を消さない — 同じ頁に 2 つの道具が旗を足す時（web-capture の --dev と自前の InitScript）に、後の物が前の物を消す。
func (s webPageSwitches) initScript() string {
	raw, err := json.Marshal(s)
	if err != nil {
		panic(err)
	}
	return "window.fgeDev = Object.assign(window.fgeDev || {}, " + string(raw) + ");"
}

// webPageReadsDev は書き出し先 out の頁が window.fgeDev を読むか（index.html に頁の旗の読み手が埋まっているか）。
func webPageReadsDev(out string) bool {
	html, err := os.ReadFile(filepath.Join(out, "index.html"))
	return err != nil || strings.Contains(string(html), "function fgePageSwitches(")
}

// openURL は道具が書き出しの頁を開く URL と、頁より先に流す script。頁が window.fgeDev を読まなければ（前の engine の書き出し）、
// 道具が使う旗だけを前の鍵の URL のクエリにする。
// WhyNot: 前の engine の書き出しにも fgeDev だけを渡さない — bin/fge は engine の根の物で、ゲームの engine が前の版のことがある。
// 前の頁は fgeDev を知らず、撮る旗が届かないまま「押して始める」で止まり、上限の秒まで待って書き出しが落ちる。
func (s webPageSwitches) openURL(base, out string) (url, initScript string) {
	if webPageReadsDev(out) {
		return base, s.initScript()
	}
	var q []string
	if s.Capture > 0 {
		q = append(q, "capture="+strconv.Itoa(s.Capture))
	}
	if s.UsedAssets {
		q = append(q, "usedAssets=1")
	}
	if s.Backend != "" {
		q = append(q, "backend="+s.Backend)
	}
	if s.Net != "" {
		q = append(q, "net="+s.Net)
	}
	if s.Deferred != "" {
		q = append(q, "deferred="+s.Deferred)
	}
	if len(q) == 0 {
		return base, ""
	}
	return base + "?" + strings.Join(q, "&"), ""
}

// parseWebDevWords は ?fge= と同じ字の決まり（<語>,<語>,…・語は 名前 か 名前:値 か短い書き方）を頁の旗にする（web-capture の --dev）。
// WhyNot: 知らない語を捨てて続けない — 頁は甘く読むが、道具の打ち間違いはその場で止めないと、旗の効かない絵を撮って気づかない。
func parseWebDevWords(words string) (webPageSwitches, error) {
	var s webPageSwitches
	for _, raw := range strings.Split(words, ",") {
		w := strings.ToLower(strings.TrimSpace(raw))
		if w == "" {
			continue
		}
		if !s.applyWord(w) {
			return webPageSwitches{}, fmt.Errorf("頁の旗の知らない語 %q（使える語は docs/web-capture.md の「頁の旗」）", strings.TrimSpace(raw))
		}
	}
	return s, nil
}

// applyWord は小文字の 1 語を s に当てる（知らない語・読めない値は偽）。
func (s *webPageSwitches) applyWord(w string) bool {
	name, value, hasValue := strings.Cut(w, ":")
	if !hasValue {
		return s.applyBare(w)
	}
	pick := func(dst *string, allowed ...string) bool {
		for _, a := range allowed {
			if value == a {
				*dst = a
				return true
			}
		}
		return false
	}
	switch name {
	case "backend":
		return s.applyBackend(value)
	case "net":
		return pick(&s.Net, "4g")
	case "sw":
		off := false
		s.Sw = &off
		return value == "0"
	case "input":
		return pick(&s.Input, "touch", "mouse")
	case "orientation":
		return pick(&s.Orientation, "portrait", "landscape")
	case "size":
		return pick(&s.Size, "small", "medium", "large")
	case "capture":
		n, err := strconv.Atoi(value)
		s.Capture = n
		return err == nil && n > 0 && strings.Trim(value, "0123456789") == ""
	case "deferred":
		return pick(&s.Deferred, "all")
	case "webgpufail":
		return pick(&s.WebgpuFail, "prepare", "canvas")
	}
	return false
}

// applyBare は値の無い語（真偽の旗の名前か、値だけを書く短い書き方）を当てる。
func (s *webPageSwitches) applyBare(w string) bool {
	switch w {
	case "fps":
		s.Fps = true
	case "glcheck":
		s.Glcheck = true
	case "loadtime":
		s.Loadtime = true
	case "usedassets":
		s.UsedAssets = true
	case "webgl2", "gl", "webgpu":
		return s.applyBackend(w)
	case "4g":
		s.Net = w
	case "nosw":
		off := false
		s.Sw = &off
	case "touch", "mouse":
		s.Input = w
	case "portrait", "landscape":
		s.Orientation = w
	case "small", "medium", "large":
		s.Size = w
	default:
		return false
	}
	return true
}

// applyBackend は描き手の語を当てる。webgpu は既定（欄を空にする）。
func (s *webPageSwitches) applyBackend(v string) bool {
	switch v {
	case "webgl2", "gl":
		s.Backend = "webgl2"
	case "webgpu":
		s.Backend = ""
	default:
		return false
	}
	return true
}
