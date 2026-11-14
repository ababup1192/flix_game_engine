package tape

import (
	"fmt"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// 広い画面のキー・シートのボタン・保存・キーボード・横長の動画を、本物の頁で 1 つずつ確かめる（plans/tape/spec-wide.md の「決まった事」）。

// step は 1 手。key があれば trusted なキーを押し、js があれば頁で流し、to があればウィンドウの大きさを変え、hover があればその selector の物の真ん中へマウスを動かす。
type step struct {
	key   string
	mods  int
	js    string
	to    *view
	hover string
}

func key(k string) step              { return step{key: k} }
func keyMod(k string, mods int) step { return step{key: k, mods: mods} }
func js(s string) step               { return step{js: s} }
func resize(v view) step             { return step{to: &v} }
func hover(sel string) step          { return step{hover: sel} }

// uiCase は 1 つの確かめ。v の大きさで開き、at 秒へ送って setup を流し、steps の後で check が true になる。
type uiCase struct {
	name  string
	v     view
	init  string
	at    float64
	setup string
	steps []step
	check string
}

const uiState = `JSON.stringify({t: video.currentTime, paused: video.paused, rate: video.playbackRate, shut: shut && {dir: shut.dir, speed: shut.speed},
  open: openId, mode, sel: sel && sel.track, anns: anns.length, edits: Object.keys(edits), focus: document.activeElement.id || document.activeElement.tagName,
  toast: $("toast").textContent, form, scrim: $("scrim").classList.contains("on")})`

// runUICases は cases を 1 本ずつ確かめる。Chrome は view ごとに 1 つ起こして使い回し、1 本ごとに頁を開き直す。
// WhyNot: 1 本ずつ Chrome を起こさない — 起こすのに 3 秒ほどかかり、本数の分だけ全量が延びる
func runUICases(t *testing.T, url string, cases []uiCase) {
	skipWithoutChrome(t)
	pages := map[view]*cdp.Page{}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := pageForCase(t, pages, c)
			load(t, p, url)
			at := c.at
			if at == 0 {
				at = 8.0
			}
			seekTo(t, p, at)
			if c.setup != "" {
				mustEval(t, p, c.setup)
			}
			for _, s := range c.steps {
				doStep(t, p, s)
			}
			if err := p.WaitFor(c.check, 2*time.Second); err != nil {
				t.Errorf("%s が偽: %s", c.check, evalString(t, p, uiState))
			}
			noErrors(t, p, c.name)
		})
	}
	for _, p := range pages {
		p.Close()
	}
}

// pageForCase は c の view の頁を返す。使い回す頁は、前の 1 本の物（localStorage・大きさ・機種・マウスの位置）を消してから渡す。
func pageForCase(t *testing.T, pages map[view]*cdp.Page, c uiCase) *cdp.Page {
	t.Helper()
	// WhyNot: init のある 1 本に使い回しの頁を渡さない — 足した script は外せず、後の 1 本にも流れる
	if c.init != "" {
		p := openTapePage(t, c.v)
		if err := p.AddInitScript(c.init); err != nil {
			t.Fatal(err)
		}
		return p
	}
	p, ok := pages[c.v]
	if !ok {
		opened, err := newTapePage(c.v)
		if err != nil {
			t.Fatal(err)
		}
		pages[c.v] = opened
		return opened
	}
	// WhyNot: about:blank を挟む — 同じ URL を開き直すだけだと、load の合図が前の頁で真になり、新しい頁を待たずに進む
	for _, err := range []error{
		p.Eval(`(() => { try { localStorage.clear(); } catch {} return true; })()`, nil),
		p.Navigate("about:blank"),
		p.WaitFor(`location.href === "about:blank"`, 10*time.Second),
		p.SetTouch(c.v.touch),
		p.SetViewport(c.v.w, c.v.h, c.v.mobile),
		p.MoveMouse(2, 2),
	} {
		if err != nil {
			t.Fatal(err)
		}
	}
	return p
}

func mustEval(t *testing.T, p *cdp.Page, expr string) {
	t.Helper()
	if err := p.Eval("(() => { "+expr+" })(), true", nil); err != nil {
		t.Fatal(err)
	}
}

func doStep(t *testing.T, p *cdp.Page, s step) {
	t.Helper()
	switch {
	case s.key != "":
		if err := p.PressKey(s.key, s.mods); err != nil {
			t.Fatal(err)
		}
	case s.js != "":
		mustEval(t, p, s.js)
	case s.to != nil:
		if err := p.SetTouch(s.to.touch); err != nil {
			t.Fatal(err)
		}
		resizeTo(t, p, s.to.w, s.to.h, s.to.mobile)
	case s.hover != "":
		var at struct{ X, Y float64 }
		if err := p.Eval(fmt.Sprintf(`(() => { const r = document.querySelector(%q).getBoundingClientRect(); return {X: r.left + r.width / 2, Y: r.top + r.height / 2}; })()`, s.hover), &at); err != nil {
			t.Fatal(err)
		}
		if err := p.MoveMouse(at.X, at.Y); err != nil {
			t.Fatal(err)
		}
	}
	// WhyNot: すぐ次の手を打たない — シートを開くと入力欄の focus は 280ms 後に移り、その前のキーは body に届く
	if err := p.Eval(nextFrame, nil); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(`!openId || performance.now() - openedAt > 300`, 5*time.Second); err != nil {
		t.Fatal(err)
	}
}

// nextFrame は頁が 2 コマ描くまで待つ（resize の listener・保存の await・マウスの移動が頁に届いた後になる）。
const nextFrame = `new Promise(res => requestAnimationFrame(() => requestAnimationFrame(() => res(true))))`

const (
	typeNote   = `$("noteText").value = "書きかけ"; $("noteText").dispatchEvent(new Event("input"));`
	typeEdit   = `$("editText").value = "直した文章"; $("editText").dispatchEvent(new Event("input"));`
	selectLine = `select({ track: "script", ln: 25 });`
	hasEdit    = `edits[25] = "直した文章"; refresh();`
	stubSave   = `window.__saved = 0; downloads = { save: async () => { window.__saved++; } };`
	stubShare  = `window.__share = 0; window.__dl = 0; navigator.canShare = () => true; navigator.share = async () => { window.__share++; };
  HTMLAnchorElement.prototype.click = function () { window.__dl++; };`
	stubPlay = `window.__p = 0; $("playHereBtn").addEventListener("click", e => { window.__p++; e.preventDefault(); });`
	saveNow  = `$("exportBtn").onclick(); $("saveBtn").click();`
	editLine = `select({ track: "script", ln: 25 }); openEdit(25);`
	// sink は 31.8 秒と 33.4 秒の 2 つある。注釈は後の方に付いている
	sinkNote    = `anns.push({kind:"sound", target:{name:"sink",kind:"se",label:"沈む（深く）",line:54}, rect:null, seconds:33.4, frame:1002, scene:"sink", note:"2 つ目の沈む音", script:null, probes:{}}); refresh(); renderMarks();`
	unknownNote = `anns.push({kind:"sound", target:{name:"gone",kind:"se",label:"消えた音",line:40}, rect:null, seconds:20, frame:600, scene:"sink", note:"TAPE に無い音", script:null, probes:{}}); refresh(); renderMarks();`
	clickMark   = `$("marks").querySelector(".mk").click();`
	clickItem   = `$("listBody").querySelector(".item").click();`
	draftToast  = `$("toast").textContent === "先に付けるか閉じてください"`
	ctrlWheel   = `scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: %d, ctrlKey: true, bubbles: true, cancelable: true }));`
	metaWheel   = `scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: %d, metaKey: true, bubbles: true, cancelable: true }));`
)

var keyCases = []uiCase{
	{name: "Space で再生する", v: desktop, steps: []step{key(" ")}, check: `!video.paused`},
	{name: "Space を 2 回で止まる", v: desktop, steps: []step{key(" "), key(" ")}, check: `video.paused`},
	{name: "K で止まる", v: desktop, steps: []step{key(" "), key("k")}, check: `video.paused`},
	{name: "L で等速の再生", v: desktop, steps: []step{key("l")}, check: `!video.paused && video.playbackRate === 1`},
	{name: "L を 2 回で 2 倍", v: desktop, steps: []step{key("l"), key("l")}, check: `video.playbackRate === 2`},
	{name: "L を 3 回で 4 倍", v: desktop, steps: []step{key("l"), key("l"), key("l")}, check: `video.playbackRate === 4`},
	{name: "J で逆送り", v: desktop, steps: []step{key("j")}, check: `!!shut && shut.dir < 0 && shut.speed === 1`},
	{name: "J を 2 回で 2 倍の逆送り", v: desktop, steps: []step{key("j"), key("j")}, check: `!!shut && shut.dir < 0 && shut.speed === 2`},
	{name: "→ で 1 コマ進む", v: desktop, setup: `window.__f = frameOf(video.currentTime);`, steps: []step{key("ArrowRight")}, check: `frameOf(video.currentTime) === __f + 1`},
	{name: "← で 1 コマ戻る", v: desktop, setup: `window.__f = frameOf(video.currentTime);`, steps: []step{key("ArrowLeft")}, check: `frameOf(video.currentTime) === __f - 1`},
	{name: "Shift → で 1 秒進む", v: desktop, steps: []step{keyMod("ArrowRight", cdp.ModShift)}, check: `Math.abs(video.currentTime - 9) < .01`},
	{name: "Shift ← で 1 秒戻る", v: desktop, steps: []step{keyMod("ArrowLeft", cdp.ModShift)}, check: `Math.abs(video.currentTime - 7) < .01`},
	{name: "Home で頭へ", v: desktop, steps: []step{key("Home")}, check: `video.currentTime === 0`},
	{name: "End で終わりへ", v: desktop, steps: []step{key("End")}, check: `Math.abs(scroller.scrollLeft / PPS - (TAPE.duration - .05)) < .02`},
	{name: "End の後にタイムラインの秒と動画の秒が合う", v: desktop, steps: []step{key("End")}, check: `video.currentTime > 43 && Math.abs(scroller.scrollLeft / PPS - video.currentTime) < .02`},
	{name: "] で次の行へ", v: desktop, steps: []step{key("]")}, check: `Math.abs(video.currentTime - 9.05) < .01`},
	{name: "[ で前の行へ", v: desktop, steps: []step{key("[")}, check: `Math.abs(video.currentTime - 7.05) < .01`},
	{name: "↓ で映像のトラックを選ぶ", v: desktop, steps: []step{key("ArrowDown")}, check: `sel?.track === "video"`},
	{name: "↓ を 2 回で台本のトラック", v: desktop, steps: []step{key("ArrowDown"), key("ArrowDown")}, check: `sel?.track === "script"`},
	{name: "↑ で音のトラック", v: desktop, steps: []step{key("ArrowUp")}, check: `sel?.track === "sound"`},
	{name: "N で注釈を開く", v: desktop, steps: []step{key("n")}, check: `openId === "noteSheet"`},
	{name: "M で注釈を開く", v: desktop, steps: []step{key("m")}, check: `openId === "noteSheet"`},
	{name: "E で選んだ台詞を直す", v: desktop, setup: selectLine, steps: []step{key("e")}, check: `openId === "editSheet"`},
	{name: "E は台詞を選んでいないとトーストだけ", v: desktop, steps: []step{key("e")}, check: `openId === null && $("toast").textContent.startsWith("台詞を選んでいる時に直せます")`},
	{name: "R で囲む", v: desktop, steps: []step{key("r")}, check: `mode === "rect"`},
	{name: "O で物を選ぶ", v: desktop, steps: []step{key("o")}, check: `mode === "pick"`},
	{name: "P でここから遊ぶを押す", v: desktop, setup: stubPlay, steps: []step{key("p")}, check: `__p === 1 && $("playHereBtn").href.includes("?talk=Lair&line=")`},
	{name: "P は playUrl が無ければ何もしない", v: desktop, setup: stubPlay + `TAPE.playUrl = "";`, steps: []step{key("p")}, check: `__p === 0`},
	{name: "Esc でシートを閉じる", v: desktop, steps: []step{key("n"), key("Escape")}, check: `openId === null`},
	{name: "Esc で囲むをやめる", v: desktop, steps: []step{key("r"), key("Escape")}, check: `mode === null`},
	{name: "Esc で選ぶのをやめる", v: desktop, setup: `select({ track: "video" });`, steps: []step{key("Escape")}, check: `sel === null`},
	{name: "⌘Enter で注釈を付ける", v: desktop, setup: `window.__n = anns.length;`, steps: []step{key("n"), js(typeNote), keyMod("Enter", cdp.ModMeta)}, check: `anns.length === __n + 1`},
	{name: "Ctrl Enter で直しを当てる", v: desktop, setup: selectLine, steps: []step{key("e"), js(typeEdit), keyMod("Enter", cdp.ModCtrl)}, check: `edits[25] === "直した文章"`},
	{name: "⌘S の 1 回目で書き出しを開き保存に focus", v: desktop, setup: hasEdit, steps: []step{keyMod("s", cdp.ModMeta)}, check: `openId === "exportSheet" && document.activeElement === $("saveBtn")`},
	{name: "⌘S の 2 回目で保存の口を呼ぶ", v: desktop, setup: hasEdit + stubSave, steps: []step{keyMod("s", cdp.ModMeta), keyMod("s", cdp.ModMeta)}, check: `__saved === 1`},
	{name: "⌘S は書きかけの注釈があると開かない", v: desktop, steps: []step{key("n"), keyMod("s", cdp.ModMeta)}, check: `openId === "noteSheet" && ` + draftToast},
	{name: "⌘S は書きかけの直しがあると開かない", v: desktop, setup: selectLine, steps: []step{key("e"), keyMod("s", cdp.ModMeta)}, check: `openId === "editSheet" && ` + draftToast},
	{name: "Ctrl S は書きかけの直しがあると開かない", v: desktop, setup: selectLine, steps: []step{key("e"), keyMod("s", cdp.ModCtrl)}, check: `openId === "editSheet" && ` + draftToast},
	{name: "Ctrl S の 1 回目で書き出しを開く", v: desktop, setup: hasEdit, steps: []step{keyMod("s", cdp.ModCtrl)}, check: `openId === "exportSheet"`},
	{name: "入力欄では Space で再生しない", v: desktop, steps: []step{key("n"), key(" ")}, check: `video.paused && openId === "noteSheet"`},
	{name: "入力欄では K で何も起きない", v: desktop, steps: []step{key("n"), key("k")}, check: `openId === "noteSheet" && $("noteText").value === "k"`},
	{name: "変換中の Esc（isComposing）では閉じない", v: desktop, steps: []step{key("n"),
		js(`$("noteText").dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, isComposing: true }));`)}, check: `openId === "noteSheet"`},
	{name: "変換中の Esc（keyCode 229）では閉じない", v: desktop, steps: []step{key("n"),
		js(`$("noteText").dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", keyCode: 229, bubbles: true }));`)}, check: `openId === "noteSheet"`},
	{name: "変換中の ⌘Enter（isComposing）では付けない", v: desktop, setup: `window.__n = anns.length;`, steps: []step{key("n"), js(typeNote),
		js(`$("noteText").dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", metaKey: true, bubbles: true, isComposing: true }));`)}, check: `anns.length === __n && openId === "noteSheet"`},
	{name: "変換中の ⌘Enter（keyCode 229）では付けない", v: desktop, setup: `window.__n = anns.length;`, steps: []step{key("n"), js(typeNote),
		js(`$("noteText").dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", keyCode: 229, metaKey: true, bubbles: true }));`)}, check: `anns.length === __n && openId === "noteSheet"`},
	{name: "指の形ではキーが効かない", v: tablet, steps: []step{key(" ")}, check: `video.paused`},
}

var buttonCases = []uiCase{
	{name: "✕ でシートを閉じる", v: desktop, steps: []step{key("n"), js(`$("noteSheet").querySelector("[data-close]").click();`)}, check: `openId === null`},
	{name: "空の注釈の追加は押せない", v: desktop, steps: []step{key("n")}, check: `$("noteSave").disabled`},
	{name: "押せない追加は薄い", v: desktop, steps: []step{key("n")}, check: `getComputedStyle($("noteSave")).opacity === "0.35"`},
	{name: "押せない追加を押しても付かない", v: desktop, setup: `window.__n = anns.length;`, steps: []step{key("n"), js(`$("noteSave").click();`)}, check: `anns.length === __n`},
	{name: "変えていない直しの適用は押せない", v: desktop, setup: selectLine, steps: []step{key("e")}, check: `$("editSave").disabled`},
	{name: "⌘↵ の表示はマウスの広い形で出る", v: desktop, steps: []step{key("n")}, check: `getComputedStyle($("noteSheet").querySelector(".kbd-hint")).display !== "none"`},
	{name: "⌘↵ の表示は指の形で出ない", v: tablet, steps: []step{js(`noteHere();`)}, check: `getComputedStyle($("noteSheet").querySelector(".kbd-hint")).display === "none"`},
	{name: "⌘↵ の表示はスマホで出ない", v: phone, steps: []step{js(`noteHere();`)}, check: `getComputedStyle($("noteSheet").querySelector(".kbd-hint")).display === "none"`},
	{name: "書きかけの注釈は 3 列から 2 列でも右の欄に残る", v: desktop, steps: []step{key("n"), js(typeNote), resize(smallWin)},
		check: `openId === "noteSheet" && $("noteText").value === "書きかけ" && $("noteSheet").parentNode.id === "insp"`},
	{name: "書きかけの注釈はスマホへ戻っても残る", v: desktop, steps: []step{key("n"), js(typeNote), resize(phone)},
		check: `openId === "noteSheet" && $("noteText").value === "書きかけ" && $("noteSheet").parentNode.id !== "insp"`},
	{name: "書きかけのままスマホへ戻ると scrim が付く", v: desktop, steps: []step{key("n"), js(typeNote), resize(phone)}, check: `$("scrim").classList.contains("on")`},
	{name: "2 列でチャプターを開いたまま 3 列になると閉じる", v: smallWin, steps: []step{js(`openChapters(false);`), resize(desktop)}, check: `openId === null`},
}

var formChangeCases = []uiCase{
	{name: "書きかけの注釈は 3 列からスマホへ focus を持って移る", v: desktop, steps: []step{key("n"), js(typeNote), resize(phone)}, check: `document.activeElement.id === "noteText"`},
	{name: "書きかけの直しは 3 列からスマホへ字を持って移る", v: desktop, steps: []step{js(editLine), js(typeEdit), resize(phone)},
		check: `openId === "editSheet" && $("editText").value === "直した文章" && $("editSheet").parentNode.id !== "insp"`},
	{name: "書きかけの直しは 3 列からスマホへ focus を持って移る", v: desktop, steps: []step{js(editLine), js(typeEdit), resize(phone)}, check: `document.activeElement.id === "editText"`},
	{name: "書きかけの注釈はスマホから 3 列へ字を持って移る", v: phone, steps: []step{js(`noteHere();`), js(typeNote), resize(desktop)},
		check: `openId === "noteSheet" && $("noteText").value === "書きかけ" && $("noteSheet").parentNode.id === "insp"`},
	{name: "書きかけの注釈はスマホから 3 列へ focus を持って移る", v: phone, steps: []step{js(`noteHere();`), js(typeNote), resize(desktop)}, check: `document.activeElement.id === "noteText"`},
	{name: "書きかけの直しはスマホから 3 列へ字を持って移る", v: phone, steps: []step{js(editLine), js(typeEdit), resize(desktop)},
		check: `openId === "editSheet" && $("editText").value === "直した文章" && $("editSheet").parentNode.id === "insp"`},
	{name: "書きかけの直しはスマホから 3 列へ focus を持って移る", v: phone, steps: []step{js(editLine), js(typeEdit), resize(desktop)}, check: `document.activeElement.id === "editText"`},
	{name: "2 列で一覧を開いたまま 3 列になると閉じる", v: smallWin, steps: []step{js(`$("listBtn").onclick();`), resize(desktop)}, check: `openId === null`},
	{name: "3 列でこのコマを開いたままスマホになると閉じる", v: desktop, steps: []step{js(`openInfo();`), resize(phone)}, check: `openId === null && !$("infoSheet").classList.contains("on")`},
	{name: "スマホで書き出しを開いたまま 3 列になると閉じる", v: phone, setup: hasEdit, steps: []step{js(`$("exportBtn").onclick();`), resize(desktop)},
		check: `openId === null && !$("exportSheet").classList.contains("on") && !$("scrim").classList.contains("on")`},
	{name: "スマホでチャプターを開いたまま 2 列になると閉じる", v: phone, steps: []step{js(`openChapters(false);`), resize(smallWin)}, check: `openId === null && !$("chapSheet").classList.contains("on")`},
}

var soundNoteCases = []uiCase{
	{name: "音の注釈のマーカーは時刻が一番近い同じ名前の音を選ぶ", v: desktop, setup: sinkNote, steps: []step{js(clickMark)}, check: `sel?.sound?.t === 33.4`},
	{name: "音の注釈の一覧は時刻が一番近い同じ名前の音を選ぶ", v: desktop, setup: sinkNote, steps: []step{js(clickItem)}, check: `sel?.sound?.t === 33.4`},
	{name: "TAPE に無い音の注釈のマーカーは時刻だけ移す", v: desktop, setup: unknownNote, steps: []step{js(clickMark)}, check: `sel === null && Math.abs(video.currentTime - 20) < .05`},
	{name: "TAPE に無い音の注釈の一覧は時刻だけ移す", v: desktop, setup: unknownNote, steps: []step{js(clickItem)}, check: `sel === null && Math.abs(video.currentTime - 20) < .05`},
}

var zoomCases = []uiCase{
	{name: "ズームは 1 秒 240px で止まる", v: desktop, steps: []step{js(`setZoom(1e6);`)}, check: `PPS === 240`},
	{name: "ズームは 1 秒 14px で止まる", v: desktop, steps: []step{js(`setZoom(0);`)}, check: `PPS === 14`},
	{name: "ズームしても動画の秒が動かない", v: desktop, steps: []step{js(`setZoom(200);`)}, check: `PPS === 200 && Math.abs(video.currentTime - 8) < .01`},
	{name: "ズームしてもタイムラインの秒が動かない", v: desktop, steps: []step{js(`setZoom(200);`)}, check: `PPS === 200 && Math.abs(scroller.scrollLeft / PPS - 8) < .01`},
	{name: "スライダーを右端にすると一番広がる", v: desktop, steps: []step{js(`$("zoom").value = 100; $("zoom").dispatchEvent(new Event("input"));`)}, check: `PPS === 240`},
	{name: "⌘＋ホイールの上で広がる", v: desktop, steps: []step{js(fmt.Sprintf(metaWheel, -50))}, check: `PPS > 96`},
	{name: "Ctrl＋ホイールの下で縮む", v: desktop, steps: []step{js(fmt.Sprintf(ctrlWheel, 50))}, check: `PPS < 96`},
	{name: "指の形では Ctrl＋ホイールでズームしない", v: tablet, steps: []step{js(fmt.Sprintf(ctrlWheel, 50))}, check: `PPS === 96`},
	{name: "操作の早見はマウスの広い形で出る", v: desktop, check: `getComputedStyle($("keys")).display === "grid"`},
	{name: "操作の早見は指の形で出ない", v: tablet, check: `getComputedStyle($("keys")).display === "none"`},
	{name: "操作の早見はスマホで出ない", v: phone, check: `getComputedStyle($("keys")).display === "none"`},
	{name: "クリップにホバーすると吹き出しが出る", v: desktop, at: 8.4, steps: []step{hover(`.clip[data-ln="25"]`)}, check: `getComputedStyle($("tip")).display === "block" && $("tip").textContent.includes(":25")`},
	{name: "指の形ではホバーの吹き出しが出ない", v: tablet, at: 8.4, steps: []step{hover(`.clip[data-ln="25"]`)}, check: `getComputedStyle($("tip")).display === "none"`},
}

// scrollEndCases は 4 つの形のそれぞれで、タイムラインを一番右まで送った所が終わりの秒になることを見る。
func scrollEndCases() []uiCase {
	var cs []uiCase
	for _, f := range []struct {
		form string
		v    view
	}{{"phone", phone}, {"portrait", tablet}, {"two", smallWin}, {"three", desktop}} {
		cs = append(cs, uiCase{name: f.form + " の形で一番右まで送ると終わりの秒", v: f.v, at: 2.5, steps: []step{js(`scroller.scrollLeft = 1e9;`)},
			check: fmt.Sprintf(`form === %q && Math.abs(scroller.scrollLeft / PPS - TAPE.duration) <= .1`, f.form)})
	}
	return cs
}

var saveCases = []uiCase{
	{name: "downloads の口があれば使う", v: desktop, setup: hasEdit + stubSave + stubShare, steps: []step{js(saveNow)}, check: `__saved === 1 && __dl === 0`},
	{name: "マウスの広い形では共有シートを出さない", v: desktop, setup: hasEdit + stubShare, steps: []step{js(saveNow)}, check: `__share === 0`},
	{name: "マウスの広い形ではダウンロードにする", v: desktop, setup: hasEdit + stubShare, steps: []step{js(saveNow)}, check: `__dl === 1`},
	{name: "指の形でも downloads の口が先", v: tablet, setup: hasEdit + stubSave + stubShare, steps: []step{js(saveNow)}, check: `__saved === 1 && __share === 0`},
	{name: "指の形では共有シートを出す", v: tablet, setup: hasEdit + stubShare, steps: []step{js(saveNow)}, check: `__share === 1 && __dl === 0`},
	{name: "スマホでは共有シートを出す", v: phone, setup: hasEdit + stubShare, steps: []step{js(saveNow)}, check: `__share === 1 && __dl === 0`},
}

// fakeViewport は visualViewport を差し替え、テストから高さを変えて resize を出せるようにする（headless ではキーボードが出ない）。
const fakeViewport = `(() => {
  const vv = new EventTarget(); vv.offsetTop = 0; vv.offsetLeft = 0; vv.scale = 1;
  Object.defineProperty(vv, "height", { get: () => window.__vvH ?? innerHeight });
  Object.defineProperty(vv, "width", { get: () => innerWidth });
  Object.defineProperty(window, "visualViewport", { get: () => vv, configurable: true });
})();`

var keyboardCases = []uiCase{
	{name: "キーボードが出るとシートの確定がキーボードの上に見える", v: phone, init: fakeViewport,
		steps: []step{js(`noteHere();`), js(`window.__vvH = innerHeight - 300; visualViewport.dispatchEvent(new Event("resize"));`)},
		check: `(() => { const r = $("noteSave").getBoundingClientRect(); return r.top >= 0 && r.bottom <= innerHeight - 300; })()`},
}

func TestWideKeys(t *testing.T)     { runUICases(t, buildSite(t).tapeURL, keyCases) }
func TestSheetButtons(t *testing.T) { runUICases(t, buildSite(t).tapeURL, buttonCases) }
func TestSaveRoute(t *testing.T)    { runUICases(t, buildSite(t).tapeURL, saveCases) }
func TestFormChangeKeepsDraftsAndClosesTheRest(t *testing.T) {
	runUICases(t, buildSite(t).tapeURL, formChangeCases)
}
func TestSoundNoteSelectsTheNearestSound(t *testing.T) {
	runUICases(t, buildSite(t).tapeURL, soundNoteCases)
}
func TestZoomAndMouseExtras(t *testing.T)      { runUICases(t, buildSite(t).tapeURL, zoomCases) }
func TestTimelineScrollsToTheEnd(t *testing.T) { runUICases(t, buildSite(t).tapeURL, scrollEndCases()) }
func TestShortTimelineScrollsToTheEnd(t *testing.T) {
	runUICases(t, buildSite(t).otherURL, scrollEndCases())
}
func TestKeyboardKeepsSheetConfirmVisible(t *testing.T) {
	runUICases(t, buildSite(t).tapeURL, keyboardCases)
}

// overlayJS は canvas と、動画の映っている矩形（object-fit: contain）の差の一番大きい値を返す。
const overlayJS = `(() => {
  const c = canvas.getBoundingClientRect(), v = video.getBoundingClientRect();
  const k = Math.min(v.width / video.videoWidth, v.height / video.videoHeight), w = video.videoWidth * k, h = video.videoHeight * k;
  return Math.max(Math.abs(c.left - (v.left + (v.width - w) / 2)), Math.abs(c.top - (v.top + (v.height - h) / 2)), Math.abs(c.width - w), Math.abs(c.height - h)) < 1;
})()`

var landscapeCases = []uiCase{
	{name: "3 列の左を 216・右を 300 にする", v: desktop, at: 2.5,
		check: `(() => { const c = getComputedStyle(document.querySelector(".app")).gridTemplateColumns.split(" "); return c[0] === "216px" && c[2] === "300px"; })()`},
	{name: "真ん中の枠の比は動画の比", v: desktop, at: 2.5,
		check: `(() => { const f = $("frame").getBoundingClientRect(); return Math.abs(f.width / f.height - 960 / 540) < .01; })()`},
	{name: "canvas が動画の映っている矩形に重なる", v: desktop, at: 2.5, setup: `select({ track: "video" }); setMode("pick"); redraw();`, check: overlayJS},
	{name: "スマホでは wide-video の CSS が効かない", v: phone, at: 2.5,
		check: `(() => { const b = document.body, r = () => JSON.stringify($("frame").getBoundingClientRect()), on = b.classList.contains("wide-video"), a = r();
		  b.classList.remove("wide-video"); const off = r(); b.classList.add("wide-video"); return on && a === off; })()`},
}

func TestLandscapeVideoOnWide(t *testing.T) {
	runUICases(t, builtSite(t, otherPath, 6.2, "960x540"), landscapeCases)
}

// uiCase の名前の重なりを見る（t.Run の名前が重なると片方が #01 になって読めない）。
func TestUICaseNamesAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, cs := range [][]uiCase{keyCases, buttonCases, saveCases, keyboardCases, landscapeCases, formChangeCases, soundNoteCases, zoomCases, scrollEndCases()} {
		for _, c := range cs {
			if seen[c.name] {
				t.Errorf("名前が重なる: %q", c.name)
			}
			seen[c.name] = true
		}
	}
}
