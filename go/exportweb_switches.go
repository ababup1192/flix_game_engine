package main

import (
	"encoding/json"
	"fmt"
	"os"
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

// webPageReadsDev は頁の HTML（書き出しの index.html など）が window.fgeDev を読むか（頁の旗の読み手が埋まっているか）。読めなければ読む物とみる。
func webPageReadsDev(htmlPath string) bool {
	html, err := os.ReadFile(htmlPath)
	return err != nil || strings.Contains(string(html), "function fgePageSwitches(")
}

// webLegacyPageKeys は欄（window.fgeDev の名前）ごとの前の鍵（?fge= の前の頁が読む URL の鍵）。並びは URL に書く順。
// 頁の FGE_SWITCHES の legacy と Flix の App.DevTools.legacyPageQueryKeys（sw を除く）と同じ一覧（テストで突き合わせる）。
var webLegacyPageKeys = []struct{ Field, Key string }{
	{"fps", "fps"}, {"backend", "backend"}, {"net", "net"}, {"sw", "sw"}, {"input", "input"}, {"orientation", "orientation"},
	{"size", "size"}, {"glcheck", "glcheck"}, {"loadtime", "loadtime"}, {"capture", "capture"}, {"deferred", "deferred"},
	{"usedAssets", "usedAssets"}, {"webgpuFail", "webgpuFail"},
}

// legacyQuery は旗を前の鍵の URL のクエリ（? を除く）にする。前の鍵を持たない欄があれば誤り。
func (s webPageSwitches) legacyQuery() (string, error) {
	raw, err := json.Marshal(s)
	if err != nil {
		return "", err
	}
	fields := map[string]any{}
	if err := json.Unmarshal(raw, &fields); err != nil {
		return "", err
	}
	var q []string
	for _, k := range webLegacyPageKeys {
		v, ok := fields[k.Field]
		if !ok {
			continue
		}
		delete(fields, k.Field)
		switch t := v.(type) {
		case bool:
			q = append(q, k.Key+"="+map[bool]string{true: "1", false: "0"}[t])
		case float64:
			q = append(q, k.Key+"="+strconv.Itoa(int(t)))
		default:
			q = append(q, k.Key+"="+fmt.Sprint(t))
		}
	}
	for f := range fields {
		return "", fmt.Errorf("頁の旗 %s は前の engine の頁へ渡す鍵が無い", f)
	}
	return strings.Join(q, "&"), nil
}

// openURL は道具が頁 htmlPath を base で開く URL と、頁より先に流す script。頁が window.fgeDev を読まなければ（前の engine の書き出し）、
// 旗を前の鍵の URL のクエリにする（前の鍵の無い旗があれば誤り）。
// WhyNot: 前の engine の書き出しにも fgeDev だけを渡さない — bin/fge は engine の根の物で、ゲームの engine が前の版のことがある。
// 前の頁は fgeDev を知らず、撮る旗が届かないまま「押して始める」で止まり、上限の秒まで待って書き出しが落ちる。
func (s webPageSwitches) openURL(base, htmlPath string) (url, initScript string, err error) {
	if webPageReadsDev(htmlPath) {
		return base, s.initScript(), nil
	}
	q, err := s.legacyQuery()
	if err != nil || q == "" {
		return base, "", err
	}
	sep := "?"
	if strings.Contains(base, "?") {
		sep = "&"
	}
	return base + sep + q, "", nil
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
		if value != "0" {
			return false
		}
		off := false
		s.Sw = &off
		return true
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
