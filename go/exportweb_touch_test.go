package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func writeTouchGame(t *testing.T, keys string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "assets"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "assets", "game.keys.json"), []byte(keys), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

const touchKeys = `{"version": 1, "note": "x", "up": ["Up", "W"], "down": ["Down"], "left": ["Left"], "right": ["Right"],
  "confirm": ["Z", "Enter"], "cancel": ["Nope", "X"], "empty": []}`

func TestResolveWebTouchUsesFirstKeyOfAction(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "virtualPad": {"dpad": true, "buttons": [{"label": "A", "action": "confirm"}]}}`)
	got, err := resolveWebTouch(game, raw)
	if err != nil || got.VirtualPad.Buttons[0].Code != "KeyZ" {
		t.Errorf("confirm の 1 本目 Z は KeyZ のはず: %+v %v", got.VirtualPad, err)
	}
}

func TestResolveWebTouchMapsDpadToArrowCodes(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "virtualPad": {"dpad": true}}`)
	got, err := resolveWebTouch(game, raw)
	want := map[string]string{"up": "ArrowUp", "down": "ArrowDown", "left": "ArrowLeft", "right": "ArrowRight"}
	if err != nil || !mapsEqual(got.VirtualPad.Dpad, want) {
		t.Errorf("十字キーは矢印の code のはず: %v %v", got.VirtualPad, err)
	}
}

func TestResolveWebTouchSkipsUnknownKeyName(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "touchGestures": {"longPress": "cancel"}}`)
	got, err := resolveWebTouch(game, raw)
	if err != nil || got.TouchGestures["longPress"] != "KeyX" {
		t.Errorf("知らない Nope を飛ばして X のはず: %v %v", got.TouchGestures, err)
	}
}

func TestResolveWebTouchAvoidsKeySharedWithOtherAction(t *testing.T) {
	game := writeTouchGame(t, `{"back": ["Escape", "X"], "quit": ["Escape"]}`)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "touchGestures": {"longPress": "back"}}`)
	got, err := resolveWebTouch(game, raw)
	if err != nil || got.TouchGestures["longPress"] != "KeyX" {
		t.Errorf("quit と共有の Escape でなく X のはず: %v %v", got.TouchGestures, err)
	}
}

func TestResolveWebTouchFallsBackToSharedKey(t *testing.T) {
	game := writeTouchGame(t, `{"back": ["Escape"], "quit": ["Escape"]}`)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "touchGestures": {"longPress": "back"}}`)
	got, err := resolveWebTouch(game, raw)
	if err != nil || got.TouchGestures["longPress"] != "Escape" {
		t.Errorf("全部共有なら 1 本目の Escape のはず: %v %v", got.TouchGestures, err)
	}
}

func TestResolveWebTouchRejectsUnknownAction(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "virtualPad": {"buttons": [{"label": "A", "action": "jump"}]}}`)
	if _, err := resolveWebTouch(game, raw); err == nil {
		t.Error("keysDoc に無い操作は誤りのはず")
	}
}

func TestResolveWebTouchRejectsActionWithoutKnownKey(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "touchGestures": {"swipeLeft": "empty"}}`)
	if _, err := resolveWebTouch(game, raw); err == nil {
		t.Error("知っているキーが無い操作は誤りのはず")
	}
}

func TestResolveWebTouchRejectsUnknownGesture(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "touchGestures": {"pinch": "confirm"}}`)
	if _, err := resolveWebTouch(game, raw); err == nil {
		t.Error("知らないジェスチャーは誤りのはず")
	}
}

func TestResolveWebTouchResolvesVerticalSwipes(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "touchGestures": {"swipeUp": "confirm", "swipeDown": "confirm"}}`)
	got, err := resolveWebTouch(game, raw)
	want := map[string]string{"swipeUp": "KeyZ", "swipeDown": "KeyZ"}
	if err != nil || !mapsEqual(got.TouchGestures, want) {
		t.Errorf("上下の払いも操作のキーに解くはず: %v %v", got.TouchGestures, err)
	}
}

func TestResolveWebTouchRejectsUnknownOrientation(t *testing.T) {
	if _, err := resolveWebTouch(t.TempDir(), json.RawMessage(`{"orientation": "sideways"}`)); err == nil {
		t.Error("知らない向きは誤りのはず")
	}
}

func TestResolveWebTouchWithoutWebIsEmpty(t *testing.T) {
	got, err := resolveWebTouch(t.TempDir(), nil)
	if err != nil || got.VirtualPad != nil || got.TouchGestures != nil {
		t.Errorf("web が無ければ何も出さないはず: %+v %v", got, err)
	}
}

func TestResolveWebTouchStickOnlyNeedsNoKeysDoc(t *testing.T) {
	got, err := resolveWebTouch(t.TempDir(), json.RawMessage(`{"virtualPad": {"stick": true}}`))
	if err != nil || got.VirtualPad == nil || !got.VirtualPad.Stick {
		t.Errorf("スティックだけなら keysDoc 無しで出せるはず: %+v %v", got.VirtualPad, err)
	}
}

func TestResolveWebTouchStickWithButtons(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "virtualPad": {"stick": true, "buttons": [{"label": "A", "action": "confirm"}]}}`)
	got, err := resolveWebTouch(game, raw)
	if err != nil || !got.VirtualPad.Stick || got.VirtualPad.Buttons[0].Code != "KeyZ" {
		t.Errorf("スティックとボタンは一緒に出せるはず: %+v %v", got.VirtualPad, err)
	}
}

func TestResolveWebTouchRejectsStickWithDpad(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "virtualPad": {"dpad": true, "stick": true}}`)
	if _, err := resolveWebTouch(game, raw); err == nil {
		t.Error("dpad と stick は同じ左のゾーンなので誤りのはず")
	}
}

func TestResolveWebTouchReadsTemplates(t *testing.T) {
	root := filepath.Join("..", "templates")
	for _, game := range []string{"rpg-starter", "sound-novel-starter"} {
		pr, err := loadExportProject(filepath.Join(root, game))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := resolveWebTouch(filepath.Join(root, game), pr.Web); err != nil {
			t.Errorf("%s の web が解けるはず: %v", game, err)
		}
	}
}

// Flix の WebLayer.keyCode の表と Go の webKeyCode が、テンプレートのキーの Doc に出うる全部の名前で同じ code を返すか。
func TestWebKeyCodeMatchesWebLayer(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "engine_web", "src", "WebLayer.flix"))
	if err != nil {
		t.Fatal(err)
	}
	arms := map[string]string{}
	for _, m := range regexp.MustCompile(`case GameEngine\.Key\.(\w+)\s*=>\s*"([^"]+)"`).FindAllStringSubmatch(string(src), -1) {
		arms[m[1]] = m[2]
	}
	if len(arms) < 20 {
		t.Fatalf("WebLayer.keyCode の腕を読めない（%d 本）", len(arms))
	}
	flixCode := func(name string) string {
		if c, ok := arms[name]; ok {
			return c
		}
		if len(name) == 1 {
			return "Key" + name
		}
		return name
	}
	for _, schema := range []string{"rpg-starter/assets/keys.schema.json", "sound-novel-starter/assets/keys.schema.json"} {
		for _, name := range schemaKeyNames(t, filepath.Join("..", "templates", schema)) {
			got, ok := webKeyCode(name)
			if !ok || got != flixCode(name) {
				t.Errorf("%s: Go %q（%v）と Flix %q が違う", name, got, ok, flixCode(name))
			}
		}
	}
}

func schemaKeyNames(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	var walk func(v any)
	walk = func(v any) {
		switch x := v.(type) {
		case map[string]any:
			if e, ok := x["enum"].([]any); ok {
				for _, n := range e {
					if s, ok := n.(string); ok {
						seen[s] = true
					}
				}
			}
			for _, c := range x {
				walk(c)
			}
		case []any:
			for _, c := range x {
				walk(c)
			}
		}
	}
	var doc any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatal(err)
	}
	walk(doc)
	return sortedKeys(seen)
}

func TestResolveWebTouchAcceptsPortraitDesign(t *testing.T) {
	for _, c := range []string{
		`{"orientation": "any", "portraitDesign": {"width": 540, "minHeight": 960}}`,
		`{"portraitDesign": {"width": 300, "minHeight": 800}}`,
	} {
		if _, err := resolveWebTouch(t.TempDir(), json.RawMessage(c)); err != nil {
			t.Errorf("通るはず（maxHeight の既定は minHeight 以上になる）: %s %v", c, err)
		}
	}
}

func TestResolveWebTouchRejectsBadPortraitDesign(t *testing.T) {
	cases := []string{
		`{"portraitDesign": {"width": 0, "minHeight": 960}}`,
		`{"portraitDesign": {"width": 540}}`,
		`{"portraitDesign": {"width": 540, "minHeight": 960, "maxHeight": 959}}`,
		`{"portraitDesign": {"width": 540, "minHeight": 540}}`,
		`{"orientation": "landscape", "portraitDesign": {"width": 540, "minHeight": 960}}`,
	}
	for _, c := range cases {
		if _, err := resolveWebTouch(t.TempDir(), json.RawMessage(c)); err == nil {
			t.Errorf("止めるはず: %s", c)
		}
	}
}

func TestResolveWebTouchWithoutPlaceKeepsBundleBytes(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "virtualPad": {"stick": true, "buttons": [{"label": "A", "action": "confirm"}]}}`)
	got, err := resolveWebTouch(game, raw)
	if err != nil {
		t.Fatal(err)
	}
	out, _ := json.Marshal(got.VirtualPad)
	if string(out) != `{"stick":true,"buttons":[{"label":"A","code":"KeyZ"}]}` {
		t.Errorf("置き場所を書かなければ束のパッドは前と同じ形のはず: %s", out)
	}
}

const placedPad = `{"keysDoc": "assets/game.keys.json", "virtualPad": {
  "stick": {"size": 204, "anchor": "BottomLeft", "offset": {"x": 132, "y": 138}, "visible": false},
  "buttons": [{"label": "つかう", "action": "confirm", "size": 156, "anchor": "BottomRight", "offset": {"x": 108, "y": 138}}]}}`

func TestResolveWebTouchReadsStickPlace(t *testing.T) {
	got, err := resolveWebTouch(writeTouchGame(t, touchKeys), json.RawMessage(placedPad))
	want := webPadPlace{Anchor: "BottomLeft", X: 132, Y: 138, Size: 204, Visible: false}
	if err != nil || !got.VirtualPad.Stick || got.VirtualPad.StickPlace == nil || *got.VirtualPad.StickPlace != want {
		t.Errorf("スティックの置き場所は書いたとおりのはず: %+v %v", got.VirtualPad, err)
	}
}

func TestResolveWebTouchButtonPlaceIsVisibleByDefault(t *testing.T) {
	got, err := resolveWebTouch(writeTouchGame(t, touchKeys), json.RawMessage(placedPad))
	want := webPadPlace{Anchor: "BottomRight", X: 108, Y: 138, Size: 156, Visible: true}
	if err != nil || got.VirtualPad.Buttons[0].Place == nil || *got.VirtualPad.Buttons[0].Place != want {
		t.Errorf("visible を書かないボタンは見える置き場所のはず: %+v %v", got.VirtualPad, err)
	}
}

func TestResolveWebTouchRejectsBadPlace(t *testing.T) {
	game := writeTouchGame(t, touchKeys)
	cases := map[string]string{
		"anchor の名前":  `{"stick": {"size": 100, "anchor": "Bottom", "offset": {"x": 60, "y": 60}}}`,
		"size が 0":    `{"stick": {"size": 0, "anchor": "BottomLeft", "offset": {"x": 60, "y": 60}}}`,
		"offset が無い":  `{"stick": {"size": 100, "anchor": "BottomLeft"}}`,
		"offset が負":   `{"stick": {"size": 100, "anchor": "BottomLeft", "offset": {"x": -1, "y": 60}}}`,
		"空の {}":       `{"stick": {}}`,
		"visible だけ":  `{"stick": {"visible": false}}`,
		"置き場所の有無が混ざる": `{"stick": {"size": 100, "anchor": "BottomLeft", "offset": {"x": 60, "y": 60}}, "buttons": [{"label": "A", "action": "confirm"}]}`,
		"dpad と置き場所":  `{"dpad": true, "buttons": [{"label": "A", "action": "confirm", "size": 100, "anchor": "BottomRight", "offset": {"x": 60, "y": 60}}]}`,
	}
	for name, pad := range cases {
		raw := json.RawMessage(`{"keysDoc": "assets/game.keys.json", "virtualPad": ` + pad + `}`)
		if _, err := resolveWebTouch(game, raw); err == nil {
			t.Errorf("%s は誤りのはず", name)
		}
	}
}

func TestResolveWebTouchRejectsPlaceWithPortraitDesign(t *testing.T) {
	raw := json.RawMessage(`{"portraitDesign": {"width": 540, "minHeight": 960},
	  "virtualPad": {"stick": {"size": 100, "anchor": "BottomLeft", "offset": {"x": 60, "y": 60}}}}`)
	if _, err := resolveWebTouch(t.TempDir(), raw); err == nil {
		t.Error("置き場所は横の design の px なので portraitDesign と一緒は誤りのはず")
	}
}

func TestCheckPadPlacesFitRejectsCircleOutsideDesign(t *testing.T) {
	got, err := resolveWebTouch(writeTouchGame(t, touchKeys), json.RawMessage(placedPad))
	if err != nil {
		t.Fatal(err)
	}
	if err := checkPadPlacesFit(got.VirtualPad, 1560, 239); err == nil {
		t.Error("高さ 239 の design に中心 138・半径 102 の丸は収まらないはず")
	}
}

func TestCheckPadPlacesFitAcceptsCircleInsideDesign(t *testing.T) {
	got, err := resolveWebTouch(writeTouchGame(t, touchKeys), json.RawMessage(placedPad))
	if err != nil {
		t.Fatal(err)
	}
	if err := checkPadPlacesFit(got.VirtualPad, 1560, 720); err != nil {
		t.Errorf("1560×720 の design に収まる丸は通るはず: %v", err)
	}
}

func TestCheckPadPlacesFitNeedsDesign(t *testing.T) {
	got, err := resolveWebTouch(writeTouchGame(t, touchKeys), json.RawMessage(placedPad))
	if err != nil {
		t.Fatal(err)
	}
	if err := checkPadPlacesFit(got.VirtualPad, 0, 0); err == nil {
		t.Error("design の無い project の置き場所は誤りのはず")
	}
}

func mapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}
