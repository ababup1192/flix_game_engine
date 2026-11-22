package main

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// 頁の canvas の指の扱い（fge-web.js の fgeGesture*）を、本物の fge-web.js を読んだ頁で確かめる。
// 起動（fgeBoot）は load の捕捉で止め、canvas の指の配線（fgeWireInput）だけを掛ける。canvas は CSS px と画素を 1:1 にする。
const fingersPage = `<!DOCTYPE html><html><head><style>body{margin:0}#fge-canvas{position:fixed;left:0;top:0;width:400px;height:300px}
#pad{position:fixed;left:0;top:300px;width:400px;height:100px}</style>
<script>addEventListener("load", function (e) {
  e.stopImmediatePropagation();
  fgeCanvas = document.getElementById("fge-canvas");
  fgeWireInput();
  window.fgeFingersReady = true;
}, true);</script>
<script src="fge-switches.js"></script><script src="fge-web.js"></script></head>
<body><canvas id="fge-canvas" width="400" height="300"></canvas><div id="pad"></div>
<script>
// pointer の event を作って送る（down は canvas か pad、move と up は canvas から window へ浮かぶ）。
function finger(type, id, x, y, primary, on) {
  var el = on === "pad" ? document.getElementById("pad") : fgeCanvas;
  el.dispatchEvent(new PointerEvent(type, { pointerId: id, pointerType: "touch", isPrimary: !!primary, clientX: x, clientY: y, bubbles: true, cancelable: true }));
}
function resetFingers() {
  fgeTouchForget();
  fgeBeginFrame(); fgeBeginFrame();
  fgePointer.buttons = [false, false, false];
  fgePointer.wheel = 0;
  fgeWeb.touchGestures = null;
  fgeLatch = Object.create(null);
}
function frame() {
  fgeBeginFrame();
  return { click: fgePointer.frameLatch[0], down: fgePointerDown(0), x: fgePointer.x, y: fgePointer.y };
}
</script></body></html>`

type fingerFrame struct {
	Click bool    `json:"click"`
	Down  bool    `json:"down"`
	X     float64 `json:"x"`
	Y     float64 `json:"y"`
}

func openFingersPage(t *testing.T, opt cdp.PageOptions) *cdp.Page {
	t.Helper()
	skipWithoutChrome(t)
	dir := t.TempDir()
	for _, name := range []string{"fge-web.js", webSwitchesSource} {
		src, err := os.ReadFile(filepath.Join("..", "engine_web", "js", name))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), src, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(fingersPage), 0o644); err != nil {
		t.Fatal(err)
	}
	ln, closeServer, err := serveWebCheck(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(closeServer)
	page, err := cdp.OpenPage(opt)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(page.Close)
	if err := page.Navigate(fmt.Sprintf("http://%s/index.html", ln.Addr().String())); err != nil {
		t.Fatal(err)
	}
	if err := page.WaitFor(`window.fgeFingersReady === true`, 10*time.Second); err != nil {
		t.Fatal(err)
	}
	return page
}

// fingerScenario は指の動きを流した後の式の値を読む（resetFingers の後に script を流す）。
func fingerScenario(t *testing.T, page *cdp.Page, script string, out any) {
	t.Helper()
	if err := page.Eval("(async () => { resetFingers(); "+script+" })()", out); err != nil {
		t.Fatal(err)
	}
}

func TestCanvasFingers(t *testing.T) {
	page := openFingersPage(t, cdp.PageOptions{Width: 400, Height: 400})
	frames := func(t *testing.T, script string) []fingerFrame {
		var got []fingerFrame
		fingerScenario(t, page, script, &got)
		return got
	}
	t.Run("パッドに置いた主な指とは別の canvas の指のタップがクリックになる", func(t *testing.T) {
		got := frames(t, `finger("pointerdown", 1, 50, 350, true, "pad");
		  finger("pointerdown", 2, 120, 80); finger("pointerup", 2, 121, 81); return [frame()];`)
		if !got[0].Click || got[0].X != 120 || got[0].Y != 80 {
			t.Errorf("(120,80) のクリックのはず: %+v", got[0])
		}
	})
	t.Run("同じコマに来た 2 本のタップは次のコマへ 1 つずつ出る", func(t *testing.T) {
		got := frames(t, `finger("pointerdown", 1, 50, 50, true); finger("pointerdown", 2, 200, 100);
		  finger("pointerup", 2, 200, 100); finger("pointerup", 1, 50, 50); return [frame(), frame()];`)
		if !got[0].Click || got[0].X != 200 || !got[1].Click || got[1].X != 50 {
			t.Errorf("1 コマ目に (200,100)・2 コマ目に (50,50) のはず: %+v", got)
		}
	})
	t.Run("主な指の横のドラッグ中の 2 本目のタップはクリックにもカーソルの跳びにもならない", func(t *testing.T) {
		got := frames(t, `finger("pointerdown", 1, 50, 50, true); finger("pointermove", 1, 90, 52, true);
		  finger("pointerdown", 2, 300, 200); finger("pointerup", 2, 300, 200); return [frame()];`)
		if got[0].Click || got[0].X != 90 || !got[0].Down {
			t.Errorf("左ボタンを押したまま (90,52) に居るはず: %+v", got[0])
		}
	})
	t.Run("大きく動かした 2 本目の指はクリックにならない", func(t *testing.T) {
		got := frames(t, `finger("pointerdown", 1, 50, 50, true); finger("pointerdown", 2, 200, 100);
		  finger("pointermove", 2, 240, 100); finger("pointerup", 2, 240, 100); return [frame()];`)
		if got[0].Click {
			t.Errorf("動かした指はクリックでないはず: %+v", got[0])
		}
	})
	t.Run("指を置いている間は置いた所で押している状態になる", func(t *testing.T) {
		got := frames(t, `finger("pointerdown", 1, 70, 60, true); return [frame()];`)
		if !got[0].Down || got[0].Click || got[0].X != 70 || got[0].Y != 60 {
			t.Errorf("(70,60) で押したまま・クリックはまだのはず: %+v", got[0])
		}
	})
	t.Run("縦のドラッグに決まると押している状態が落ちる", func(t *testing.T) {
		got := frames(t, `finger("pointerdown", 1, 70, 60, true); finger("pointermove", 1, 70, 120, true); return [frame()];`)
		if got[0].Down {
			t.Errorf("ホイールに決まった指は押していないはず: %+v", got[0])
		}
	})
	t.Run("2 本置くとカーソルは後の指・後の指を離すと先の指の押しが残る", func(t *testing.T) {
		got := frames(t, `finger("pointerdown", 1, 50, 50, true); finger("pointerdown", 2, 200, 100); var a = frame();
		  finger("pointerup", 2, 200, 100); frame(); var b = frame(); return [a, b];`)
		if got[0].X != 200 || !got[0].Down || got[1].X != 50 || !got[1].Down {
			t.Errorf("置いている間は (200,100)・離した後は (50,50) で押したままのはず: %+v", got)
		}
	})
	t.Run("主でない指だけで置いた指も押している状態になる", func(t *testing.T) {
		got := frames(t, `finger("pointerdown", 1, 50, 350, true, "pad"); finger("pointerdown", 2, 150, 90); return [frame()];`)
		if !got[0].Down || got[0].X != 150 {
			t.Errorf("(150,90) で押したままのはず: %+v", got[0])
		}
	})
	t.Run("長押しに決まると押している状態が落ち、離すと長押しのキーだけが出る", func(t *testing.T) {
		var got struct {
			Held    fingerFrame `json:"held"`
			Click   bool        `json:"click"`
			Escaped bool        `json:"escaped"`
		}
		fingerScenario(t, page, `fgeWeb.touchGestures = { longPress: "Escape" }; var keep = fgeLongPressMs; fgeLongPressMs = 30;
		  finger("pointerdown", 1, 70, 60, true); await new Promise(r => setTimeout(r, 80)); fgeLongPressMs = keep;
		  var held = frame(); finger("pointerup", 1, 70, 60, true); var f = frame();
		  return { held: held, click: f.click, escaped: !!fgeFrameLatch.Escape };`, &got)
		if got.Held.Down || got.Click || !got.Escaped {
			t.Errorf("長押しの間は押していない・離すと Escape だけのはず: %+v", got)
		}
	})
	t.Run("離した合図の来なかった指は次の主な指で捨てられる", func(t *testing.T) {
		got := frames(t, `finger("pointerdown", 1, 50, 350, true, "pad"); finger("pointerdown", 2, 50, 50);
		  finger("pointerdown", 3, 200, 100, true); finger("pointermove", 3, 200, 160, true); return [frame()];`)
		if got[0].Down {
			t.Errorf("残った指 2 の押しが消え、指 3 がホイールに決まっているはず: %+v", got[0])
		}
	})
	t.Run("touch の event に canvas の指が無ければ残った追い先を捨てる", func(t *testing.T) {
		var down bool
		fingerScenario(t, page, `finger("pointerdown", 1, 50, 350, true, "pad"); finger("pointerdown", 2, 50, 50);
		  dispatchEvent(new TouchEvent("touchend", { touches: [] })); await new Promise(r => setTimeout(r, 200));
		  return fgePointer.buttons[0] || fgeGesture !== null;`, &down)
		if down {
			t.Error("pointerup の来なかった指の押しが残っている")
		}
	})
}

// 本物の指の event（CDP の touch）で、2 本を同時に置いて離すと 2 つのクリックになる。
func TestCanvasTrustedTwoFingerTaps(t *testing.T) {
	page := openFingersPage(t, cdp.PageOptions{Width: 400, Height: 400, Mobile: true, Touch: true})
	if err := page.Eval(`resetFingers(), true`, nil); err != nil {
		t.Fatal(err)
	}
	if err := page.Touch("touchStart", [2]float64{60, 350}, [2]float64{150, 90}); err != nil {
		t.Fatal(err)
	}
	if err := page.Touch("touchEnd"); err != nil {
		t.Fatal(err)
	}
	var got []fingerFrame
	if err := page.Eval(`[frame()]`, &got); err != nil {
		t.Fatal(err)
	}
	if !got[0].Click || math.Abs(got[0].X-150) > 0.01 || math.Abs(got[0].Y-90) > 0.01 {
		t.Errorf("pad 側に置いた主な指とは別の canvas の指が (150,90) のクリックのはず: %+v", got[0])
	}
}
