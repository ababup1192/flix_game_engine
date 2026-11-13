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

const forkPath = "testdata/fork.tape.json"

// forkTape は分岐の見本（3.2 秒に 2 択・行 10）を picked で選んだ物にする。
func forkTape(t *testing.T, picked int) []byte {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(readFile(t, forkPath), &m); err != nil {
		t.Fatal(err)
	}
	m["choices"].([]any)[0].(map[string]any)["picked"] = picked
	b, _ := json.Marshal(m)
	return b
}

func parsed(t *testing.T, raw []byte) *Tape {
	t.Helper()
	tp, err := Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	return tp
}

func TestGroupBranchesLinkTheOtherRoute(t *testing.T) {
	got := GroupBranches([]string{"light", "dark"}, []*Tape{parsed(t, forkTape(t, 0)), parsed(t, forkTape(t, 1))})
	want := []Branch{{T: 3.2, Line: 10, Question: "今夜は風が強い", Routes: []Route{
		{Label: "灯をともす", Note: "このテープ", Here: true},
		{Label: "眠る", Note: "dark のテープ", Href: "../dark/#t=3.2"},
	}}}
	a, _ := json.Marshal(got[0])
	w, _ := json.Marshal(want)
	if string(a) != string(w) {
		t.Fatalf("light の branches\n got: %s\nwant: %s", a, w)
	}
}

func TestGroupBranchesMarkTheOtherTapeHere(t *testing.T) {
	got := GroupBranches([]string{"light", "dark"}, []*Tape{parsed(t, forkTape(t, 0)), parsed(t, forkTape(t, 1))})
	if len(got[1]) != 1 || !got[1][0].Routes[1].Here || got[1][0].Routes[0].Href != "../light/#t=3.2" {
		t.Fatalf("dark の branches: %+v", got[1])
	}
}

func TestGroupSkipsChoiceWhereEveryTapePickedTheSame(t *testing.T) {
	got := GroupBranches([]string{"a", "b"}, []*Tape{parsed(t, forkTape(t, 0)), parsed(t, forkTape(t, 0))})
	if len(got[0]) != 0 || len(got[1]) != 0 {
		t.Fatalf("同じ道しか撮っていないのに分岐ができた: %+v", got)
	}
}

func TestParseAcceptsTapeWithoutChoices(t *testing.T) {
	if tp := parsed(t, readFile(t, otherPath)); len(tp.Choices) != 0 {
		t.Fatalf("choices の無い tape.json から選択肢が読めた: %+v", tp.Choices)
	}
}

func TestParseRejectsPickedOutsideOptions(t *testing.T) {
	if _, err := Parse(forkTape(t, 2)); err == nil || !strings.Contains(err.Error(), "picked") {
		t.Fatalf("options の外の picked を通した: %v", err)
	}
}

func TestParseArgsTakesGroupFolders(t *testing.T) {
	opt, err := parseArgs([]string{"--group", "debug/tape/a", "debug/tape/b"})
	if err != nil || strings.Join(opt.Group, " ") != "debug/tape/a debug/tape/b" {
		t.Fatalf("--group: %+v %v", opt, err)
	}
}

func TestParseArgsRejectsGroupOfOne(t *testing.T) {
	if _, err := parseArgs([]string{"--group", "debug/tape/a"}); err == nil {
		t.Fatal("--group に 1 つだけを通した")
	}
}

// forkSite は分岐の見本を 2 本（light は 1 つ目・dark は 2 つ目を選んだ）並べて --group で束ね、1 つの origin に置く。
func forkSite(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	var dirs []string
	for i, name := range []string{"light", "dark"} {
		d := filepath.Join(root, name)
		if err := os.Mkdir(d, 0o755); err != nil {
			t.Fatal(err)
		}
		makeVideo(t, filepath.Join(d, VideoFile), 6.2)
		if err := os.WriteFile(filepath.Join(d, TapeFile), forkTape(t, i), 0o644); err != nil {
			t.Fatal(err)
		}
		dirs = append(dirs, d)
	}
	if _, err := BuildGroup(dirs, "abc1234", ""); err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.FileServer(http.Dir(root)))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestBuildGroupStopsOnSameFolderName(t *testing.T) {
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
	if _, err := BuildGroup([]string{a, b}, "abc1234", ""); err == nil || !strings.Contains(err.Error(), "intro") {
		t.Fatalf("同じフォルダ名を通した: %v", err)
	}
}

// 撮った道のボタンは、その道の頁へ移り、#t= の秒から開く。
func TestRouteWithHrefMovesToTheOtherPageAtItsTime(t *testing.T) {
	p := openTapePage(t)
	base := forkSite(t)
	loadPlain(t, p, base+"/light/")
	if err := p.Eval(`(() => { openChapters(true); document.querySelector('.route[data-r="1"]').click(); return true; })()`, nil); err != nil {
		t.Fatal(err)
	}
	if err := p.WaitFor(`location.pathname === "/dark/" && location.hash === "#t=3.2" && typeof video !== "undefined" && video.readyState >= 1 && Math.abs(video.currentTime - 3.2) < 0.05`, 30*time.Second); err != nil {
		var where string
		_ = p.Eval(`location.href + " t=" + (typeof video !== "undefined" ? video.currentTime : "-")`, &where)
		t.Fatalf("dark の頁の 3.2 秒へ移っていない（%s）: %v", where, err)
	}
	noErrors(t, p, "dark")
}

// この頁の道のボタンは、頁を移らずにその選択肢の秒へ送る。
func TestRouteHereSeeksOnThisPage(t *testing.T) {
	p := openTapePage(t)
	base := forkSite(t)
	loadPlain(t, p, base+"/light/")
	var got struct {
		Path string
		T    float64
	}
	if err := p.Eval(`(() => { seek(0.5); openChapters(true); document.querySelector('.route[data-r="0"]').click(); return { Path: location.pathname, T: video.currentTime }; })()`, &got); err != nil {
		t.Fatal(err)
	}
	if got.Path != "/light/" || got.T < 3.2 || got.T > 3.3 {
		t.Fatalf("この頁の 3.2 秒へ送っていない: %+v", got)
	}
}

// ノードをまたいだ行の「ここから遊ぶ」は、その行のノードで talk= を作る。
func TestPlayLinkUsesTheNodeOfTheLine(t *testing.T) {
	p := openTapePage(t)
	base := forkSite(t)
	loadPlain(t, p, base+"/light/")
	var hrefs struct{ Shore, Tower string }
	if err := p.Eval(`({ Shore: playLink(2.5).href, Tower: playLink(4.5).href })`, &hrefs); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(hrefs.Shore, "?talk=Shore&line=4&") || !strings.Contains(hrefs.Tower, "?talk=Tower&line=13&") {
		t.Fatalf("行のノードで talk= を作っていない: %+v", hrefs)
	}
}

// 分岐のカードは問い・道の名前と、隣の頁の道のテープの名前を出す。
func TestForkCardShowsRoutesFromTheGroup(t *testing.T) {
	p := openTapePage(t)
	base := forkSite(t)
	loadPlain(t, p, base+"/light/")
	var card struct {
		Forks  int
		Routes string
		Chap   string
	}
	if err := p.Eval(`(() => { openChapters(true); return { Forks: $("forks").children.length,
	  Routes: [...document.querySelectorAll(".route")].map(n => n.textContent).join("|"), Chap: $("chapBody").querySelector(".ctxline").textContent }; })()`, &card); err != nil {
		t.Fatal(err)
	}
	if card.Forks != 1 || card.Routes != "✓ 灯をともすこのテープ|眠るdark のテープ" || strings.Contains(card.Chap, "例") {
		t.Fatalf("分岐のカード: %+v", card)
	}
}
