package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// project.json の web 欄（ブラウザ版だけが読む）。操作の名前は keysDoc（ゲームのキーの割り当ての Doc）の操作の名前。
type exportWebSettings struct {
	KeysDoc       string            `json:"keysDoc"`
	VirtualPad    *exportVirtualPad `json:"virtualPad"`
	TouchGestures map[string]string `json:"touchGestures"`
	Orientation   string            `json:"orientation"`
}

type exportVirtualPad struct {
	Dpad    json.RawMessage `json:"dpad"`
	Buttons []struct {
		Label  string `json:"label"`
		Action string `json:"action"`
	} `json:"buttons"`
}

// bundle.json に書く形。キーは KeyboardEvent.code に解いてある（頁の JS は code だけを扱う）。
type webVirtualPad struct {
	Dpad    map[string]string `json:"dpad,omitempty"`
	Buttons []webPadButton    `json:"buttons"`
}

type webPadButton struct {
	Label string `json:"label"`
	Code  string `json:"code"`
}

type webDesign struct {
	W int `json:"w"`
	H int `json:"h"`
}

type webTouch struct {
	VirtualPad    *webVirtualPad
	TouchGestures map[string]string
	Orientation   string
}

var webDpadDirs = []string{"up", "down", "left", "right"}
var webGestureNames = map[string]bool{"longPress": true, "swipeLeft": true, "swipeRight": true}
var webOrientations = map[string]bool{"": true, "any": true, "landscape": true, "portrait": true}

// webKeyCodes は GameEngine.Key の名前のうち、KeyboardEvent.code が名前と違う物（engine_web/src/WebLayer.flix の keyCode と同じ表）。
// 1 字の名前は "Key" + 字、ほかの名前（Digit0・F1・Numpad0 など）はそのまま code になる。
var webKeyCodes = map[string]string{
	"Up": "ArrowUp", "Down": "ArrowDown", "Left": "ArrowLeft", "Right": "ArrowRight",
	"Enter": "Enter", "Space": "Space", "Escape": "Escape", "Tab": "Tab", "Backspace": "Backspace",
	"Insert": "Insert", "Delete": "Delete", "PageUp": "PageUp", "PageDown": "PageDown", "Home": "Home", "End": "End",
	"CapsLock": "CapsLock", "Apostrophe": "Quote", "Comma": "Comma", "Minus": "Minus", "Period": "Period",
	"Slash": "Slash", "Semicolon": "Semicolon", "Equal": "Equal", "LeftBracket": "BracketLeft",
	"Backslash": "Backslash", "RightBracket": "BracketRight", "GraveAccent": "Backquote",
	"LeftShift": "ShiftLeft", "LeftCtrl": "ControlLeft", "LeftAlt": "AltLeft", "LeftSuper": "MetaLeft",
	"RightShift": "ShiftRight", "RightCtrl": "ControlRight", "RightAlt": "AltRight", "RightSuper": "MetaRight",
	"Menu": "ContextMenu", "NumpadDecimal": "NumpadDecimal", "NumpadDivide": "NumpadDivide",
	"NumpadMultiply": "NumpadMultiply", "NumpadSubtract": "NumpadSubtract", "NumpadAdd": "NumpadAdd",
	"NumpadEnter": "NumpadEnter", "NumpadEqual": "NumpadEqual",
}

var webNamedKeyRe = regexp.MustCompile(`^(?:[A-Z]|Digit[0-9]|Numpad[0-9]|F(?:[1-9]|1[0-9]|2[0-5]))$`)

// webKeyCode は GameEngine.Key の名前を KeyboardEvent.code へ。知らない名前は false（KeysDoc と同じく、その 1 個を飛ばす）。
func webKeyCode(name string) (string, bool) {
	if code, ok := webKeyCodes[name]; ok {
		return code, true
	}
	if !webNamedKeyRe.MatchString(name) {
		return "", false
	}
	if len(name) == 1 {
		return "Key" + name, true
	}
	return name, true
}

// resolveWebTouch は project.json の web 欄を読み、操作の名前を keysDoc の 1 本目の知っているキーの code へ解く。
// web 欄が無ければ空（パッドもジェスチャーも出さない）。
func resolveWebTouch(game string, raw json.RawMessage) (webTouch, error) {
	var t webTouch
	if len(raw) == 0 || string(raw) == "null" {
		return t, nil
	}
	var s exportWebSettings
	if err := json.Unmarshal(raw, &s); err != nil {
		return t, fmt.Errorf("project.json の web を読めない: %v\n  次: web の形を直す（keysDoc・virtualPad・touchGestures・orientation）", err)
	}
	if !webOrientations[s.Orientation] {
		return t, fmt.Errorf("project.json の web.orientation が %q。\n  次: landscape・portrait・any のどれかにする", s.Orientation)
	}
	t.Orientation = s.Orientation
	if s.VirtualPad == nil && len(s.TouchGestures) == 0 {
		return t, nil
	}
	actions, err := loadWebKeysDoc(game, s.KeysDoc)
	if err != nil {
		return t, err
	}
	codeOf := func(field, action string) (string, error) {
		keys, ok := actions[action]
		if !ok {
			return "", fmt.Errorf("project.json の %s の操作 %q が %s に無い。\n  次: %s にある操作の名前（%s）にする",
				field, action, s.KeysDoc, s.KeysDoc, strings.Join(sortedKeys(actions), "・"))
		}
		for _, k := range keys {
			if code, ok := webKeyCode(k); ok {
				return code, nil
			}
		}
		return "", fmt.Errorf("%s の操作 %q に知っているキーが無い（%v）。\n  次: GameEngine.Key の名前（Z・Up・Enter など）を 1 つ入れる",
			s.KeysDoc, action, keys)
	}
	if s.VirtualPad != nil {
		pad := &webVirtualPad{Buttons: []webPadButton{}}
		dpad, err := webDpadActions(s.VirtualPad.Dpad)
		if err != nil {
			return t, err
		}
		if dpad != nil {
			pad.Dpad = map[string]string{}
			for _, dir := range webDpadDirs {
				code, err := codeOf("web.virtualPad.dpad."+dir, dpad[dir])
				if err != nil {
					return t, err
				}
				pad.Dpad[dir] = code
			}
		}
		if len(s.VirtualPad.Buttons) > 4 {
			return t, fmt.Errorf("project.json の web.virtualPad.buttons が %d 個。\n  次: 4 個までにする（指で押し分けられる数）", len(s.VirtualPad.Buttons))
		}
		for i, b := range s.VirtualPad.Buttons {
			code, err := codeOf(fmt.Sprintf("web.virtualPad.buttons[%d]", i), b.Action)
			if err != nil {
				return t, err
			}
			pad.Buttons = append(pad.Buttons, webPadButton{Label: b.Label, Code: code})
		}
		t.VirtualPad = pad
	}
	if len(s.TouchGestures) > 0 {
		t.TouchGestures = map[string]string{}
		for _, name := range sortedKeys(s.TouchGestures) {
			if !webGestureNames[name] {
				return t, fmt.Errorf("project.json の web.touchGestures の %q を知らない。\n  次: longPress・swipeLeft・swipeRight のどれかにする", name)
			}
			code, err := codeOf("web.touchGestures."+name, s.TouchGestures[name])
			if err != nil {
				return t, err
			}
			t.TouchGestures[name] = code
		}
	}
	return t, nil
}

// webDpadActions は dpad の欄を読む。true = up・down・left・right の操作・false か無し = 十字キーを出さない・{up: …} = 名指し。
func webDpadActions(raw json.RawMessage) (map[string]string, error) {
	if len(raw) == 0 || string(raw) == "null" || string(raw) == "false" {
		return nil, nil
	}
	if string(raw) == "true" {
		return map[string]string{"up": "up", "down": "down", "left": "left", "right": "right"}, nil
	}
	var m map[string]string
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("project.json の web.virtualPad.dpad を読めない: %v\n  次: true か {\"up\": \"<操作>\", …} にする", err)
	}
	for _, dir := range webDpadDirs {
		if m[dir] == "" {
			return nil, fmt.Errorf("project.json の web.virtualPad.dpad に %s が無い。\n  次: up・down・left・right の 4 つを書く", dir)
		}
	}
	return m, nil
}

// loadWebKeysDoc は keysDoc（操作の名前 → キーの名前の列）を読む。文字列の列でない欄（version・note など）は飛ばす。
func loadWebKeysDoc(game, rel string) (map[string][]string, error) {
	if rel == "" {
		return nil, fmt.Errorf("project.json の web.keysDoc が無い。\n  次: キーの割り当ての Doc（例 assets/rpg.keys.json）を書く")
	}
	clean, err := checkAssetPath(game, rel, "web.keysDoc")
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(filepath.Join(game, filepath.FromSlash(path.Clean(clean))))
	if err != nil {
		return nil, fmt.Errorf("web.keysDoc の %s を読めない: %v", rel, err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return nil, fmt.Errorf("web.keysDoc の %s を読めない: %v", rel, err)
	}
	actions := map[string][]string{}
	for name, v := range fields {
		var keys []string
		if json.Unmarshal(v, &keys) == nil {
			actions[name] = keys
		}
	}
	return actions, nil
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
