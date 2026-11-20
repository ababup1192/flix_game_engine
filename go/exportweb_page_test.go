package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const stampTestHTML = "<head>\n<title>t</title>\n</head>\n<body>\n" + `<script src="wasm-gc-runtime.js"></script>` + "\n" + `<script src="fge-web.js"></script>` + "\n</body>"

func stampForTest(t *testing.T, preload []webPreload) string {
	t.Helper()
	got, err := stampWebIndex(stampTestHTML, "abc123", preload)
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

func TestStampWebIndexFailsWhenScriptMissing(t *testing.T) {
	if _, err := stampWebIndex("<head></head>"+`<script src="fge-web.js"></script>`, "abc", nil); err == nil {
		t.Error("wasm-gc-runtime.js の script が無ければ誤りのはず")
	}
}

func TestStampWebIndexFailsWithoutHeadClose(t *testing.T) {
	html := `<script src="wasm-gc-runtime.js"></script>` + `<script src="fge-web.js"></script>`
	if _, err := stampWebIndex(html, "abc", nil); err == nil {
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
	if err := writeWebServiceWorker(jsDir, out, `my"game`); err != nil {
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
	if err := writeWebServiceWorker(jsDir, t.TempDir(), "g"); err == nil {
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
