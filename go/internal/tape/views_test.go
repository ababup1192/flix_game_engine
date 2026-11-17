package tape

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 縦（スマホ）と横（PC）の 2 本の動画と、頁の隣に置くブラウザ版（はじめから遊ぶ）。

// writeViews は dir に横の tape.json と 960×540 の動画、phone が非 nil なら縦の tape-phone.json と 540×960 の動画を書く。
func writeViews(t *testing.T, dir string, tape []byte, phone []byte) {
	t.Helper()
	makeVideoSized(t, filepath.Join(dir, VideoFile), 6.2, "960x540")
	writeFile(t, filepath.Join(dir, TapeFile), string(tape))
	if phone != nil {
		makeVideoSized(t, filepath.Join(dir, PhoneVideoFile), 6.2, "540x960")
		writeFile(t, filepath.Join(dir, PhoneTapeFile), string(phone))
	}
}

// phoneTape は tape の msg と objects の枠を縦の画面の物に替えた tape.json（時刻の欄はそのまま）。
func phoneTape(t *testing.T, tape []byte, edit func(m map[string]any)) []byte {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(tape, &m); err != nil {
		t.Fatal(err)
	}
	m["msg"].(map[string]any)["cy"] = 0.31
	for _, o := range m["objects"].([]any) {
		o.(map[string]any)["rect"].(map[string]any)["h"] = 0.05
	}
	if edit != nil {
		edit(m)
	}
	out, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func pageTAPE(t *testing.T, dir string) map[string]json.RawMessage {
	t.Helper()
	page := string(readFile(t, filepath.Join(dir, IndexFile)))
	i, j := tapeLiteral(t, page, "const TAPE = ", ";\n")
	var m map[string]json.RawMessage
	if err := json.Unmarshal([]byte(strings.TrimSuffix(strings.TrimPrefix(page[i:j], "const TAPE = "), ";\n")), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestBuildPutsPhoneViewIntoViews(t *testing.T) {
	dir := t.TempDir()
	tape := readFile(t, otherPath)
	writeViews(t, dir, tape, phoneTape(t, tape, nil))
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	var views map[string]struct {
		Video string `json:"video"`
		Strip Strip  `json:"strip"`
		Msg   struct {
			Cy float64 `json:"cy"`
		} `json:"msg"`
	}
	if err := json.Unmarshal(pageTAPE(t, dir)["views"], &views); err != nil {
		t.Fatal(err)
	}
	got := views["phone"]
	if got.Video != PhoneVideoFile || got.Strip.File != PhoneStripFile || got.Strip.Count != 13 || got.Msg.Cy != 0.31 {
		t.Fatalf("views.phone: %+v", got)
	}
}

func TestBuildWritesPhoneStrip(t *testing.T) {
	dir := t.TempDir()
	tape := readFile(t, otherPath)
	writeViews(t, dir, tape, phoneTape(t, tape, nil))
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, PhoneStripFile)); err != nil {
		t.Fatal(err)
	}
}

func TestBuildWithoutPhoneTapeHasNoViews(t *testing.T) {
	dir := t.TempDir()
	writeViews(t, dir, readFile(t, otherPath), nil)
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	if _, ok := pageTAPE(t, dir)["views"]; ok {
		t.Fatal("縦の分が無いのに views がある")
	}
}

func TestBuildStopsWhenPhoneTimelineDiffers(t *testing.T) {
	dir := t.TempDir()
	tape := readFile(t, otherPath)
	writeViews(t, dir, tape, phoneTape(t, tape, func(m map[string]any) {
		tl := m["timeline"].([]any)
		tl[len(tl)-1].([]any)[0] = 5.9
	}))
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err == nil || !strings.Contains(err.Error(), `"timeline"`) {
		t.Fatalf("時刻の違う縦の分を通した: %v", err)
	}
}

func TestBuildStopsWhenPhoneVideoIsMissing(t *testing.T) {
	dir := t.TempDir()
	tape := readFile(t, otherPath)
	writeViews(t, dir, tape, nil)
	writeFile(t, filepath.Join(dir, PhoneTapeFile), string(phoneTape(t, tape, nil)))
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err == nil || !strings.Contains(err.Error(), PhoneVideoFile) {
		t.Fatalf("縦の動画が無いのに通した: %v", err)
	}
}

// writeExport は dir にブラウザ版の書き出しに見立てた index.html と wasm を書く。
func writeExport(t *testing.T, dir, wasm string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "assets"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(dir, "index.html"), "<!doctype html><title>ゲーム</title><p id=game>game</p>")
	writeFile(t, filepath.Join(dir, "assets", "classes.wasm"), wasm)
}

func TestBuildCopiesPlayAndSetsStart(t *testing.T) {
	dir, web := t.TempDir(), t.TempDir()
	writeViews(t, dir, readFile(t, otherPath), nil)
	writeExport(t, web, "wasm")
	if _, err := Build(Options{Dir: dir, Commit: "abc1234", Play: web}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, PlayDir, "assets", "classes.wasm")); err != nil {
		t.Fatal(err)
	}
	if got := string(pageTAPE(t, dir)["start"]); got != `"play/index.html"` {
		t.Fatalf("start: %s", got)
	}
}

func TestBuildWithoutPlayHasNoStart(t *testing.T) {
	dir := t.TempDir()
	writeViews(t, dir, readFile(t, otherPath), nil)
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	if _, ok := pageTAPE(t, dir)["start"]; ok {
		t.Fatal("書き出しが無いのに start がある")
	}
}

func TestBuildRefusesPlayWithHomePath(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip(err)
	}
	dir, web := t.TempDir(), t.TempDir()
	writeViews(t, dir, readFile(t, otherPath), nil)
	writeExport(t, web, "src="+home+"/game/src/Main.flix")
	if _, err := Build(Options{Dir: dir, Commit: "abc1234", Play: web}); err == nil || !strings.Contains(err.Error(), "ホームのパス") {
		t.Fatalf("ホームのパス入りの書き出しを通した: %v", err)
	}
}

func TestParseArgsTakesPlay(t *testing.T) {
	opt, err := parseArgs([]string{"--dir", "d", "--play", "w"})
	if err != nil || opt.Play != "w" {
		t.Fatalf("%+v %v", opt, err)
	}
}

func TestCopyTapeCopiesPhoneAndPlay(t *testing.T) {
	src, web, dst := t.TempDir(), t.TempDir(), filepath.Join(t.TempDir(), "out")
	tape := readFile(t, otherPath)
	writeViews(t, src, tape, phoneTape(t, tape, nil))
	writeExport(t, web, "wasm")
	if _, err := Build(Options{Dir: src, Commit: "abc1234", Play: web}); err != nil {
		t.Fatal(err)
	}
	if err := copyTape(src, dst, nil); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{PhoneVideoFile, PhoneStripFile, filepath.Join(PlayDir, "index.html"), filepath.Join(PlayDir, "assets", "classes.wasm")} {
		if _, err := os.Stat(filepath.Join(dst, f)); err != nil {
			t.Errorf("置き場に %s が無い", f)
		}
	}
}

// viewsSite は縦と横の 2 本と書き出しを持つテープを 1 つの origin に置く。
func viewsSite(t *testing.T) string {
	t.Helper()
	srv := httptest.NewServer(http.FileServer(http.Dir(viewsDir(t))))
	t.Cleanup(srv.Close)
	return srv.URL + "/"
}

// viewsSiteNoRange は Range を読まずいつも丸ごと返す置き場（手元の簡易な http サーバ）に viewsSite と同じ物を置く。
func viewsSiteNoRange(t *testing.T) string {
	t.Helper()
	fs := http.FileServer(http.Dir(viewsDir(t)))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Header.Del("Range")
		fs.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	return srv.URL + "/"
}

func viewsDir(t *testing.T) string {
	t.Helper()
	dir, web := t.TempDir(), t.TempDir()
	tape := readFile(t, otherPath)
	writeViews(t, dir, tape, phoneTape(t, tape, nil))
	writeExport(t, web, "wasm")
	if _, err := Build(Options{Dir: dir, Commit: "abc1234", Play: web}); err != nil {
		t.Fatal(err)
	}
	return dir
}

// shownView は今の動画の向き・URL の query・ボタンの字・はじめから遊ぶの href・MSG の cy。
type shownView struct {
	Tall           bool
	Search, Button string
	Start          string
	Cy             float64
	StartHidden    bool
	ButtonHidden   bool
}

const shownViewJS = `({Tall: video.videoHeight > video.videoWidth, Search: location.search, Button: $("viewBtn").textContent,
  Start: $("startBtn").getAttribute("href"), Cy: MSG.cy, StartHidden: $("startBtn").hidden, ButtonHidden: $("viewBtn").hidden})`

func readShown(t *testing.T, url string, v view, js string) shownView {
	t.Helper()
	p := openTapePage(t, v)
	loadPlain(t, p, url)
	if js != "" {
		if err := p.Eval(js, nil); err != nil {
			t.Fatal(err)
		}
	}
	var got shownView
	if err := p.Eval(shownViewJS, &got); err != nil {
		t.Fatal(err)
	}
	return got
}

func TestPageOpensPhoneVideoByDefault(t *testing.T) {
	got := readShown(t, viewsSite(t), desktop, "")
	if !got.Tall || got.Button != "PC の画面" || got.Cy != 0.31 {
		t.Fatalf("%+v", got)
	}
}

func TestPageOpensPcVideoWithViewQuery(t *testing.T) {
	got := readShown(t, viewsSite(t)+"?view=pc", phone, "")
	if got.Tall || got.Button != "スマホの画面" || got.Cy == 0.31 {
		t.Fatalf("%+v", got)
	}
}

func TestStartButtonOpensPlayInTheViewOrientation(t *testing.T) {
	if got := readShown(t, viewsSite(t), phone, ""); got.StartHidden || got.Start != "play/index.html?orientation=portrait" {
		t.Fatalf("%+v", got)
	}
}

func TestOldTapeHasNeitherButton(t *testing.T) {
	got := readShown(t, builtSite(t, otherPath, 6.2, "960x540"), desktop, "")
	if !got.StartHidden || !got.ButtonHidden {
		t.Fatalf("%+v", got)
	}
}

// switched は 3.0 秒で止めてから切り替えのボタンを押し、動画が替わった後の秒と様子。
func switched(t *testing.T, url string, v view, presses int) (float64, shownView) {
	t.Helper()
	p := openTapePage(t, v)
	loadPlain(t, p, url)
	seekTo(t, p, 3)
	for i := 0; i < presses; i++ {
		want := "video.videoHeight < video.videoWidth"
		if i%2 == 1 {
			want = "video.videoHeight > video.videoWidth"
		}
		if err := p.Eval(`$("viewBtn").click(), true`, nil); err != nil {
			t.Fatal(err)
		}
		if err := p.WaitFor(want+" && !video.seeking && Math.abs(video.currentTime - 3) < 0.05", 20*time.Second); err != nil {
			t.Fatalf("%d 回目の切り替えで秒が保たれない（%v）: %s", i+1, err, evalString(t, p, `String(video.currentTime)`))
		}
	}
	var got shownView
	if err := p.Eval(shownViewJS, &got); err != nil {
		t.Fatal(err)
	}
	return evalFloat(t, p, "scroller.scrollLeft / PPS"), got
}

func TestSwitchToPcKeepsTheTimelinePosition(t *testing.T) {
	at, got := switched(t, viewsSite(t), desktop, 1)
	if got.Tall || got.Search != "?view=pc" || got.Start != "play/index.html?orientation=landscape" || at < 2.95 || at > 3.05 {
		t.Fatalf("帯 %v 秒・%+v", at, got)
	}
}

func TestSwitchBackToPhoneDropsTheQuery(t *testing.T) {
	at, got := switched(t, viewsSite(t), phone, 2)
	if !got.Tall || got.Search != "" || got.Cy != 0.31 || at < 2.95 || at > 3.05 {
		t.Fatalf("帯 %v 秒・%+v", at, got)
	}
}

func TestRectNoteRemembersTheScreen(t *testing.T) {
	p := openTapePage(t, phone)
	loadPlain(t, p, viewsSite(t))
	seekTo(t, p, 2.5)
	md := evalString(t, p, `(() => { pending = { track: "video", kind: "rect", target: { name: "囲んだ所" }, scene: TAPE.scenes[0].id, frame: 75, seconds: 2.5, rect: { x: .1, y: .1, w: .2, h: .2 } };
	  $("noteText").value = "ここ"; $("noteSave").onclick(); return buildPrompt(); })()`)
	if !strings.Contains(md, `"screen": "phone"`) || !strings.Contains(md, "スマホの画面] ここ") {
		t.Fatalf("書き出しに画面が無い:\n%s", md)
	}
}

func TestBranchLinkCarriesPcView(t *testing.T) {
	// 横で見ている時は、分岐の道の隣の頁へも ?view=pc を持っていく（縦は既定なので何も足さない）。
	p := openTapePage(t, phone)
	loadPlain(t, p, viewsSite(t)+"?view=pc")
	if got := evalString(t, p, `withTapeView("../dark/index.html#t=4")`); got != "../dark/index.html?view=pc#t=4" {
		t.Fatalf("横: %s", got)
	}
	if err := p.Eval(`setTapeView("phone"), true`, nil); err != nil {
		t.Fatal(err)
	}
	if got := evalString(t, p, `withTapeView("../dark/index.html#t=4")`); got != "../dark/index.html#t=4" {
		t.Fatalf("縦: %s", got)
	}
}

func TestGraphJumpToTheOtherPageKeepsPcView(t *testing.T) {
	// 分岐を束ねた頁で、グラフの箱から隣の頁へ移っても横の選びが続く。
	root := t.TempDir()
	writeGame(t, root)
	dirs := writeForkDirs(t, root, []string{"light", "dark"}, [][]byte{forkTape(t, 0), forkTape(t, 1)})
	for i, d := range dirs {
		makeVideoSized(t, filepath.Join(d, VideoFile), 6.2, "960x540")
		makeVideoSized(t, filepath.Join(d, PhoneVideoFile), 6.2, "540x960")
		writeFile(t, filepath.Join(d, PhoneTapeFile), string(phoneTape(t, forkTape(t, i), nil)))
	}
	if _, err := BuildGroup(Options{Group: dirs, Commit: "abc1234"}, nil); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.FileServer(http.Dir(root)))
	t.Cleanup(srv.Close)
	p := openTapePage(t, phone)
	loadPlain(t, p, srv.URL+"/light/?view=pc")
	if err := p.Eval(`(() => { openChapters(true); $("gwrap").querySelector('.gbox[data-node="Sleep"]').dispatchEvent(new MouseEvent("click", { bubbles: true })); $("nodePanel").querySelector('.gact[data-href]').click(); return true; })()`, nil); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(`location.pathname.startsWith("/dark/") && location.search === "?view=pc" && location.hash === "#t=4" && typeof video !== "undefined" && video.readyState >= 1 && video.videoWidth > video.videoHeight`, 30*time.Second); err != nil {
		t.Fatalf("dark の頁へ横のまま移っていない: %v（%s）", err, evalString(t, p, `location.href + " " + video.readyState + " " + video.videoWidth + "x" + video.videoHeight + " " + tapeView + " " + TAPE.video`))
	}
}

func TestSwitchWithoutRangeKeepsTheTime(t *testing.T) {
	// Range を返さない置き場では丸ごと取ってから替える。それでも秒が頭へ戻らない。
	at, got := switched(t, viewsSiteNoRange(t), phone, 1)
	if got.Tall || at < 2.95 || at > 3.05 {
		t.Fatalf("帯 %v 秒・%+v", at, got)
	}
}

func TestSwitchShowsProgressAtOnce(t *testing.T) {
	// 押したその場で「切り替え中…」が出る（スマホの回線で取り終えるまで何も起きないように見えない）。
	p := openTapePage(t, phone)
	loadPlain(t, p, viewsSite(t))
	if got := evalString(t, p, `($("viewBtn").click(), $("viewPill").classList.contains("on") + " " + $("viewPill").textContent)`); got != "true PC の画面に切り替え中…" {
		t.Fatalf("押した直後: %s", got)
	}
	if err := p.WaitFor(`!$("viewPill").classList.contains("on") && video.videoWidth > video.videoHeight`, 20*time.Second); err != nil {
		t.Fatalf("切り替えの様子が消えない: %v", err)
	}
}

// topBarJS は（グラフの無いテープでも映像/グラフを出して一番狭い形にして）上の帯のボタンが画面の中に収まり、互いに重ならないか。重なり・はみ出しを 1 つずつ返す。
const topBarJS = `(() => {
  const ids = ["listBtn", "chapBtn", "modes", "viewBtn", "startBtn", "exportBtn"], out = [];
  $("modes").style.display = "";
  const r = ids.map(id => [id, $(id).getBoundingClientRect()]);
  r.forEach(([id, b]) => { if (b.left < 0 || b.right > innerWidth + .5 || b.top < 0 || b.width === 0) out.push(id + " が外" + JSON.stringify([b.left, b.right, b.top, b.width, innerWidth])); });
  r.forEach(([a, x], i) => r.slice(i + 1).forEach(([b, y]) => {
    if (x.left < y.right - .5 && y.left < x.right - .5 && x.top < y.bottom - .5 && y.top < x.bottom - .5) out.push(a + " と " + b + " が重なる");
  }));
  const t = $("tapeTitle").getBoundingClientRect(), c = $("chapBtn").getBoundingClientRect();
  if (t.top < c.top - .5 || t.bottom > c.bottom + .5) out.push("題名が枠の外");
  if (!$("startBtn").textContent.includes("はじめから遊ぶ") || $("startBtn").querySelector(".long").offsetWidth === 0) out.push("はじめから遊ぶの字が出ない");
  return out.join(" / ");
})()`

func TestTopBarFitsNarrowPhones(t *testing.T) {
	for _, w := range []int{360, 375, 411, 768, 1280} {
		p := openTapePage(t, view{w, 800, w < 720, w < 720})
		loadPlain(t, p, viewsSite(t))
		if got := evalString(t, p, topBarJS); got != "" {
			t.Errorf("幅 %d: %s", w, got)
		}
	}
}

// switchedStrip は縦横 2 本のテープを横で開き、縦の strip を 5 列 3 行の格子と見なして縦へ替え、js の値を返す。
// WhyNot: 縦の strip をそのまま使わない — 試験の 2 本は同じ長さで格子の形も同じになり、描き直しを抜いても値が変わらない
func switchedStrip[T any](t *testing.T, js string) T {
	t.Helper()
	p := openTapePage(t, phone)
	loadPlain(t, p, viewsSite(t)+"?view=pc")
	var out T
	if err := p.Eval(`(() => { VIEWS.phone.strip = { ...VIEWS.phone.strip, cols: 5, rows: 3 }; setTapeView("phone"); return `+js+`; })()`, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestSwitchingViewSetsTheThumbSizeOfTheNewStrip(t *testing.T) {
	// 縦へ替えると、チャプターの見出しの絵の背景の大きさは縦の strip の格子から出し直す。
	if ok := switchedStrip[bool](t, `document.documentElement.style.getPropertyValue("--chap-bg") === (CHAP_W * 5) + "px " + (53 * 3) + "px"`); !ok {
		t.Fatal("--chap-bg が縦の strip の 5 列 3 行の値でない")
	}
}

func TestSwitchingViewLaysTheFilmOutAgain(t *testing.T) {
	// 縦へ替えると、映像の帯は縦の strip の行の数だけの区間に並べ直す。
	if ok := switchedStrip[bool](t, `film.children.length === 3`); !ok {
		t.Fatal("帯の区間の数が縦の strip の行の数でない")
	}
}

func TestSwitchingViewKeepsTheCurrentScene(t *testing.T) {
	// 縦へ替えても、タイムラインの今のシーンの強調は残る。
	if ok := switchedStrip[bool](t, `!!$("scenes").querySelector(".scene.cur")`); !ok {
		t.Fatal("今のシーンの強調が消えた")
	}
}
