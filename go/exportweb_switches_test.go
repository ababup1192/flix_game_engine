package main

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

type webSwitchCase struct {
	Name     string            `json:"name"`
	Search   string            `json:"search"`
	Dev      map[string]any    `json:"dev"`
	Switches map[string]any    `json:"switches"`
	Legacy   []json.RawMessage `json:"legacy"`
	Unknown  []string          `json:"unknown"`
}

func loadWebSwitchCases(t *testing.T) []webSwitchCase {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("..", "testdata", "web-switches.cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Cases []webSwitchCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	return doc.Cases
}

// switchesAsMap は既定と違う欄だけを JSON の値の形にする（cases の switches と比べる形）。
func switchesAsMap(t *testing.T, s webPageSwitches) map[string]any {
	t.Helper()
	raw, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]any{}
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestParseWebDevWordsMatchesPageReaderTable(t *testing.T) {
	for _, c := range loadWebSwitchCases(t) {
		if c.Dev != nil || len(c.Legacy) > 0 {
			continue
		}
		q, err := url.ParseQuery(strings.TrimPrefix(c.Search, "?"))
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		if q.Has("sw") {
			continue
		}
		got, err := parseWebDevWords(q.Get("fge"))
		if len(c.Unknown) > 0 {
			if err == nil {
				t.Errorf("%s: 知らない語 %v は誤りのはず", c.Name, c.Unknown)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", c.Name, err)
			continue
		}
		want := c.Switches
		if want == nil {
			want = map[string]any{}
		}
		if g := switchesAsMap(t, got); !reflect.DeepEqual(g, want) {
			t.Errorf("%s: %v のはず: %v", c.Name, want, g)
		}
	}
}

func TestWebPageSwitchesInitScriptKeepsEarlierDev(t *testing.T) {
	got := webPageSwitches{Capture: 6, Backend: "webgl2"}.initScript()
	if got != `window.fgeDev = Object.assign(window.fgeDev || {}, {"backend":"webgl2","capture":6});` {
		t.Errorf("既定でない欄だけを前の fgeDev に足す script のはず: %s", got)
	}
}

func TestWebCheckRejectsMeasureFlagsWithoutBrowser(t *testing.T) {
	var out, errOut strings.Builder
	if code := cmdWebCheck(&out, &errOut, []string{t.TempDir(), "--cpu", "4"}, false); code != 2 {
		t.Errorf("--cpu は --browser と一緒でなければ呼び方の誤り（2）のはず: %d %s", code, errOut.String())
	}
}

func TestWebCheckRejectsCPUBelowOne(t *testing.T) {
	var out, errOut strings.Builder
	if code := cmdWebCheck(&out, &errOut, []string{t.TempDir(), "--browser", "--cpu", "0.5"}, false); code != 2 {
		t.Errorf("--cpu は 1 以上の倍率のはず: %d %s", code, errOut.String())
	}
}

func TestMeasureConditionsLabelNamesDelayAndCPU(t *testing.T) {
	got := webMeasureConditions{CPU: 4, TapDelay: 1500 * time.Millisecond}.label()
	if got != "1.5 秒置いて押す・CPU 4 倍" {
		t.Errorf("条件の字は %q のはず: %q", "1.5 秒置いて押す・CPU 4 倍", got)
	}
}

func TestOpenURLGivesFgeDevToPageWithSwitchesReader(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<script>function fgePageSwitches() {}</script>"), 0o644); err != nil {
		t.Fatal(err)
	}
	url, script := webPageSwitches{Capture: 3}.openURL("http://h/index.html", dir)
	if url != "http://h/index.html" || !strings.Contains(script, `"capture":3`) {
		t.Errorf("読み手を持つ頁は URL にクエリを付けず fgeDev で渡すはず: %s / %s", url, script)
	}
}

func TestOpenURLFallsBackToOldKeysForOldEnginePage(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<script>/* 前の engine */</script>"), 0o644); err != nil {
		t.Fatal(err)
	}
	url, script := webPageSwitches{Capture: 120, UsedAssets: true, Backend: "webgl2", Net: "4g", Deferred: "all"}.openURL("http://h/index.html", dir)
	if url != "http://h/index.html?capture=120&usedAssets=1&backend=webgl2&net=4g&deferred=all" || script != "" {
		t.Errorf("前の engine の頁は前の鍵のクエリで渡すはず: %s / %s", url, script)
	}
}

// fgeReadSwitches の答えから既定と違う欄だけを残し、cases と同じ形 { switches, legacy, unknown } で返す式。
const webSwitchesTableProbe = `(() => {
  var d = fgeSwitchDefaults();
  return CASES.map(function (c) {
    var r = fgeReadSwitches(c.search, c.dev || null);
    var s = {};
    Object.keys(r.switches).forEach(function (k) { if (r.switches[k] !== d[k]) s[k] = r.switches[k]; });
    return { switches: s, legacy: r.legacy, unknown: r.unknown };
  });
})()`

func TestPageSwitchesReaderTable(t *testing.T) {
	skipWithoutChrome(t)
	cases := loadWebSwitchCases(t)
	src, err := os.ReadFile(filepath.Join("..", "engine_web", "js", webSwitchesSource))
	if err != nil {
		t.Fatal(err)
	}
	casesJSON, err := json.Marshal(cases)
	if err != nil {
		t.Fatal(err)
	}
	page, err := cdp.OpenPage(cdp.PageOptions{InitScript: string(src) + "\nvar CASES = " + string(casesJSON) + ";"})
	if err != nil {
		t.Fatal(err)
	}
	defer page.Close()
	if err := page.Navigate("data:text/html,<p>t</p>"); err != nil {
		t.Fatal(err)
	}
	if err := page.WaitFor(`typeof fgeReadSwitches === "function" && document.readyState === "complete"`, 10*time.Second); err != nil {
		t.Fatal(err)
	}
	var got []struct {
		Switches map[string]any    `json:"switches"`
		Legacy   []json.RawMessage `json:"legacy"`
		Unknown  []string          `json:"unknown"`
	}
	if err := page.Eval(webSwitchesTableProbe, &got); err != nil {
		t.Fatal(err)
	}
	for i, c := range cases {
		want, g := c.Switches, got[i]
		if want == nil {
			want = map[string]any{}
		}
		if !reflect.DeepEqual(g.Switches, want) {
			t.Errorf("%s: switches は %v のはず: %v", c.Name, want, g.Switches)
		}
		if !reflect.DeepEqual(legacyStrings(g.Legacy), legacyStrings(c.Legacy)) {
			t.Errorf("%s: legacy は %v のはず: %v", c.Name, legacyStrings(c.Legacy), legacyStrings(g.Legacy))
		}
		if strings.Join(g.Unknown, ",") != strings.Join(c.Unknown, ",") {
			t.Errorf("%s: unknown は %v のはず: %v", c.Name, c.Unknown, g.Unknown)
		}
	}
}

func legacyStrings(raw []json.RawMessage) []string {
	out := []string{}
	for _, r := range raw {
		var l struct{ From, To string }
		_ = json.Unmarshal(r, &l)
		out = append(out, l.From+"→"+l.To)
	}
	return out
}

func TestPageSwitchesSearchWithWordKeepsStartKeysAndDropsOldBackend(t *testing.T) {
	skipWithoutChrome(t)
	src, err := os.ReadFile(filepath.Join("..", "engine_web", "js", webSwitchesSource))
	if err != nil {
		t.Fatal(err)
	}
	page, err := cdp.OpenPage(cdp.PageOptions{InitScript: string(src)})
	if err != nil {
		t.Fatal(err)
	}
	defer page.Close()
	if err := page.Navigate("data:text/html,<p>t</p>"); err != nil {
		t.Fatal(err)
	}
	var got []string
	if err := page.Eval(`[fgeSearchWithWord("?talk=Lair&fge=fps&backend=webgpu", "webgl2", "backend"), fgeSearchWithWord("?fge=webgl2", "webgl2", "backend"), fgeSearchWithWord("?fge=webgpufail:canvas", "webgl2", "backend")]`, &got); err != nil {
		t.Fatal(err)
	}
	want := []string{"?talk=Lair&fge=fps,webgl2", "?fge=webgl2", "?fge=webgpufail:canvas,webgl2"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("開き直す URL は %v のはず: %v", want, got)
	}
}
