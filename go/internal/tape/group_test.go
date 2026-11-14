package tape

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const forkPath = "testdata/fork.tape.json"

// forkTapeWith は分岐の見本（3.2 秒に 2 択・行 10）を読み、edit で直した tape.json を返す。
func forkTapeWith(t *testing.T, edit func(m map[string]any)) []byte {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(readFile(t, forkPath), &m); err != nil {
		t.Fatal(err)
	}
	edit(m)
	b, _ := json.Marshal(m)
	return b
}

// forkTape は分岐の見本を picked で選んだ物にする。
func forkTape(t *testing.T, picked int) []byte {
	t.Helper()
	return forkTapeWith(t, func(m map[string]any) { firstChoice(m)["picked"] = picked })
}

func firstChoice(m map[string]any) map[string]any { return m["choices"].([]any)[0].(map[string]any) }

func parsed(t *testing.T, raw []byte) *Tape {
	t.Helper()
	tp, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return tp
}

// lightDark は 1 つ目を選んだ light と 2 つ目を選んだ dark の branches。
func lightDark(t *testing.T) [][]Branch {
	t.Helper()
	return GroupBranches([]string{"light", "dark"}, []*Tape{parsed(t, forkTape(t, 0)), parsed(t, forkTape(t, 1))})
}

func TestGroupBranchesLinkTheOtherRoute(t *testing.T) {
	// light の分岐: 選んだ道は「このテープ」、もう 1 本は dark の頁のその秒への道。問いは直前の台詞の最初の文。
	want := []Branch{{T: 3.2, Line: 10, Question: "今夜は風が強い", Routes: []Route{
		{Label: "灯をともす", Note: "このテープ", Here: true},
		{Label: "眠る", Note: "dark のテープ", Href: "../dark/index.html#t=3.2"},
	}}}
	a, _ := json.Marshal(lightDark(t)[0])
	w, _ := json.Marshal(want)
	if string(a) != string(w) {
		t.Fatalf("light の branches\n got: %s\nwant: %s", a, w)
	}
}

func TestGroupBranchesMarkThisTapesRouteHere(t *testing.T) {
	// dark の分岐では 2 つ目の道が「このテープ」。
	if !lightDark(t)[1][0].Routes[1].Here {
		t.Fatalf("dark の 2 つ目の道が here でない: %+v", lightDark(t)[1])
	}
}

func TestGroupBranchesLinkBackToTheFirstTape(t *testing.T) {
	// dark の 1 つ目の道は light の頁への道。
	if got := lightDark(t)[1][0].Routes[0].Href; got != "../light/index.html#t=3.2" {
		t.Fatalf("dark から light への道: %q", got)
	}
}

func TestGroupSkipsChoiceWhereEveryTapePickedTheSame(t *testing.T) {
	// どのテープも同じ番号を選んだ選択肢は分岐にしない。
	got := GroupBranches([]string{"a", "b"}, []*Tape{parsed(t, forkTape(t, 0)), parsed(t, forkTape(t, 0))})
	if countBranches(got) != 0 {
		t.Fatalf("同じ道しか撮っていないのに分岐ができた: %+v", got)
	}
}

func TestGroupUsesTheLastPickOfTheSameLine(t *testing.T) {
	// 1 本のテープが同じ行の選択肢を 2 回通ったら、最後に選んだ番号がそのテープの道（1 回目に「眠る」、選び直して「灯をともす」）。
	again := forkTapeWith(t, func(m map[string]any) {
		first := firstChoice(m)
		first["picked"] = 1
		second := map[string]any{"t": 4.0, "line": 10, "node": "Shore", "options": first["options"], "picked": 0}
		m["choices"] = append(m["choices"].([]any), second)
	})
	got := GroupBranches([]string{"again", "dark"}, []*Tape{parsed(t, again), parsed(t, forkTape(t, 1))})
	if len(got[0]) != 1 || !got[0][0].Routes[0].Here {
		t.Fatalf("最後に選んだ道が here でない: %+v", got[0])
	}
}

func TestGroupRouteNotFilmedHasNoHref(t *testing.T) {
	// 3 つの道のうち、どのテープも選ばなかった道は「まだ撮っていない」で、移り先が無い。
	three := func(picked int) []byte {
		return forkTapeWith(t, func(m map[string]any) {
			firstChoice(m)["options"] = []any{"灯をともす", "眠る", "海を見る"}
			firstChoice(m)["picked"] = picked
		})
	}
	got := GroupBranches([]string{"light", "dark"}, []*Tape{parsed(t, three(0)), parsed(t, three(1))})
	if r := got[0][0].Routes[2]; r.Href != "" || r.Note != "まだ撮っていない" {
		t.Fatalf("撮っていない道: %+v", r)
	}
}

func TestGroupHrefEscapesTheFolderName(t *testing.T) {
	// フォルダ名は URL の道に逃がして載せる。
	got := GroupBranches([]string{"light", "dark night"}, []*Tape{parsed(t, forkTape(t, 0)), parsed(t, forkTape(t, 1))})
	if h := got[0][0].Routes[1].Href; h != "../dark%20night/index.html#t=3.2" {
		t.Fatalf("href: %q", h)
	}
}

func TestGroupQuestionFallsBackToTheNode(t *testing.T) {
	// choices に question が無ければ、問いはノードの名前。
	silent := forkTapeWith(t, func(m map[string]any) { delete(firstChoice(m), "question") })
	got := GroupBranches([]string{"light", "dark"}, []*Tape{parsed(t, silent), parsed(t, forkTape(t, 1))})
	if q := got[0][0].Question; q != "Shore" {
		t.Fatalf("問い: %q", q)
	}
}

func TestGroupQuestionIsCutToALineOfTheCard(t *testing.T) {
	// 長い問いは 14 字目を「…」にして切る。
	long := forkTapeWith(t, func(m map[string]any) {
		firstChoice(m)["question"] = "灯台の階段は長く、いくら上っても先が見えない"
	})
	got := GroupBranches([]string{"light", "dark"}, []*Tape{parsed(t, long), parsed(t, forkTape(t, 1))})
	if q := got[0][0].Question; q != "灯台の階段は長く、いくら上…" {
		t.Fatalf("問い: %q", q)
	}
}

func TestRouteTargetsReadsTheBranchesOfThePage(t *testing.T) {
	// 置いた頁の branches から、道の先のフォルダ名を逃がしを戻して読む（この頁の道と移り先の無い道は数えない）。
	tp := parsed(t, forkTape(t, 0))
	b, _ := json.Marshal([]Branch{{Routes: []Route{{Here: true}, {Href: "../dark%20night/index.html#t=3.2"}, {Note: "まだ撮っていない"}}}})
	tp.raw["branches"] = b
	page, err := Render(tp, "abc1234", sampleStrip, Splash{})
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(routeTargets(page), ","); got != "dark night" {
		t.Fatalf("道の先: %q", got)
	}
}

func TestParseAcceptsTapeWithoutChoices(t *testing.T) {
	// choices の無い tape.json（前の版のテンプレート）も読める。
	if tp := parsed(t, readFile(t, otherPath)); len(tp.Choices) != 0 {
		t.Fatalf("choices の無い tape.json から選択肢が読めた: %+v", tp.Choices)
	}
}

func TestParseRejectsPickedOutsideOptions(t *testing.T) {
	// picked が options の外なら止める。
	if _, err := Parse(forkTape(t, 2)); err == nil || !strings.Contains(err.Error(), "picked") {
		t.Fatalf("options の外の picked を通した: %v", err)
	}
}

func TestParseArgsTakesGroupFolders(t *testing.T) {
	// --group の後のフォルダを全部受け取る。
	opt, err := parseArgs([]string{"--group", "debug/tape/a", "debug/tape/b"})
	if err != nil || strings.Join(opt.Group, " ") != "debug/tape/a debug/tape/b" {
		t.Fatalf("--group: %+v %v", opt, err)
	}
}

func TestParseArgsRejectsGroupOfOne(t *testing.T) {
	// --group に 1 つだけなら止める（1 つは --dir）。
	if _, err := parseArgs([]string{"--group", "debug/tape/a"}); err == nil {
		t.Fatal("--group に 1 つだけを通した")
	}
}

func TestParseArgsRejectsDirAndGroupTogether(t *testing.T) {
	// --dir と --group を両方渡したら止める。
	if _, err := parseArgs([]string{"--dir", "x", "--group", "a", "b"}); err == nil {
		t.Fatal("--dir と --group の両方を通した")
	}
}

// writeForkDirs は root の下に names のフォルダを作り、tape.json（tapes の同じ並び）と動画を置く。
func writeForkDirs(t *testing.T, root string, names []string, tapes [][]byte) []string {
	t.Helper()
	var dirs []string
	for i, name := range names {
		d := filepath.Join(root, name)
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		makeVideo(t, filepath.Join(d, VideoFile), 6.2)
		if err := os.WriteFile(filepath.Join(d, TapeFile), tapes[i], 0o644); err != nil {
			t.Fatal(err)
		}
		dirs = append(dirs, d)
	}
	return dirs
}

func TestBuildGroupWarnsWhenNoBranchIsMade(t *testing.T) {
	// 分岐が 1 つもできなければ 1 行言う（頁は作る）。
	dirs := writeForkDirs(t, t.TempDir(), []string{"a", "b"}, [][]byte{forkTape(t, 0), forkTape(t, 0)})
	var warn bytes.Buffer
	if _, err := BuildGroup(Options{Group: dirs, Commit: "abc1234"}, &warn); err != nil {
		t.Fatal(err)
	}
	if strings.Count(warn.String(), "\n") != 1 || !strings.Contains(warn.String(), "分岐が 1 つもできなかった") {
		t.Fatalf("言った言葉: %q", warn.String())
	}
}

func TestBuildGroupStopsOnDifferentGame(t *testing.T) {
	// game の違うテープは束ねない。
	other := forkTapeWith(t, func(m map[string]any) { m["game"] = "another" })
	dirs := writeForkDirs(t, t.TempDir(), []string{"a", "b"}, [][]byte{forkTape(t, 0), other})
	if _, err := BuildGroup(Options{Group: dirs, Commit: "abc1234"}, nil); err == nil || !strings.Contains(err.Error(), "another") {
		t.Fatalf("game の違うテープを束ねた: %v", err)
	}
}

func TestBuildGroupStopsOnDifferentYarn(t *testing.T) {
	// .yarn の違うテープは束ねない。
	other := forkTapeWith(t, func(m map[string]any) { m["yarn"] = "assets/talk/day.yarn" })
	dirs := writeForkDirs(t, t.TempDir(), []string{"a", "b"}, [][]byte{forkTape(t, 0), other})
	if _, err := BuildGroup(Options{Group: dirs, Commit: "abc1234"}, nil); err == nil || !strings.Contains(err.Error(), "day.yarn") {
		t.Fatalf(".yarn の違うテープを束ねた: %v", err)
	}
}

func TestBuildGroupStopsOnSameFolderName(t *testing.T) {
	// 別の場所でもフォルダ名が同じなら止める（隣の頁への道はフォルダ名で引く）。
	root := t.TempDir()
	a, b := filepath.Join(root, "x", "intro"), filepath.Join(root, "y", "intro")
	for _, d := range []string{a, b} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, TapeFile), forkTape(t, 0), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := BuildGroup(Options{Group: []string{a, b}, Commit: "abc1234"}, nil); err == nil || !strings.Contains(err.Error(), "intro") {
		t.Fatalf("同じフォルダ名を通した: %v", err)
	}
}

// forkSite は分岐の見本を 2 本（light は 1 つ目・dark は 2 つ目を選んだ）並べて --group で束ね、1 つの origin に置く。
func forkSite(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	dirs := writeForkDirs(t, root, []string{"light", "dark"}, [][]byte{forkTape(t, 0), forkTape(t, 1)})
	if _, err := BuildGroup(Options{Group: dirs, Commit: "abc1234"}, nil); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.FileServer(http.Dir(root)))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestRouteWithHrefMovesToTheOtherPage(t *testing.T) {
	// 撮った道のボタンは、その道の頁へ #t= 付きで移る。
	p := openTapePage(t, phone)
	base := forkSite(t)
	loadPlain(t, p, base+"/light/")
	if err := p.Eval(`(() => { openChapters(true); document.querySelector('.route[data-r="1"]').click(); return true; })()`, nil); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(`location.pathname.startsWith("/dark/") && location.hash === "#t=3.2"`, 30*time.Second); err != nil {
		t.Fatalf("dark の頁へ移っていない: %v", err)
	}
}

// startTimeOf は url を開いて動画が読めた後の秒。
func startTimeOf(t *testing.T, url string) float64 {
	t.Helper()
	p := openTapePage(t, phone)
	loadPlain(t, p, url)
	waitSeeked(t, p)
	var sec float64
	if err := p.Eval(`video.currentTime`, &sec); err != nil {
		t.Fatal(err)
	}
	noErrors(t, p, url)
	return sec
}

func TestHashTimeSeeksWhenOpened(t *testing.T) {
	// #t=3.2 で開くと 3.2 秒から。
	if sec := startTimeOf(t, forkSite(t)+"/dark/index.html#t=3.2"); sec < 3.15 || sec > 3.25 {
		t.Fatalf("3.2 秒へ送っていない: %v", sec)
	}
}

func TestNoHashStartsAtZero(t *testing.T) {
	// #t が無ければ 0 秒から。
	if sec := startTimeOf(t, forkSite(t)+"/dark/index.html"); sec != 0 {
		t.Fatalf("0 秒からでない: %v", sec)
	}
}

func TestHashTimeZeroStartsAtZero(t *testing.T) {
	// #t=0 は 0 秒から。
	if sec := startTimeOf(t, forkSite(t)+"/dark/index.html#t=0"); sec != 0 {
		t.Fatalf("0 秒からでない: %v", sec)
	}
}

func TestRouteHereSeeksOnThisPage(t *testing.T) {
	// この頁の道のボタンは、頁を移らずにその選択肢の秒へ送る。
	p := openTapePage(t, phone)
	loadPlain(t, p, forkSite(t)+"/light/")
	var sec float64
	if err := p.Eval(`(() => { seek(0.5); openChapters(true); document.querySelector('.route[data-r="0"]').click(); return location.pathname === "/light/" ? video.currentTime : -1; })()`, &sec); err != nil {
		t.Fatal(err)
	}
	if sec < 3.2 || sec > 3.3 {
		t.Fatalf("この頁の 3.2 秒へ送っていない: %v", sec)
	}
}

// evalOnFork は light の頁を開いて js の値を返す。
func evalOnFork[T any](t *testing.T, js string) T {
	t.Helper()
	p := openTapePage(t, phone)
	loadPlain(t, p, forkSite(t)+"/light/")
	var v T
	if err := p.Eval(js, &v); err != nil {
		t.Fatal(err)
	}
	noErrors(t, p, "light")
	return v
}

func TestPlayLinkUsesTheNodeOfTheFirstNode(t *testing.T) {
	// 最初のノードの行の「ここから遊ぶ」はそのノードで talk= を作る。
	if href := evalOnFork[string](t, `playLink(2.5).href`); !strings.Contains(href, "?talk=Shore&line=4&") {
		t.Fatalf("href: %s", href)
	}
}

func TestPlayLinkUsesTheNodeAfterTheJump(t *testing.T) {
	// <<jump>> の先のノードの行は、先のノードで talk= を作る。
	if href := evalOnFork[string](t, `playLink(4.5).href`); !strings.Contains(href, "?talk=Tower&line=13&") {
		t.Fatalf("href: %s", href)
	}
}

func TestScriptRefUsesTheNodeOfTheLine(t *testing.T) {
	// シナリオの行への注釈の node はその行のノード。
	if node := evalOnFork[string](t, `scriptRef(13).node`); node != "Tower" {
		t.Fatalf("node: %s", node)
	}
}

func TestInfoSheetShowsTheNodeOfTheLine(t *testing.T) {
	// 「このコマ」のノードの欄は、今の行のノード。
	if body := evalOnFork[string](t, `(() => { seek(4.5); openInfo(); return $("infoBody").textContent; })()`); !strings.Contains(body, "ノードTower") {
		t.Fatalf("このコマ: %s", body)
	}
}

func TestExportTellsToStartFromTheScriptNode(t *testing.T) {
	// 書き出しの reproduce.talk は、注釈の script.node と script.line で始める書き方。
	if md := evalOnFork[string](t, `buildPrompt()`); !strings.Contains(md, "start talk node=<script.node> line=<script.line>") {
		t.Fatalf("書き出し: %s", md)
	}
}

func TestForkMarkerIsShownOnTheTimeline(t *testing.T) {
	// --group で分岐ができた頁は、タイムラインに分岐のマーカーが 1 つ出る。
	if n := evalOnFork[int](t, `$("forks").children.length`); n != 1 {
		t.Fatalf("分岐のマーカー: %d", n)
	}
}

func TestForkCardShowsTheRoutesFromTheGroup(t *testing.T) {
	// 分岐のカードの道は、選んだ道（✓ このテープ）と、隣のテープの道。
	routes := evalOnFork[string](t, `(() => { openChapters(true); return [...document.querySelectorAll(".route")].map(n => n.textContent).join("|"); })()`)
	if routes != "✓ 灯をともすこのテープ|眠るdark のテープ" {
		t.Fatalf("道: %s", routes)
	}
}

func TestForkCardHasNoExampleLabel(t *testing.T) {
	// 撮った分岐には「例」の文言が出ない。
	if line := evalOnFork[string](t, `(() => { openChapters(true); return $("chapBody").textContent; })()`); strings.Contains(line, "例") {
		t.Fatalf("例の文言が出た: %s", line)
	}
}

func TestBranchBeforeTheFirstMarkIsInTheFirstSceneCard(t *testing.T) {
	// 最初の mark より前の分岐も、最初のシーンの下にカードが出る。
	n := evalOnFork[int](t, `(() => { TAPE.scenes[0].t = 3.5; openChapters(true); return document.querySelectorAll(".forkcard").length; })()`)
	if n != 1 {
		t.Fatalf("分岐のカード: %d", n)
	}
}

func TestThreeRoutesWrapToTheNextRow(t *testing.T) {
	// 道が 3 本の時は 2 本と 1 本の 2 行に折れる（2 本の時は 1 行）。
	top := evalOnFork[float64](t, `(() => { TAPE.branches[0].routes.push({ label: "海を見る", note: "まだ撮っていない", here: false });
	  openChapters(true); const r = document.querySelectorAll(".route"); return r[2].offsetTop - r[0].offsetTop; })()`)
	if top <= 0 {
		t.Fatalf("3 本目が 1 行目に並んだ: %v", top)
	}
}
