package tape

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const (
	planDir    = "../../../plans/tape"
	samplePath = planDir + "/tape.sample.json"
	mockPath   = planDir + "/mock.html"
	otherPath  = "testdata/other.tape.json"
)

var sampleStrip = Strip{File: StripFile, Count: 88, W: StripW, H: StripH}

func readFile(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func renderFile(t *testing.T, p string, strip Strip) string {
	t.Helper()
	tp, err := Parse(readFile(t, p))
	if err != nil {
		t.Fatal(err)
	}
	page, err := Render(tp, "e32b519", strip)
	if err != nil {
		t.Fatal(err)
	}
	return string(page)
}

// mockFixes は mock.html から雛形へ直した所の全部（plans/tape/plan.md の「TAPE から引くように直す所」）。
// ここに無い違いが出たら、雛形がモックから外れている。
var mockFixes = [][2]string{
	{"<title>テープ（モック）— 血鱗 序章</title>", "<title>テープ — 血鱗 序章</title>"},
	{"    --witch: #c8a6ff; --girl: #ffb46b; --narr: #e6e6e6;\n", ""},
	{"  .mock { font-size: 9px; font-weight: 700; color: #1a1300; background: var(--accent); border-radius: 3px; padding: 0 3px; margin-left: 4px; vertical-align: 2px; }\n", ""},
	{"background-image: url(strip.jpg); background-repeat: no-repeat; }", "background-image: var(--strip); background-repeat: no-repeat; }"},
	{".thumb { width: 34px; height: 60px; border-radius: 4px; flex: none; background-image: url(strip.jpg); background-size: 2992px 60px; position: relative; }",
		".thumb { width: var(--thumb-w); height: 60px; border-radius: 4px; flex: none; background-image: var(--strip); background-size: var(--thumb-bg); position: relative; }"},
	{".chap .thumb { width: 30px; height: 53px; background-size: 2640px 53px; }", ".chap .thumb { width: var(--chap-w); height: 53px; background-size: var(--chap-bg); }"},
	{"video.onseeked = () => onTime(video.currentTime);\n",
		"video.onseeked = () => onTime(video.currentTime);\n" +
			"video.addEventListener(\"loadedmetadata\", () => { document.documentElement.style.setProperty(\"--frame-ratio\", `${video.videoWidth} / ${video.videoHeight}`); redraw(); });\n"},
	{".frame { position: relative; height: 100%; aspect-ratio: 540 / 960; max-width: 100%; }",
		".frame { position: relative; height: 100%; aspect-ratio: var(--frame-ratio, auto); max-width: 100%; }"},
	{"const box = () => canvas.getBoundingClientRect();\nfunction redraw() {\n",
		"const box = () => canvas.getBoundingClientRect();\n" +
			"// 枠より動画が横長・縦長の時は、動画が映っている矩形（object-fit: contain の内側）に canvas を重ねる。枠と動画の比が同じなら枠いっぱいのまま\n" +
			"function fitCanvas() {\n" +
			"  const f = $(\"frame\"), fw = f.clientWidth, fh = f.clientHeight, vw = video.videoWidth, vh = video.videoHeight;\n" +
			"  if (!fw || !fh || !vw || !vh || Math.abs(fw / fh - vw / vh) < .01) { canvas.style.left = canvas.style.top = canvas.style.width = canvas.style.height = \"\"; return; }\n" +
			"  const k = Math.min(fw / vw, fh / vh), w = vw * k, h = vh * k;\n" +
			"  Object.assign(canvas.style, { left: (fw - w) / 2 + \"px\", top: (fh - h) / 2 + \"px\", width: w + \"px\", height: h + \"px\" });\n" +
			"}\n" +
			"function redraw() {\n  fitCanvas();\n"},
	{`<b>血鱗 序章</b><span class="mock">MOCK</span><br>`, `<b id="tapeTitle"></b><br>`},
	{`<b id="tcNow">0:00.0</b> / 0:43.6</div>`, `<b id="tcNow">0:00.0</b> / <span id="tcDur"></span></div>`},
	{`const WHO = { "魔女": "var(--witch)", "少女": "var(--girl)", "地の文": "var(--narr)" };`,
		"const WHO = Object.fromEntries(TAPE.speakers.map((s, i) => [s.name, `var(--speaker-${i})`]));"},
	{"const thumbPos = t => `${-Math.min(87, Math.floor(t * TAPE.stripPerSec)) * 34}px 0`;",
		"const THUMB_W = Math.round(60 * TAPE.strip.w / TAPE.strip.h), CHAP_W = Math.round(53 * TAPE.strip.w / TAPE.strip.h);\n" +
			"const thumbPos = t => `${-Math.min(TAPE.strip.count - 1, Math.floor(t * TAPE.stripPerSec)) * THUMB_W}px 0`;"},
	{"film.style.backgroundSize = `${TILE * 88}px 44px`;", "film.style.backgroundSize = `${TILE * TAPE.strip.count}px 44px`;"},
	{`style="background-position:${-Math.floor(s.t * TAPE.stripPerSec + 1) * 30}px 0"`, `style="background-position:${-Math.floor(s.t * TAPE.stripPerSec + 1) * CHAP_W}px 0"`},
	{"`<div class=\"ctxline\">通し · ${TAPE.scenes.length} シーン · 分岐 ${TAPE.branches.length}（この序章には分岐が無いので、分岐は見せ方の例です）</div>`",
		"`<div class=\"ctxline\">通し · ${TAPE.scenes.length} シーン${TAPE.branches.length ? ` · 分岐 ${TAPE.branches.length}${TAPE.branches.some(br => br.example) ? \"（例の分岐は見せ方を試すための仮の物です）\" : \"\"}` : \"\"}</div>`"},
	{"// 枠の寸法は動画から測った値: 横は画面の 2.8%〜97.2%、縦は 1 行目の中心から 47px 上〜最終行の中心から 32px 下、行の間 43.6px、中心は 466px（540×960 で）\n", ""},
	{"const MSG = { x0: .028, x1: .972, cy: 466 / 960, lh: 43.6 / 960, padTop: 47 / 960, padBot: 32 / 960, font: 25 / 960, cps: 28 };\n" +
		`const SPEAKER_INK = { "魔女": "#e2c2ff", "少女": "#ffd29a", "地の文": "#f4f4f4" };`,
		"const MSG = TAPE.msg;\nconst SPEAKER_INK = Object.fromEntries(TAPE.speakers.map(s => [s.name, s.ink]));"},
	{"if (!ln || edits[ln] === undefined || t < 8) {", `if (!ln || edits[ln] === undefined || !objectsAt(t).some(o => o.id === "message")) {`},
	{`  const names = { phase: "場面", witch: "魔女", item: "小物", ambience: "環境音", logSize: "ログ" };`, "  const names = TAPE.probeNames;"},
	{"function playHref(t) { const ln = lineAt(t) || 18; return `${TAPE.playUrl}?talk=${TAPE.node}&line=${ln}`; }",
		"function playHref(t) {\n" +
			"  const ln = lineAt(t), node = encodeURIComponent(TAPE.node);\n" +
			"  if (!ln) return `${TAPE.playUrl}?talk=${node}`;\n" +
			"  const l = TAPE.lines[ln];\n" +
			"  return `${TAPE.playUrl}?talk=${node}&line=${ln}&at=${fnv1a(l.text ?? l.cmd)}`;\n" +
			"}\n" +
			`function fnv1a(s) { let h = 0x811c9dc5; for (const b of new TextEncoder().encode(s)) h = Math.imul(h ^ b, 0x01000193) >>> 0; return h.toString(16).padStart(8, "0"); }`},
	{`toast("別のタブでゲームを開きます（モックでは最初から）");`, `toast("別のタブでゲームを開きます");`},
	{"function refresh() {", "function applyTape() {\n" +
		"  const root = document.documentElement.style;\n" +
		"  TAPE.speakers.forEach((s, i) => root.setProperty(`--speaker-${i}`, s.color));\n" +
		"  root.setProperty(\"--strip\", `url(\"${encodeURI(TAPE.strip.file)}\")`);\n" +
		"  root.setProperty(\"--thumb-w\", THUMB_W + \"px\"); root.setProperty(\"--thumb-bg\", `${THUMB_W * TAPE.strip.count}px 60px`);\n" +
		"  root.setProperty(\"--chap-w\", CHAP_W + \"px\"); root.setProperty(\"--chap-bg\", `${CHAP_W * TAPE.strip.count}px 53px`);\n" +
		"  $(\"tapeTitle\").textContent = TAPE.title; $(\"tcDur\").textContent = mmss(TAPE.duration);\n" +
		"  if (!TAPE.playUrl) $(\"playHereBtn\").style.display = \"none\";\n" +
		"}\n" +
		"function refresh() {"},
	{"setIcon(); buildTimeline(); refresh(); onTime(0);\n" +
		`fetch("kesshou.mp4").then(r => r.blob()).then(b => { video.src = URL.createObjectURL(b); }).catch(() => { video.src = "kesshou.mp4"; });`,
		"applyTape();\nsetIcon(); buildTimeline(); refresh(); onTime(0);\n" +
			"fetch(TAPE.video).then(r => r.blob()).then(b => { video.src = URL.createObjectURL(b); }).catch(() => { video.src = TAPE.video; });"},
}

// tapeLiteral は頁の「const TAPE = …;」の右辺を返す（モックは JS の書き方、雛形は JSON なので比べずに差し替える）。
func tapeLiteral(t *testing.T, page, start, end string) (int, int) {
	t.Helper()
	i := strings.Index(page, start)
	if i < 0 {
		t.Fatalf("%q が無い", start)
	}
	j := strings.Index(page[i:], end)
	if j < 0 {
		t.Fatalf("%q の後に %q が無い", start, end)
	}
	return i, i + j + len(end)
}

func TestSampleRenderEqualsMockExceptListedFixes(t *testing.T) {
	got := renderFile(t, samplePath, sampleStrip)
	want := string(readFile(t, mockPath))
	for _, f := range mockFixes {
		if n := strings.Count(want, f[0]); n != 1 {
			t.Fatalf("mock.html に直す前の文が %d 回: %q", n, f[0])
		}
		want = strings.Replace(want, f[0], f[1], 1)
	}
	mi, mj := tapeLiteral(t, want, "// ── 書き出しの道具が埋め込む想定のデータ", "\n};\n")
	gi, gj := tapeLiteral(t, got, "const TAPE = ", ";\n")
	want = want[:mi] + got[gi:gj] + want[mj:]
	if got != want {
		gl, wl := strings.Split(got, "\n"), strings.Split(want, "\n")
		for k := 0; k < len(gl) && k < len(wl); k++ {
			if gl[k] != wl[k] {
				t.Fatalf("%d 行目が違う\n雛形: %s\nモック: %s", k+1, gl[k], wl[k])
			}
		}
		t.Fatalf("行の数が違う 雛形 %d / モック %d", len(gl), len(wl))
	}
}

func TestOtherSampleLeavesNoMockNames(t *testing.T) {
	page := renderFile(t, otherPath, Strip{File: StripFile, Count: 13, W: StripW, H: StripH})
	for _, word := range []string{"kesshou", "血鱗", "MOCK", "2992", "魔女"} {
		if strings.Contains(page, word) {
			t.Errorf("書き出した頁に %q が残っている", word)
		}
	}
}

func TestRenderEscapesScriptCloseInText(t *testing.T) {
	var m map[string]any
	if err := json.Unmarshal(readFile(t, otherPath), &m); err != nil {
		t.Fatal(err)
	}
	m["title"] = "</script><b>x"
	data, _ := json.Marshal(m)
	tp, err := Parse(data)
	if err != nil {
		t.Fatal(err)
	}
	page, _ := Render(tp, "abc", sampleStrip)
	if strings.Contains(string(page), "</script><b>") {
		t.Fatal("題名の </script> がそのまま頁に出た")
	}
}

func TestRenderAddedFieldsOverrideGameValues(t *testing.T) {
	page := renderFile(t, samplePath, Strip{File: StripFile, Count: 5, W: StripW, H: StripH})
	if !strings.Contains(page, `"strip":{"file":"strip.jpg","count":5,"w":54,"h":96}`) {
		t.Fatal("strip が Render の値になっていない")
	}
}

func dropKey(t *testing.T, key string) []byte {
	t.Helper()
	var m map[string]json.RawMessage
	if err := json.Unmarshal(readFile(t, otherPath), &m); err != nil {
		t.Fatal(err)
	}
	delete(m, key)
	b, _ := json.Marshal(m)
	return b
}

func TestParseNamesEachMissingField(t *testing.T) {
	for _, r := range required {
		_, err := Parse(dropKey(t, r.key))
		if err == nil || !strings.Contains(err.Error(), `"`+r.key+`"`) {
			t.Errorf("%s を抜いた時の言葉に欄の名前が無い: %v", r.key, err)
		}
	}
}

func TestParseAcceptsMissingPlayUrl(t *testing.T) {
	if _, err := Parse(readFile(t, otherPath)); err != nil {
		t.Fatal(err)
	}
}

func withEdit(t *testing.T, edit func(m map[string]any)) error {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(readFile(t, otherPath), &m); err != nil {
		t.Fatal(err)
	}
	edit(m)
	b, _ := json.Marshal(m)
	_, err := Parse(b)
	return err
}

func TestParseAcceptsSoundWithoutLine(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { m["sounds"].([]any)[0].(map[string]any)["line"] = nil })
	if err != nil {
		t.Fatal(err)
	}
}

func TestParseRejectsUnknownField(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { m["speakerColors"] = []any{} })
	if err == nil || !strings.Contains(err.Error(), "speakerColors") {
		t.Fatalf("got %v", err)
	}
}

func TestParseRejectsTimelineLineAbsentFromLines(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { m["timeline"] = []any{[]any{0, nil}, []any{1, 99}} })
	if err == nil || !strings.Contains(err.Error(), "99") {
		t.Fatalf("got %v", err)
	}
}

func TestParseRejectsSpeakerWithoutColor(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { m["speakers"] = m["speakers"].([]any)[1:] })
	if err == nil || !strings.Contains(err.Error(), "灯台守") {
		t.Fatalf("got %v", err)
	}
}

func TestParseRejectsMsgWithoutKey(t *testing.T) {
	err := withEdit(t, func(m map[string]any) { delete(m["msg"].(map[string]any), "cps") })
	if err == nil || !strings.Contains(err.Error(), "cps") {
		t.Fatalf("got %v", err)
	}
}

func TestParseRejectsDuplicateSceneID(t *testing.T) {
	err := withEdit(t, func(m map[string]any) {
		s := m["scenes"].([]any)
		m["scenes"] = append(s, s[0])
	})
	if err == nil || !strings.Contains(err.Error(), "title") {
		t.Fatalf("got %v", err)
	}
}

func TestStripCountIncludesFrameZero(t *testing.T) {
	if got := StripCount(43.6); got != 88 {
		t.Fatalf("got %d", got)
	}
}

func TestStripCountOnExactHalfSecond(t *testing.T) {
	if got := StripCount(3.0); got != 6 {
		t.Fatalf("got %d", got)
	}
}

func TestParseArgsNeedsDir(t *testing.T) {
	if _, err := parseArgs(nil); err == nil {
		t.Fatal("want error")
	}
}

func TestParseArgsTakesDirEquals(t *testing.T) {
	opt, err := parseArgs([]string{"--dir=debug/tape/a"})
	if err != nil || opt.Dir != "debug/tape/a" {
		t.Fatalf("got %+v %v", opt, err)
	}
}

// makeVideo は ffmpeg の試験用の絵で secs 秒の 540×960 の mp4 を作る。ffmpeg が無ければ飛ばす。
func makeVideo(t *testing.T, path string, secs float64) {
	t.Helper()
	makeVideoSized(t, path, secs, "540x960")
}

// makeVideoSized は size（"幅x高さ"）の試験の動画を作る。
func makeVideoSized(t *testing.T, path string, secs float64, size string) {
	t.Helper()
	ff, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("ffmpeg が無い")
	}
	out, err := exec.Command(ff, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
		"-i", fmt.Sprintf("testsrc2=size=%s:rate=30:duration=%g", size, secs),
		"-pix_fmt", "yuv420p", path).CombinedOutput()
	if err != nil {
		t.Fatalf("試験の動画を作れない: %v\n%s", err, out)
	}
}

func TestBuildWritesStripAndIndex(t *testing.T) {
	dir := t.TempDir()
	makeVideo(t, filepath.Join(dir, VideoFile), 6.2)
	if err := os.WriteFile(filepath.Join(dir, TapeFile), readFile(t, otherPath), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Build(Options{Dir: dir, Commit: "abc1234"}); err != nil {
		t.Fatal(err)
	}
	page := string(readFile(t, filepath.Join(dir, IndexFile)))
	if !strings.Contains(page, `"strip":{"file":"strip.jpg","count":13,"w":54,"h":96}`) || !strings.Contains(page, `"commit":"abc1234"`) {
		t.Fatal("index.html に strip と commit が入っていない")
	}
}

func TestBuildStopsWithoutVideo(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, TapeFile), readFile(t, otherPath), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Build(Options{Dir: dir, Commit: "abc1234"})
	if err == nil || !strings.Contains(err.Error(), VideoFile) {
		t.Fatalf("got %v", err)
	}
}
