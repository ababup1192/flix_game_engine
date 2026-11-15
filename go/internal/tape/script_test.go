package tape

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// gameTapeDir は root をゲームのルート（シナリオつき）にし、その debug/tape/x に other.tape.json と動画を置いたフォルダを返す。
func gameTapeDir(t *testing.T, withGame bool) string {
	t.Helper()
	root := t.TempDir()
	if withGame {
		writeGame(t, root)
	}
	dir := filepath.Join(root, "debug", "tape", "x")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	makeVideo(t, filepath.Join(dir, VideoFile), 1)
	if err := os.WriteFile(filepath.Join(dir, TapeFile), readFile(t, otherPath), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func builtPage(t *testing.T, dir string) string {
	t.Helper()
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	return string(readFile(t, filepath.Join(dir, IndexFile)))
}

func TestBuildEmbedsGraphFromTheYarnFolder(t *testing.T) {
	// ゲームのルート（project.json）から tape.json の yarn のフォルダを読み、分岐のグラフを頁に埋める。
	if page := builtPage(t, gameTapeDir(t, true)); !strings.Contains(page, `"graph":{"h":{"w":`) || !strings.Contains(page, `"id":"Sleep"`) {
		t.Fatal("頁にグラフが入っていない")
	}
}

func TestBuildEmbedsReadingScript(t *testing.T) {
	// 同じフォルダからシナリオ原稿の Markdown を作って頁に埋める（話し手は id のまま・選択肢は ◆）。
	if page := builtPage(t, gameTapeDir(t, true)); !strings.Contains(page, `# シナリオ原稿 — 灯台守の夜`) || !strings.Contains(page, `◆ 選ぶ`) {
		t.Fatal("頁にシナリオ原稿が入っていない")
	}
}

func TestBuildWithoutGameRootHasNoGraph(t *testing.T) {
	// ゲームのルートが見つからなければ、グラフもシナリオ原稿も埋めない。
	if page := builtPage(t, gameTapeDir(t, false)); strings.Contains(page, `"graph":`) || strings.Contains(page, `"script":`) {
		t.Fatal("シナリオの無い頁にグラフかシナリオ原稿が入った")
	}
}

func TestScriptDownloadSavesGameNamedMarkdown(t *testing.T) {
	// 左の欄の「シナリオ原稿 .md」は、埋めたシナリオ原稿を <ゲームの名前>.md で落とす。
	p := openTapePage(t, desktop)
	load(t, p, buildSite(t).tapeURL)
	var got string
	if err := p.Eval(`(async () => {
	  let a = null; HTMLAnchorElement.prototype.click = function () { a = this; };
	  openChapters(false); $("binBody").querySelector(".scriptdl").click();
	  for (let i = 0; i < 50 && !a; i++) await new Promise(r => setTimeout(r, 20));
	  return a.download + "\n" + await (await fetch(a.href)).text();
	})()`, &got); err != nil {
		t.Fatal(err)
	}
	name, md, _ := strings.Cut(got, "\n")
	if name != "blood-scale.md" || !strings.Contains(md, "# シナリオ原稿") || !strings.Contains(md, "〔Lair〕") {
		t.Fatalf("落とした物: %s\n%.200s", name, md)
	}
}

func TestPhoneGraphFillsTheScreenVertically(t *testing.T) {
	// スマホの形で「グラフ」を選ぶと、画面いっぱいに縦に並べたグラフと「シナリオ原稿 .md」が出て、頁は横へはみ出さない。
	p := openTapePage(t, phone)
	load(t, p, buildSite(t).tapeURL)
	if !evalBool(t, p, `(() => { $("modes").querySelector('[data-m="graph"]').click(); const r = $("graphView").getBoundingClientRect(), svg = $("gwrap").querySelector("svg");
	  return r.top === 0 && r.height === innerHeight && getComputedStyle($("gvScript")).display !== "none" && svg.getAttribute("viewBox").endsWith(TAPE.graph.v.w + " " + TAPE.graph.v.h)
	    && $("gwrap").querySelectorAll(".gbox").length === TAPE.graph.v.nodes.length && document.scrollingElement.scrollWidth <= innerWidth; })()`) {
		t.Fatal("スマホのグラフが画面いっぱいの縦のグラフでないか、横へはみ出す")
	}
}

func TestWideGraphReplacesTheVideoAndKeepsTheTimeline(t *testing.T) {
	// 広い画面で「グラフ」を選ぶと、真ん中の動画の所がグラフに替わり、タイムラインは残り、ノードの欄は右の欄に出る。
	p := openTapePage(t, desktop)
	load(t, p, buildSite(t).tapeURL)
	if !evalBool(t, p, `(() => { setView("graph"); return getComputedStyle(document.querySelector(".preview")).display === "none" && $("graphView").offsetWidth > 0
	  && document.querySelector(".timeline").offsetHeight > 0 && $("nodePanel").parentNode === $("insp") && $("nodePanel").offsetHeight > 0; })()`) {
		t.Fatal("広い画面のグラフの形が崩れている")
	}
}

func TestTapeWithoutGraphShowsNoGraphOrDownload(t *testing.T) {
	// シナリオの無いテープ（graph の無い TAPE）は、グラフも「シナリオ原稿 .md」も出さない。
	p := openTapePage(t, desktop)
	load(t, p, buildSite(t).otherURL)
	if !evalBool(t, p, `(() => { openChapters(true); return getComputedStyle($("modes")).display === "none" && !document.querySelector(".scriptrow") && viewMode === "video"; })()`) {
		t.Fatal("シナリオの無いテープにグラフかダウンロードが出た")
	}
}

func TestBuildWithBrokenVocabStillWritesThePage(t *testing.T) {
	// vocab.json が壊れていても頁は作り、グラフとシナリオ原稿は載せずに注意を出す。
	dir := gameTapeDir(t, true)
	if err := os.WriteFile(filepath.Join(dir, "..", "..", "..", "assets", "talk", "vocab.json"), []byte("{"), 0o644); err != nil {
		t.Fatal(err)
	}
	var warn strings.Builder
	if _, err := Build(Options{Dir: dir, Commit: "abc1234", Warn: &warn}); err != nil {
		t.Fatal(err)
	}
	page := string(readFile(t, filepath.Join(dir, IndexFile)))
	if strings.Contains(page, `"graph":`) || !strings.Contains(warn.String(), "シナリオ") {
		t.Fatalf("注意: %q", warn.String())
	}
}
