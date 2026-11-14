package tape

import (
	"fmt"
	"image"
	"math"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// 広い画面（幅 720 以上）の門: mock.html と本物を同じ大きさ・同じ入力で撮り比べ、形の切り替えで本物にだけある機能が崩れないことを見る。

// wideSeed は注釈 5 つと直し 1 つを頁の鍵（KEY）に入れる。左の欄・右の欄・ルーラーのマーカーに中身が出る状態で比べるため。
const wideSeed = `localStorage.setItem(KEY, JSON.stringify({
 anns: [
  {kind:"scene", target:{id:"arrive",name:"少女と魔女",from:5,to:8}, rect:null, seconds:6.2, frame:186, scene:"arrive", note:"魔女が出るまでが長い。1 秒ほど詰めたい", script:null, probes:{}},
  {kind:"sound", target:{name:"bubble",kind:"se",label:"泡",line:27}, rect:null, seconds:9.0, frame:270, scene:"wish", note:"泡の音が大きすぎる。台詞にかぶる", script:{file:"assets/talk/kesshou.yarn",node:"Lair",line:28}, probes:{}},
  {kind:"object", target:{id:"witch",name:"魔女"}, rect:{x:.44,y:.6,w:.56,h:.4}, seconds:10.4, frame:312, scene:"wish", note:"魔女の立ち絵がメッセージウィンドウに隠れる", script:{file:"assets/talk/kesshou.yarn",node:"Lair",line:29}, probes:{}},
  {kind:"script", target:{line:31}, rect:null, seconds:13.2, frame:396, scene:"price", note:"ここで 0.5 秒ほど間を置きたい", script:{file:"assets/talk/kesshou.yarn",node:"Lair",line:31}, probes:{}},
  {kind:"sound", target:{name:"sink",kind:"se",label:"沈む（深く）",line:54}, rect:null, seconds:33.4, frame:1002, scene:"sink", note:"2 つ目の沈む音", script:null, probes:{}}
 ],
 edits: {29: "なになに……／魔女の力を借りに、／息を切らしてここまで？／ご苦労なことだ"}
})), true`

// wideCase は撮り比べの 1 枚（どの大きさ・入力で開き、何秒で何をした所を撮るか）。
type wideCase struct {
	name string
	v    view
	sec  float64
	act  string
}

var wideCases = []wideCase{
	{"1440x900-three-edit", desktop, 8.0, `select({ track: "script", ln: 25 }); openEdit(25); true`},
	{"1180x820-three-fork", laptop, 16.7, `openChapters(true); true`},
	{"820x1180-portrait-touch", tablet, 8.0, `true`},
	{"900x700-two-line", smallWin, 8.0, `select({ track: "script", ln: 25 }); true`},
}

// seeded は url を開いて wideSeed を入れ、開き直す。
func seeded(t *testing.T, p *cdp.Page, url string) {
	t.Helper()
	load(t, p, url)
	if err := p.Eval(wideSeed, nil); err != nil {
		t.Fatal(err)
	}
	load(t, p, url)
}

// shootCase は 1 つの頁で c の状態を作って撮る。
func shootCase(t *testing.T, url string, c wideCase, mock bool) *image.NRGBA {
	t.Helper()
	p := openTapePage(t, c.v)
	seeded(t, p, url)
	if mock {
		if err := p.Eval(`document.querySelector(".mock").style.display = "none", true`, nil); err != nil {
			t.Fatal(err)
		}
	}
	// WhyNot: マウスを (0, 0) のままにしない — タイムラインのクリップやマーカーの上に来ると吹き出しが出て、片方の頁だけに映る
	if !c.v.touch {
		if err := p.MoveMouse(2, 2); err != nil {
			t.Fatal(err)
		}
	}
	seekTo(t, p, c.sec)
	if err := p.Eval(c.act, nil); err != nil {
		t.Fatal(err)
	}
	// WhyNot: すぐ撮らない — 入力欄の focus は少し後に移り、左の欄の scrollIntoView は smooth で動き、着いた所のハイライト（.flash）はしばらく残る
	waitStill(t, p, draftFocused+` && !document.querySelector(".flash")`)
	if err := p.Eval(nextFrame, nil); err != nil {
		t.Fatal(err)
	}
	noErrors(t, p, c.name)
	return shot(t, p)
}

const maxDiffWide = 0.002

func TestPageMatchesMockWide(t *testing.T) {
	s := buildSite(t)
	dir := shotsDir(t)
	for _, c := range wideCases {
		t.Run(c.name, func(t *testing.T) {
			r, side := diffRatio(shootCase(t, s.mockURL, c, true), shootCase(t, s.tapeURL, c, false))
			savePNG(t, filepath.Join(dir, "compare-wide-"+c.name+".png"), side)
			t.Logf("%s: 違う画素 %.3f%%", c.name, r*100)
			if r > maxDiffWide {
				t.Errorf("%s: モックと違う画素が %.2f%%（%s）", c.name, r*100, dir)
			}
		})
	}
}

func evalString(t *testing.T, p *cdp.Page, expr string) string {
	t.Helper()
	var s string
	if err := p.Eval(expr, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

func evalFloat(t *testing.T, p *cdp.Page, expr string) float64 {
	t.Helper()
	var f float64
	if err := p.Eval(expr, &f); err != nil {
		t.Fatal(err)
	}
	return f
}

// resizeTo は開いたままの頁の大きさを変え、形の切り替え（resize の listener）が済むのを待つ。
func resizeTo(t *testing.T, p *cdp.Page, w, h int, mobile bool) {
	t.Helper()
	if err := p.SetViewport(w, h, mobile); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(fmt.Sprintf("innerWidth === %d && innerHeight === %d", w, h), 5*time.Second); err != nil {
		t.Fatal(err)
	}
	if err := p.Eval(nextFrame, nil); err != nil {
		t.Fatal(err)
	}
}

func TestFormFollowsWindowSizeAtTheEdges(t *testing.T) {
	s := buildSite(t)
	p := openTapePage(t, desktop)
	load(t, p, s.tapeURL)
	for _, c := range []struct {
		w, h int
		want string
	}{
		{719, 600, "phone"}, {720, 600, "two"}, {1023, 700, "two"}, {1024, 700, "three"}, {720, 1000, "portrait"}, {719, 1000, "phone"},
	} {
		t.Run(fmt.Sprintf("%dx%d", c.w, c.h), func(t *testing.T) {
			resizeTo(t, p, c.w, c.h, false)
			if got := evalString(t, p, "form"); got != c.want {
				t.Errorf("形 %s（want %s）", got, c.want)
			}
		})
	}
}

func TestPhoneLooksTheSameAfterGoingWideAndBack(t *testing.T) {
	// 375 → 1440 → 375 と変えると、DOM の置き場が元へ戻り、初めの絵と同じになる。
	s := buildSite(t)
	p := openTapePage(t, phone)
	load(t, p, s.tapeURL)
	// WhyNot: 動画の枠を写さない — 大きさを変えると背景の絵の縮め方が変わり、UI と関係の無い端の画素が揺れる
	if err := p.Eval(`$("frame").style.visibility = "hidden", true`, nil); err != nil {
		t.Fatal(err)
	}
	seekTo(t, p, 8.0)
	before := shot(t, p)
	resizeTo(t, p, desktop.w, desktop.h, false)
	resizeTo(t, p, phone.w, phone.h, true)
	seekTo(t, p, 8.0)
	r, side := diffRatio(before, shot(t, p))
	savePNG(t, filepath.Join(shotsDir(t), "compare-phone-wide-phone.png"), side)
	if r > 0 {
		t.Errorf("行き来した後の 375 の絵が初めと %.3f%% 違う", r*100)
	}
}

// exportIn は v のウィンドウで本物を開き、annotateAndExport の .md を返す。
func exportIn(t *testing.T, url string, v view) string {
	t.Helper()
	p := openTapePage(t, v)
	load(t, p, url)
	return evalString(t, p, annotateAndExport)
}

func TestExportIsTheSameOnWideAndPhone(t *testing.T) {
	s := buildSite(t)
	if wide, ph := exportIn(t, s.tapeURL, desktop), exportIn(t, s.tapeURL, phone); wide != ph {
		t.Errorf("広い形とスマホの形で書き出しが違う\n広い:\n%s\nスマホ:\n%s", wide, ph)
	}
}

// hashStart は v のウィンドウで url を開き、動画が読めた後の秒と、タイムラインの位置（scroller）を秒に直した値を返す。
func hashStart(t *testing.T, url string, v view) (float64, float64, string) {
	t.Helper()
	p := openTapePage(t, v)
	loadPlain(t, p, url)
	waitSeeked(t, p)
	noErrors(t, p, url)
	return evalFloat(t, p, "video.currentTime"), evalFloat(t, p, "scroller.scrollLeft / PPS"), evalString(t, p, "form")
}

func TestHashTimeSeeksVideoOnThreeColumns(t *testing.T) {
	s := buildSite(t)
	if sec, _, form := hashStart(t, s.tapeURL+"#t=20", desktop); math.Abs(sec-20) > .05 || form != "three" {
		t.Fatalf("3 列で動画が 20 秒でない: %v 秒・形 %s", sec, form)
	}
}

func TestHashTimeMovesTimelineOnThreeColumns(t *testing.T) {
	s := buildSite(t)
	if _, at, _ := hashStart(t, s.tapeURL+"#t=20", desktop); math.Abs(at-20) > .05 {
		t.Fatalf("3 列でタイムラインの位置が 20 秒でない: %v", at)
	}
}

func TestHashTimeMovesTimelineWithLandscapeVideo(t *testing.T) {
	// 横長の動画は読めた時に 3 列の列幅が変わる（relayout）。その後でもタイムラインと動画が #t の秒に合う。
	sec, at, _ := hashStart(t, builtSite(t, samplePath, 43.6, "960x540")+"#t=20", desktop)
	if math.Abs(sec-20) > .05 || math.Abs(at-20) > .05 {
		t.Fatalf("横長の動画で #t=20 が合わない: 動画 %v 秒・タイムライン %v 秒", sec, at)
	}
}

func TestOtherTapeFilmUsesItsOwnStripCountOnWide(t *testing.T) {
	// 13 コマの strip のテープ（6.2 秒）は、広い画面のタイムラインでも 13 コマ分の幅で並べる。
	p := openTapePage(t, desktop)
	loadPlain(t, p, builtSite(t, otherPath, 6.2, "540x960"))
	if !evalBool(t, p, `TAPE.strip.count === 13 && film.style.backgroundSize.split(" ")[0] === PPS / TAPE.stripPerSec * 13 + "px"`) {
		t.Fatalf("映像のトラックの幅 %s（13 コマ分でない）", evalString(t, p, `film.style.backgroundSize`))
	}
}

func evalBool(t *testing.T, p *cdp.Page, expr string) bool {
	t.Helper()
	var b bool
	if err := p.Eval(expr, &b); err != nil {
		t.Fatal(err)
	}
	return b
}

func TestSplashCoversTheWholeWideWindow(t *testing.T) {
	step := make(chan struct{})
	defer close(step)
	p := openSplashPage(t, desktop, videoServer(t, steppedVideo(t, true, []float64{.3, 1}, step)))
	if err := p.WaitFor(`typeof splash !== "undefined" && splash.ratio >= .29`, 20*time.Second); err != nil {
		t.Fatal(err)
	}
	if r := evalString(t, p, `(() => { const b = $("splash").getBoundingClientRect(); return [b.left, b.top, b.width, b.height].join(","); })()`); r != "0,0,1440,900" {
		t.Fatalf("起動画面の矩形 %s（ウィンドウは 1440×900）", r)
	}
}

func TestRouteInLeftPanelMovesToTheOtherPage(t *testing.T) {
	// 3 列の左の欄にある分岐のカードの、撮った道のボタンは、その道の頁へ #t= 付きで移る。
	p := openTapePage(t, desktop)
	base := forkSite(t)
	loadPlain(t, p, base+"/light/")
	if err := p.Eval(`(() => { openChapters(true); $("bfork0").querySelector('.route[data-r="1"]').click(); return true; })()`, nil); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(`location.pathname.startsWith("/dark/") && location.hash === "#t=3.2"`, 30*time.Second); err != nil {
		t.Fatalf("dark の頁へ移っていない: %v", err)
	}
}

func TestInfoInPanelShowsTheNodeOfTheLine(t *testing.T) {
	// 広い画面の右の欄の「このコマ」も、今の行のノードを出す。
	p := openTapePage(t, desktop)
	loadPlain(t, p, forkSite(t)+"/light/")
	if body := evalString(t, p, `(() => { seek(4.5); openInfo(); return $("infoBody").textContent; })()`); !strings.Contains(body, "ノードTower") {
		t.Fatalf("このコマ: %s", body)
	}
}

func TestPlayLinkOnWideUsesTheNodeAfterTheJump(t *testing.T) {
	// 広い画面の「ここから遊ぶ」も、<<jump>> の先のノードで talk= を作る。
	p := openTapePage(t, desktop)
	loadPlain(t, p, forkSite(t)+"/light/")
	if href := evalString(t, p, `(() => { seek(4.5); $("playHereBtn").addEventListener("click", e => e.preventDefault()); $("playHereBtn").click(); return $("playHereBtn").href; })()`); !strings.Contains(href, "?talk=Tower&line=13&") {
		t.Fatalf("href: %s", href)
	}
}
