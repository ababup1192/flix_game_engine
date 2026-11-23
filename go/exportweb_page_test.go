package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/andybalholm/brotli"
)

const stampTestHTML = "<head>\n<title>t</title>\n</head>\n<body>\n" + `<script src="wasm-gc-runtime.js"></script>` + "\n" + `<script src="fge-web.js"></script>` + "\n</body>"

func stampForTest(t *testing.T, preload []webPreload) string {
	t.Helper()
	got, err := stampWebIndex(stampTestHTML, "abc123", preload, "", "")
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestStampWebIndexChecksVersionInHead(t *testing.T) {
	got := stampForTest(t, nil)
	head := got[:strings.Index(got, "</head>")]
	for _, want := range []string{`fetch("version.txt", { cache: "no-store" })`, `var baked = "abc123";`} {
		if !strings.Contains(head, want) {
			t.Errorf("head の起動役に %q が入るはず: %s", want, head)
		}
	}
}

func TestStampWebIndexLoadsScriptsInOrderAtScriptPlace(t *testing.T) {
	got := stampForTest(t, nil)
	if !strings.Contains(got, "<body>\n<script>\nfgeBootVersion.then(") || !strings.HasSuffix(got, "</script>\n</body>") {
		t.Errorf("body の起動役は元の script の場所に入るはず: %q", got)
	}
	for _, want := range []string{`["wasm-gc-runtime.js", "fge-web.js"]`, "s.async = false;"} {
		if !strings.Contains(got, want) {
			t.Errorf("body の起動役に %q が入るはず", want)
		}
	}
}

func TestStampWebIndexRemovesOriginalScriptTags(t *testing.T) {
	got := stampForTest(t, nil)
	if strings.Contains(got, `<script src="fge-web.js">`) || strings.Contains(got, `<script src="wasm-gc-runtime.js">`) {
		t.Errorf("元の script の行は消えるはず: %s", got)
	}
}

func TestStampWebIndexListsPreloadsWithTheirAs(t *testing.T) {
	got := stampForTest(t, []webPreload{{"bundle.json", "fetch"}, {"brotli-decode.js", "script"}})
	if !strings.Contains(got, `var preload = [["bundle.json", "fetch"], ["brotli-decode.js", "script"]];`) {
		t.Errorf("preload の表が head に入るはず: %s", got)
	}
}

func TestStampWebIndexPutsSwitchesReaderBeforeHeadScript(t *testing.T) {
	got, err := stampWebIndex(stampTestHTML, "abc123", nil, "function fgePageSwitches() {}\n", "")
	if err != nil {
		t.Fatal(err)
	}
	reader, head := strings.Index(got, "function fgePageSwitches() {}"), strings.Index(got, `var baked = "abc123";`)
	if reader < 0 || reader > head || reader > strings.Index(got, "</head>") {
		t.Errorf("頁の旗の読み手は head の起動役より前に入るはず: %s", got)
	}
}

func TestStampWebIndexWithoutSwitchesReaderAddsNoScript(t *testing.T) {
	got := stampForTest(t, nil)
	head := got[:strings.Index(got, "</head>")]
	if strings.Count(head, "<script>") != 1 {
		t.Errorf("読み手が無い（前の engine）時は head の script は起動役の 1 本のはず: %s", head)
	}
}

func TestHeadScriptReadsSwFromSwitchesAndOldKey(t *testing.T) {
	got := webHeadScript("abc", nil)
	for _, want := range []string{"fgePageSwitches().switches.sw === false", `/[?&]sw=0(&|$)/`} {
		if !strings.Contains(got, want) {
			t.Errorf("head の起動役は %q で Service Worker を外す口を見るはず", want)
		}
	}
}

func TestWriteWebServiceWorkerPutsSwitchesReaderFirst(t *testing.T) {
	jsDir, out := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(jsDir, webServiceWorkerSource), []byte(`var FGE_GAME_ID = "__FGE_GAME_ID__";`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(jsDir, webSwitchesSource), []byte("function fgeReadSwitches() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeWebServiceWorker(jsDir, out, "g", true); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(out, webServiceWorkerFile))
	if string(got) != "function fgeReadSwitches() {}\n\nvar FGE_GAME_ID = \"g\";" {
		t.Errorf("sw.js は頁の旗の読み手の後ろに Service Worker をつなぐはず: %s", got)
	}
}

func TestStampWebIndexFailsWhenScriptMissing(t *testing.T) {
	if _, err := stampWebIndex("<head></head>"+`<script src="fge-web.js"></script>`, "abc", nil, "", ""); err == nil {
		t.Error("wasm-gc-runtime.js の script が無ければ誤りのはず")
	}
}

func TestStampWebIndexFailsWithoutHeadClose(t *testing.T) {
	html := `<script src="wasm-gc-runtime.js"></script>` + `<script src="fge-web.js"></script>`
	if _, err := stampWebIndex(html, "abc", nil, "", ""); err == nil {
		t.Error("</head> が無ければ誤りのはず")
	}
}

func TestWebPreloadsWithBrotliFetchesBrotliAndDecoder(t *testing.T) {
	got := webPreloads(webBundle{WasmBrotli: webWasmBrotliFile})
	want := []webPreload{{"bundle.json", "fetch"}, {"classes.wasm.br", "fetch"}, {"brotli-decode.js", "script"},
		{"wasm-gc-runtime.js", "script"}, {"fge-web.js", "script"}}
	if len(got) != len(want) {
		t.Fatalf("preload は %v のはず: %v", want, got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("preload の %d 本目は %v のはず: %v", i, want[i], got[i])
		}
	}
}

func TestWebPreloadsWithoutBrotliFetchesPlainWasm(t *testing.T) {
	got := webPreloads(webBundle{})
	if got[1] != (webPreload{"classes.wasm", "fetch"}) {
		t.Errorf("brotli が無ければ 2 本目は classes.wasm のはず: %v", got)
	}
}

func TestResolveWebServiceWorkerDefaultsToOn(t *testing.T) {
	on, err := resolveWebServiceWorker([]byte(`{"compress": {}}`))
	if err != nil || !on {
		t.Errorf("書かなければ入れるはず: %v %v", on, err)
	}
}

func TestResolveWebServiceWorkerReadsFalse(t *testing.T) {
	on, err := resolveWebServiceWorker([]byte(`{"serviceWorker": false}`))
	if err != nil || on {
		t.Errorf("false なら入れないはず: %v %v", on, err)
	}
}

func TestResolveWebServiceWorkerRejectsNonBool(t *testing.T) {
	if _, err := resolveWebServiceWorker([]byte(`{"serviceWorker": "yes"}`)); err == nil {
		t.Error("真偽でなければ誤りのはず")
	}
}

func TestWriteWebServiceWorkerPutsGameID(t *testing.T) {
	jsDir, out := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(jsDir, webServiceWorkerSource), []byte(`var FGE_GAME_ID = "__FGE_GAME_ID__";`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeWebServiceWorker(jsDir, out, `my"game`, true); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(out, webServiceWorkerFile))
	if string(got) != `var FGE_GAME_ID = "my\"game";` {
		t.Errorf("束の id が JS の字として入るはず: %s", got)
	}
}

func TestWriteWebServiceWorkerFailsWithoutMark(t *testing.T) {
	jsDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(jsDir, webServiceWorkerSource), []byte(`var id = "x";`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeWebServiceWorker(jsDir, t.TempDir(), "g", true); err == nil {
		t.Error("束の id の印が無ければ誤りのはず")
	}
}

func TestEngineServiceWorkerSourceHasIDMark(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "engine_web", "js", webServiceWorkerSource))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), webServiceWorkerIDMark) {
		t.Errorf("engine_web/js/%s に %s が要る", webServiceWorkerSource, webServiceWorkerIDMark)
	}
}

func TestWriteWebServiceWorkerOffPutsRemovingWorker(t *testing.T) {
	jsDir, out := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(jsDir, webServiceWorkerOffSource), []byte("self.registration.unregister();"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := writeWebServiceWorker(jsDir, out, "g", false); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(out, webServiceWorkerFile))
	if string(got) != "self.registration.unregister();" {
		t.Errorf("false の時は自分を外す sw.js が出るはず: %s", got)
	}
}

func TestEngineServiceWorkerOffSourceUnregistersWithoutFetch(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "engine_web", "js", webServiceWorkerOffSource))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(src), "registration.unregister()") || strings.Contains(string(src), `addEventListener("fetch"`) {
		t.Errorf("自分を外す sw.js は unregister し、fetch を受けないはず")
	}
}

func writeSumsForTest(t *testing.T) (string, string) {
	t.Helper()
	out := t.TempDir()
	for name, body := range map[string]string{"index.html": "i", "version.txt": "v", "fge-web.js": "js", "assets/a.png": "png"} {
		p := filepath.Join(out, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	version, err := writeWebSums(out)
	if err != nil {
		t.Fatal(err)
	}
	return out, version
}

func TestWriteWebSumsListsEachFileHashExceptPageAndVersion(t *testing.T) {
	out, _ := writeSumsForTest(t)
	data, _ := os.ReadFile(filepath.Join(out, webSumsFile))
	var sums map[string]string
	if err := json.Unmarshal(data, &sums); err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256([]byte("png"))
	if len(sums) != 2 || sums["assets/a.png"] != hex.EncodeToString(h[:]) {
		t.Errorf("index.html と version.txt を除く 1 本ずつの sha256 のはず: %v", sums)
	}
}

func TestWriteWebSumsVersionIsHeadOfSumsHash(t *testing.T) {
	out, version := writeSumsForTest(t)
	data, _ := os.ReadFile(filepath.Join(out, webSumsFile))
	h := sha256.Sum256(data)
	if version != hex.EncodeToString(h[:])[:12] {
		t.Errorf("版は sums.json の sha256 の頭 12 字のはず: %s", version)
	}
}

// jsc は macOS にだけある。無い機械では飛ばす。
const jscPath = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"

func checkJsSyntax(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(jscPath); err != nil {
		t.Skip("jsc が無い（macOS の外）")
	}
	if out, err := exec.Command(jscPath, "-e", "checkSyntax("+strconvQuote(path)+")").CombinedOutput(); err != nil {
		t.Errorf("%s の構文が通らない: %s", path, out)
	}
}

func strconvQuote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func TestEngineWebScriptsParse(t *testing.T) {
	for _, name := range []string{webServiceWorkerSource, webServiceWorkerOffSource, webSwitchesSource, "fge-web.js"} {
		checkJsSyntax(t, filepath.Join("..", "engine_web", "js", name))
	}
}

func TestStampedScriptsParse(t *testing.T) {
	got := stampForTest(t, webPreloads(webBundle{WasmBrotli: webWasmBrotliFile}))
	dir := t.TempDir()
	for i, part := range strings.Split(got, "<script>")[1:] {
		body := part[:strings.Index(part, "</script>")]
		p := filepath.Join(dir, "s"+string(rune('0'+i))+".js")
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		checkJsSyntax(t, p)
	}
}

func TestBrotliBytesDecodeBackToInput(t *testing.T) {
	data := bytes.Repeat([]byte("(module (func $main))"), 5000)
	br, err := brotliBytes(data)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(brotli.NewReader(bytes.NewReader(br)))
	if err != nil || !bytes.Equal(got, data) {
		t.Errorf("詰めた物を戻すと元に戻るはず: err=%v len=%d", err, len(got))
	}
}

func TestBrotliBytesShrinksRepeatedData(t *testing.T) {
	data := bytes.Repeat([]byte("abcdefgh"), 10000)
	if br, err := brotliBytes(data); err != nil || len(br) >= len(data)/10 {
		t.Errorf("繰り返しの多い物は 1 割より小さくなるはず: err=%v %d", err, len(br))
	}
}
