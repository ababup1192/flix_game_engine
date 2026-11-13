package tape

import (
	"fmt"
	"hash/fnv"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// 頁の門: sample で作った index.html と mock.html を Chrome で 375×667 に開いて比べる。
// 動画は FGE_TAPE_MP4（モックの kesshou.mp4）があればそれ、無ければ ffmpeg の試験用の絵。
// 撮った絵は FGE_TAPE_SHOTS のフォルダへ書く（無ければ一時フォルダ）。

const (
	viewW, viewH = 375, 667
	envMP4       = "FGE_TAPE_MP4"
	envShots     = "FGE_TAPE_SHOTS"
)

// fnvPair は頁の fnv1a とゲームの側の FNV-1a 32bit が同じ字に同じ 8 桁を出すことを確かめる組。
// fnvPairs はその他の組（空・ASCII・「／」入り）。ゲームの側（テンプレの TestScriptEdits）にも同じ組を置く。
var fnvPair = [2]string{"こいつを持っていきな", "e05227c0"}
var fnvPairs = [][2]string{fnvPair, {"", "811c9dc5"}, {"abc", "1a47e90b"}, {"今夜は風が強い。／船は来るだろうか", "db27e017"}}

func TestFNV1aPairMatchesGoHash(t *testing.T) {
	for _, pair := range fnvPairs {
		if got := fnvHex(pair[0]); got != pair[1] {
			t.Errorf("%q: got %s（want %s）", pair[0], got, pair[1])
		}
	}
}

// initScript は頁のどの script より先に流し、例外と console.error を window.__errs に溜める。
const initScript = `
window.__errs = [];
addEventListener("error", e => window.__errs.push("error: " + e.message));
addEventListener("unhandledrejection", e => window.__errs.push("rejection: " + e.reason));
const __ce = console.error; console.error = (...a) => { window.__errs.push("console: " + a.join(" ")); __ce(...a); };
`

// posterCSS は <video> を隠して同じポスター画像を下に置く（UI だけを比べるため）。
const posterCSS = `(() => { const s = document.createElement("style");
  s.textContent = ".frame video{visibility:hidden}.frame{background:url(poster.png) center/contain no-repeat;border-radius:8px}";
  document.head.appendChild(s); return true; })()`

type site struct {
	root, mockURL, tapeURL, otherURL string
}

func writePoster(t *testing.T, path string) {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, 540, 960))
	for y := 0; y < 960; y++ {
		for x := 0; x < 540; x++ {
			img.SetNRGBA(x, y, color.NRGBA{uint8(x * 255 / 540), uint8(y * 255 / 960), uint8((x + y) % 256), 255})
		}
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
}

func copyFile(t *testing.T, src, dst string) {
	t.Helper()
	if err := os.WriteFile(dst, readFile(t, src), 0o644); err != nil {
		t.Fatal(err)
	}
}

func buildSite(t *testing.T) site {
	t.Helper()
	root := t.TempDir()
	mp4 := os.Getenv(envMP4)
	if mp4 == "" {
		mp4 = filepath.Join(root, "src.mp4")
		makeVideo(t, mp4, 43.6)
	}
	writePoster(t, filepath.Join(root, "poster.png"))
	// WhyNot: モックの strip.jpg は生成した絵なので git に置けない。同じ mp4 から同じ作りで起こし、両方の頁に同じ物を置く。
	if _, err := MakeStrip("", mp4, filepath.Join(root, StripFile), 43.6); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{"mock", "tape", "other"} {
		dir := filepath.Join(root, d)
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		copyFile(t, filepath.Join(root, StripFile), filepath.Join(dir, StripFile))
		copyFile(t, filepath.Join(root, "poster.png"), filepath.Join(dir, "poster.png"))
	}
	copyFile(t, mockPath, filepath.Join(root, "mock", "index.html"))
	copyFile(t, mp4, filepath.Join(root, "mock", "kesshou.mp4"))
	copyFile(t, mp4, filepath.Join(root, "tape", VideoFile))
	copyFile(t, mp4, filepath.Join(root, "other", VideoFile))
	write := func(dir, page string) {
		if err := os.WriteFile(filepath.Join(root, dir, "index.html"), []byte(page), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("tape", renderFile(t, samplePath, sampleStrip))
	write("other", renderFile(t, otherPath, sampleStrip))
	// WhyNot: 1 つの origin に並べると、モックと雛形が同じ localStorage の鍵（tape4:<game>:<commit>）を読み合い、前の頁の注釈が混ざる。
	serve := func(dir string) string {
		srv := httptest.NewServer(http.FileServer(http.Dir(filepath.Join(root, dir))))
		t.Cleanup(srv.Close)
		return srv.URL + "/"
	}
	return site{root: root, mockURL: serve("mock"), tapeURL: serve("tape"), otherURL: serve("other")}
}

func openTapePage(t *testing.T) *cdp.Page {
	t.Helper()
	if testing.Short() {
		t.Skip("-short では Chrome を起こさない")
	}
	if _, err := cdp.FindChrome(); err != nil {
		t.Skip(err)
	}
	p, err := cdp.OpenPage(cdp.PageOptions{Width: viewW, Height: viewH, Mobile: true, InitScript: initScript})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)
	return p
}

func load(t *testing.T, p *cdp.Page, url string) {
	t.Helper()
	if err := p.Navigate(url); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(`document.readyState === "complete" && typeof video !== "undefined" && video.readyState >= 1`, 30*time.Second); err != nil {
		t.Fatal(err)
	}
	if err := p.Eval(`document.fonts.ready.then(() => true)`, nil); err != nil {
		t.Fatal(err)
	}
	if err := p.Eval(posterCSS, nil); err != nil {
		t.Fatal(err)
	}
}

func seekTo(t *testing.T, p *cdp.Page, sec float64) {
	t.Helper()
	if err := p.Eval(fmt.Sprintf("seek(%g), true", sec), nil); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(fmt.Sprintf("!video.seeking && Math.abs(video.currentTime - %g) < 0.05", sec), 10*time.Second); err != nil {
		t.Fatal(err)
	}
	// WhyNot: 「注釈」ボタンの出る動き（.18 秒）が終わる前に撮ると、2 つの頁で途中の絵が違う。
	time.Sleep(400 * time.Millisecond)
}

func shot(t *testing.T, p *cdp.Page) *image.NRGBA {
	t.Helper()
	img, err := p.Screenshot()
	if err != nil {
		t.Fatal(err)
	}
	return img
}

func shotsDir(t *testing.T) string {
	if d := os.Getenv(envShots); d != "" {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		return d
	}
	return t.TempDir()
}

// diffRatio は 1 つの色の差が 32 を超える画素の割合と、モック｜雛形｜差 を横に並べた絵を返す。
func diffRatio(a, b *image.NRGBA) (float64, *image.NRGBA) {
	w, h := a.Bounds().Dx(), a.Bounds().Dy()
	side := image.NewNRGBA(image.Rect(0, 0, w*3, h))
	bad := 0
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			ca, cb := a.NRGBAAt(x, y), b.NRGBAAt(x, y)
			side.SetNRGBA(x, y, ca)
			side.SetNRGBA(w+x, y, cb)
			d := max(absDiff(ca.R, cb.R), absDiff(ca.G, cb.G), absDiff(ca.B, cb.B))
			if d > 32 {
				bad++
				side.SetNRGBA(2*w+x, y, color.NRGBA{255, 0, 0, 255})
			} else {
				side.SetNRGBA(2*w+x, y, color.NRGBA{ca.R / 4, ca.G / 4, ca.B / 4, 255})
			}
		}
	}
	return float64(bad) / float64(w*h), side
}

func absDiff(a, b uint8) int {
	if a > b {
		return int(a - b)
	}
	return int(b - a)
}

func savePNG(t *testing.T, path string, img image.Image) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
}

func noErrors(t *testing.T, p *cdp.Page, name string) {
	t.Helper()
	var errs []string
	if err := p.Eval(`window.__errs`, &errs); err != nil {
		t.Fatal(err)
	}
	if len(errs) > 0 {
		t.Errorf("%s の console にエラー: %v", name, errs)
	}
}

// 同じ手順で注釈を 1 つ・直しを 1 つ付け、書き出す .md を返す。
const annotateAndExport = `(() => {
  seek(9.5); $("sceneNote").click(); $("noteText").value = "泡が多すぎる"; $("noteSave").click();
  seek(8.6); openEdit(25); $("editText").value = "おや、あんた海の者でないね。\nすぐ分かるさ"; $("editSave").click();
  seek(8.6); return buildPrompt();
})()`

const maxDiff = 0.002

func TestPageMatchesMockOnPhone(t *testing.T) {
	p := openTapePage(t)
	s := buildSite(t)
	dir := shotsDir(t)
	times := []float64{3.0, 8.0, 17.5, 31.8}
	mock := map[float64]*image.NRGBA{}

	load(t, p, s.mockURL)
	// WhyNot: MOCK のバッジは雛形で消した物（直した所の一覧にある）。バッジの幅で題名がずれた分を違いに数えない。
	if err := p.Eval(`document.querySelector(".mock").style.display = "none", true`, nil); err != nil {
		t.Fatal(err)
	}
	for _, sec := range times {
		seekTo(t, p, sec)
		mock[sec] = shot(t, p)
	}
	var mockMD string
	if err := p.Eval(annotateAndExport, &mockMD); err != nil {
		t.Fatal(err)
	}
	seekTo(t, p, 8.6)
	mockEdited := shot(t, p)
	noErrors(t, p, "mock.html")

	load(t, p, s.tapeURL)
	for _, sec := range times {
		seekTo(t, p, sec)
		r, side := diffRatio(mock[sec], shot(t, p))
		savePNG(t, filepath.Join(dir, fmt.Sprintf("compare-%04.1f.png", sec)), side)
		t.Logf("%.1f 秒: 違う画素 %.3f%%", sec, r*100)
		if r > maxDiff {
			t.Errorf("%.1f 秒: モックと違う画素が %.2f%%（%s）", sec, r*100, dir)
		}
	}
	var scroll struct{ H, VH, W, VW float64 }
	if err := p.Eval(`({H: document.scrollingElement.scrollHeight, VH: innerHeight, W: document.scrollingElement.scrollWidth, VW: innerWidth})`, &scroll); err != nil {
		t.Fatal(err)
	}
	if scroll.H > scroll.VH || scroll.W > scroll.VW {
		t.Errorf("頁がスクロールする: %+v", scroll)
	}
	var lanes struct{ Film, Clips, Sounds, Forks int }
	if err := p.Eval(`({Film: $("film").offsetWidth, Clips: $("scriptRow").children.length, Sounds: $("soundRow").children.length, Forks: $("forks").children.length})`, &lanes); err != nil {
		t.Fatal(err)
	}
	if lanes.Film == 0 || lanes.Clips == 0 || lanes.Sounds == 0 || lanes.Forks != 1 {
		t.Errorf("3 つのトラックと分岐のマーカー: %+v", lanes)
	}
	for _, pair := range fnvPairs {
		var hash string
		if err := p.Eval(fmt.Sprintf("fnv1a(%q)", pair[0]), &hash); err != nil {
			t.Fatal(err)
		}
		if hash != pair[1] {
			t.Errorf("頁の fnv1a(%q) = %s（want %s）", pair[0], hash, pair[1])
		}
	}
	var tapeMD string
	if err := p.Eval(annotateAndExport, &tapeMD); err != nil {
		t.Fatal(err)
	}
	// reproduce.talk はノードをまたぐテープのために行のノードを指す書き方へ直した（mockFixes にある）。モックの側もその字にそろえて比べる。
	mockMD = strings.Replace(mockMD, "start talk node=Lair line=", "start talk node=<script.node> line=", 1)
	if tapeMD != mockMD {
		t.Errorf("書き出した .md がモックと違う\n雛形:\n%s\nモック:\n%s", tapeMD, mockMD)
	}
	seekTo(t, p, 8.6)
	r, side := diffRatio(mockEdited, shot(t, p))
	savePNG(t, filepath.Join(dir, "compare-edited-08.6.png"), side)
	t.Logf("直した台詞を重ねた 8.6 秒: 違う画素 %.3f%%", r*100)
	if r > maxDiff {
		t.Errorf("直した台詞を重ねた絵がモックと %.2f%% 違う", r*100)
	}
	noErrors(t, p, "index.html")
}

var exportKeys = []string{`"game"`, `"commit"`, `"flow"`, `"fps"`, `"reproduce"`, `"scriptEdits"`, `"annotations"`,
	`"id"`, `"track"`, `"kind"`, `"target"`, `"scene"`, `"frame"`, `"seconds"`, `"rect"`, `"script"`, `"note"`, `"probes"`,
	`"file"`, `"node"`, `"line"`, `"speaker"`, `"before"`, `"after"`}

func TestOtherTapeHasNoForkAndExportsAllFields(t *testing.T) {
	p := openTapePage(t)
	s := buildSite(t)
	load(t, p, s.otherURL)
	var got struct {
		Forks    int
		Chap     string
		PlayHere string
		Title    string
	}
	if err := p.Eval(`(() => { openChapters(false); const r = {Forks: $("forks").children.length, Chap: $("chapBody").querySelector(".ctxline").textContent,
	  PlayHere: getComputedStyle($("playHereBtn")).display, Title: document.title}; close(); return r; })()`, &got); err != nil {
		t.Fatal(err)
	}
	if got.Forks != 0 || strings.Contains(got.Chap, "分岐") {
		t.Errorf("branches が空なのに分岐が出る: %+v", got)
	}
	if got.PlayHere != "none" {
		t.Errorf("playUrl が無いのに「ここから遊ぶ」が出る: %s", got.PlayHere)
	}
	if got.Title != "テープ — 灯台守の夜" {
		t.Errorf("題名 %q", got.Title)
	}
	var md string
	if err := p.Eval(`(() => {
	  seek(2.5); $("sceneNote").click(); $("noteText").value = "風の音が小さい"; $("noteSave").click();
	  seek(2.5); openEdit(4); $("editText").value = "今夜は風が強い"; $("editSave").click();
	  return buildPrompt(); })()`, &md); err != nil {
		t.Fatal(err)
	}
	for _, k := range exportKeys {
		if !strings.Contains(md, k) {
			t.Errorf("書き出しに %s が無い", k)
		}
	}
	noErrors(t, p, "other")
}

// 横長の動画（960×540）: strip のコマは帯の枠の比のまま（真ん中を切り抜く）、canvas が動画の映っている矩形に重なり、枠が頁の外へ出ない。
func TestLandscapeVideoOverlaysWhereItIsShown(t *testing.T) {
	p := openTapePage(t)
	dir := t.TempDir()
	makeVideoSized(t, filepath.Join(dir, VideoFile), 6.2, "960x540")
	if err := os.WriteFile(filepath.Join(dir, TapeFile), readFile(t, otherPath), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.FileServer(http.Dir(dir)))
	t.Cleanup(srv.Close)
	if err := p.Navigate(srv.URL + "/"); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(`document.readyState === "complete" && typeof video !== "undefined" && video.readyState >= 1`, 30*time.Second); err != nil {
		t.Fatal(err)
	}
	seekTo(t, p, 2.5)
	if err := p.Eval(`select({track: "video"}), setMode("pick"), redraw(), true`, nil); err != nil {
		t.Fatal(err)
	}
	var got struct {
		StripW, StripH                     float64
		CanvasL, CanvasT, CanvasW, CanvasH float64
		ShownL, ShownT, ShownW, ShownH     float64
		FrameR, PageW                      float64
		Mid                                struct{ X, Y float64 }
	}
	if err := p.Eval(`(() => {
	  const c = canvas.getBoundingClientRect(), v = video.getBoundingClientRect(), f = $("frame").getBoundingClientRect();
	  const k = Math.min(v.width / video.videoWidth, v.height / video.videoHeight), w = video.videoWidth * k, h = video.videoHeight * k;
	  return {StripW: TAPE.strip.w, StripH: TAPE.strip.h, CanvasL: c.left, CanvasT: c.top, CanvasW: c.width, CanvasH: c.height,
	    ShownL: v.left + (v.width - w) / 2, ShownT: v.top + (v.height - h) / 2, ShownW: w, ShownH: h,
	    FrameR: f.right, PageW: innerWidth, Mid: toN({clientX: c.left + c.width / 2, clientY: c.top + c.height / 2})};
	})()`, &got); err != nil {
		t.Fatal(err)
	}
	savePNG(t, filepath.Join(shotsDir(t), "landscape-pick-02.5.png"), shot(t, p))
	if got.StripW != 54 || got.StripH != 96 {
		t.Errorf("strip の 1 コマが %vx%v（動画の比によらず帯の枠の 54x96）", got.StripW, got.StripH)
	}
	near := func(a, b float64) bool { return a-b < 1 && b-a < 1 }
	if !near(got.CanvasL, got.ShownL) || !near(got.CanvasT, got.ShownT) || !near(got.CanvasW, got.ShownW) || !near(got.CanvasH, got.ShownH) {
		t.Errorf("canvas が動画の映っている矩形に重なっていない: %+v", got)
	}
	if got.FrameR > got.PageW+0.5 {
		t.Errorf("枠が頁の外へ出る: 右端 %v / 頁の幅 %v", got.FrameR, got.PageW)
	}
	if !near(got.Mid.X*100, 50) || !near(got.Mid.Y*100, 50) {
		t.Errorf("動画の真ん中が割合の (0.5, 0.5) にならない: %+v", got.Mid)
	}
	noErrors(t, p, "landscape")
}

func fnvHex(s string) string {
	h := fnv.New32a()
	io.WriteString(h, s)
	return fmt.Sprintf("%08x", h.Sum32())
}

// 「ここから遊ぶ」の URL に、直した行が edit.<行>（後の文）と was.<行>（前の文のハッシュ）で乗る。
func TestPlayLinkCarriesEdits(t *testing.T) {
	p := openTapePage(t)
	s := buildSite(t)
	load(t, p, s.otherURL)
	var got struct {
		Href    string
		Dropped int
	}
	if err := p.Eval(`(() => { edits[4] = "今夜は風が凪いだ。／船は来る"; edits[8] = "灯台守は灯りを点けた"; return playLink(2.5); })()`, &got); err != nil {
		t.Fatal(err)
	}
	want := "&edit.4=" + url.PathEscape("今夜は風が凪いだ。／船は来る") + "&was.4=" + fnvHex("今夜は風が強い。／船は来るだろうか") +
		"&edit.8=" + url.PathEscape("灯台守は灯りを点けた") + "&was.8=" + fnvHex("灯台守は階段を上った")
	if got.Dropped != 0 || !strings.HasSuffix(got.Href, want) {
		t.Errorf("直しが URL に乗っていない\n got: %s（落とした %d）\nwant の終わり: %s", got.Href, got.Dropped, want)
	}
	noErrors(t, p, "other")
}

// msg.when の問いの値が今のコマと違う時（NVL のウィンドウなど）は、直した台詞を重ねず帯も出さない。そろう時は重ねる。
func TestEditOverlayFollowsMsgWhen(t *testing.T) {
	p := openTapePage(t)
	s := buildSite(t)
	load(t, p, s.otherURL)
	var got struct{ Off, On string }
	if err := p.Eval(`(() => {
	  const k = Object.keys(TAPE.probes)[0], now = String(probesAt(2.5)[k]);
	  edits[4] = "今夜は風が凪いだ"; seek(2.5);
	  MSG.when = { [k]: now + "_別" }; redraw(); const off = getComputedStyle($("editPill")).display;
	  MSG.when = { [k]: now }; redraw(); const on = getComputedStyle($("editPill")).display;
	  return { Off: off, On: on }; })()`, &got); err != nil {
		t.Fatal(err)
	}
	if got.Off != "none" || got.On == "none" {
		t.Errorf("when に従っていない: そろわない時 %s・そろう時 %s", got.Off, got.On)
	}
	noErrors(t, p, "other")
}

// 直しが長くて URL が 8000 字を超える時は、超えない所まで載せ、載せられなかった数をトーストで言う。
func TestPlayLinkDropsEditsPastTheLimit(t *testing.T) {
	p := openTapePage(t)
	s := buildSite(t)
	load(t, p, s.otherURL)
	var got struct {
		Len     int
		Dropped int
		Has4    bool
		Toast   string
	}
	if err := p.Eval(`(() => { const long = "あ".repeat(400); edits[4] = long; edits[6] = long; edits[8] = long;
	  const link = playLink(2.5); $("playHereBtn").onclick();
	  return {Len: link.href.length, Dropped: link.dropped, Has4: link.href.includes("&edit.4="), Toast: $("toast").textContent}; })()`, &got); err != nil {
		t.Fatal(err)
	}
	if got.Len > 8000 || got.Dropped != 1 || !got.Has4 {
		t.Errorf("8000 字までで削っていない: %+v", got)
	}
	if got.Toast != "直しの一部（1 件）は URL に乗らないので当てずに開きます" {
		t.Errorf("トースト %q", got.Toast)
	}
}

// twoTapesOneOrigin は同じ tape.json の頁を 1 つの origin の /a/ と /b/ に置き、その URL を返す（Pages に何本も並ぶ形）。
func twoTapesOneOrigin(t *testing.T) (string, string) {
	t.Helper()
	root := t.TempDir()
	a := filepath.Join(root, "a")
	if err := os.Mkdir(a, 0o755); err != nil {
		t.Fatal(err)
	}
	makeVideo(t, filepath.Join(a, VideoFile), 6.2)
	if err := os.WriteFile(filepath.Join(a, TapeFile), readFile(t, otherPath), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Build(Options{Dir: a, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	b := filepath.Join(root, "b")
	if err := os.Mkdir(b, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{VideoFile, TapeFile, StripFile, IndexFile} {
		copyFile(t, filepath.Join(a, f), filepath.Join(b, f))
	}
	srv := httptest.NewServer(http.FileServer(http.Dir(root)))
	t.Cleanup(srv.Close)
	return srv.URL + "/a/", srv.URL + "/b/"
}

func loadPlain(t *testing.T, p *cdp.Page, url string) {
	t.Helper()
	if err := p.Navigate(url); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(`document.readyState === "complete" && typeof video !== "undefined" && video.readyState >= 1`, 30*time.Second); err != nil {
		t.Fatal(err)
	}
}

// 同じ origin の別の頁（別のテープ）の注釈と直しは読まない。
func TestOtherPageOnSameOriginDoesNotShareNotes(t *testing.T) {
	p := openTapePage(t)
	a, b := twoTapesOneOrigin(t)
	loadPlain(t, p, a)
	if err := p.Eval(`(() => { seek(2.5); $("sceneNote").click(); $("noteText").value = "a の注釈"; $("noteSave").click();
	  seek(2.5); openEdit(4); $("editText").value = "a の直し"; $("editSave").click(); return true; })()`, nil); err != nil {
		t.Fatal(err)
	}
	loadPlain(t, p, b)
	var n struct{ Anns, Edits int }
	if err := p.Eval(`({Anns: anns.length, Edits: Object.keys(edits).length})`, &n); err != nil {
		t.Fatal(err)
	}
	if n.Anns != 0 || n.Edits != 0 {
		t.Errorf("/b/ が /a/ の注釈と直しを読んだ: %+v", n)
	}
	loadPlain(t, p, a)
	if err := p.Eval(`({Anns: anns.length, Edits: Object.keys(edits).length})`, &n); err != nil {
		t.Fatal(err)
	}
	if n.Anns != 1 || n.Edits != 1 {
		t.Errorf("/a/ に戻ると自分の注釈と直しが残っているはず: %+v", n)
	}
	noErrors(t, p, "a")
}

// 今の TAPE に無い scene・行・音を指す注釈と直しは、読んだ時に捨てる（書き出しが落ちない）。
func TestStoredNotesPointingAtUnknownThingsAreDropped(t *testing.T) {
	p := openTapePage(t)
	a, _ := twoTapesOneOrigin(t)
	loadPlain(t, p, a)
	if err := p.Eval(`(() => { localStorage.setItem(KEY, JSON.stringify({
	    anns: [
	      { kind: "scene", target: { id: "gone", name: "消えたシーン" }, scene: "gone", seconds: 1, frame: 30, note: "古い" },
	      { kind: "sound", target: { name: "se_gone" }, scene: TAPE.scenes[0].id, seconds: 1, frame: 30, note: "古い音" },
	      { kind: "script", target: { line: 999 }, scene: TAPE.scenes[0].id, seconds: 1, frame: 30, note: "古い行" },
	      { kind: "scene", target: { id: TAPE.scenes[0].id, name: TAPE.scenes[0].name }, scene: TAPE.scenes[0].id, seconds: 1, frame: 30, note: "今もある" }
	    ],
	    edits: { 999: "消えた行の直し", 3: "演出コマンドの直し", 4: "今もある行の直し" } })); return true; })()`, nil); err != nil {
		t.Fatal(err)
	}
	loadPlain(t, p, a)
	var got struct {
		Notes []string
		Edits []string
		MD    string
	}
	if err := p.Eval(`({Notes: anns.map(a => a.note), Edits: Object.keys(edits), MD: buildPrompt()})`, &got); err != nil {
		t.Fatal(err)
	}
	if strings.Join(got.Notes, ",") != "今もある" || strings.Join(got.Edits, ",") != "4" {
		t.Errorf("知らない物を指す注釈と直しが残った: %+v", got)
	}
	if !strings.Contains(got.MD, "今もある") {
		t.Errorf("残った注釈が書き出しに無い:\n%s", got.MD)
	}
	noErrors(t, p, "a")
}
