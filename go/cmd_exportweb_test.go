package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestEngineVersionFromTomlReadsDependencyLine(t *testing.T) {
	toml := "[dependencies]\n\"github:ababup1192/flix_game_engine\" = { version = \"0.84.1\", mount = \"fge\" }\n"
	if got := engineVersionFromToml(toml); got != "0.84.1" {
		t.Errorf("版は 0.84.1 のはず: %q", got)
	}
}

func TestEngineVersionFromTomlSkipsCommentedLine(t *testing.T) {
	toml := "# \"github:ababup1192/flix_game_engine\" = { version = \"0.1.0\" }\n"
	if got := engineVersionFromToml(toml); got != "" {
		t.Errorf("コメントの行は読まないはず: %q", got)
	}
}

func TestTeavmErrorsCountsOnlyLinesStartingWithError(t *testing.T) {
	log := "INFO ok\nERROR a\n  at x\n  at y\n  at z\nwarning: ERROR inside\nERROR b\n"
	if n, _ := teavmErrors(log, 5); n != 2 {
		t.Errorf("ERROR で始まる行は 2 件のはず: %d", n)
	}
}

func TestTeavmErrorsShowsTwoFollowingLines(t *testing.T) {
	_, shown := teavmErrors("ERROR a\n  at x\n  at y\n  at z\n", 5)
	if shown != "ERROR a\n  at x\n  at y" {
		t.Errorf("ERROR の行と次の 2 行を出すはず: %q", shown)
	}
}

func TestTeavmErrorsLimitsShownEntries(t *testing.T) {
	_, shown := teavmErrors("ERROR a\n1\n2\n3\nERROR c\n", 1)
	if strings.Contains(shown, "ERROR c") {
		t.Errorf("最初の 1 件より後は出さないはず: %q", shown)
	}
}

func TestStampWebIndexAddsVersionToBothScripts(t *testing.T) {
	html := `<script src="wasm-gc-runtime.js"></script>` + "\n" + `<script src="fge-web.js"></script>`
	got, err := stampWebIndex(html, "abc")
	want := `<script src="wasm-gc-runtime.js?v=abc"></script>` + "\n" + `<script src="fge-web.js?v=abc"></script>`
	if err != nil || got != want {
		t.Errorf("2 つの script に ?v= が付くはず: %q %v", got, err)
	}
}

func TestStampWebIndexFailsWhenScriptMissing(t *testing.T) {
	if _, err := stampWebIndex(`<script src="fge-web.js"></script>`, "abc"); err == nil {
		t.Error("wasm-gc-runtime.js の script が無ければ誤りのはず")
	}
}

func TestParseExportWebArgsReadsValueFlags(t *testing.T) {
	o, err := parseExportWebArgs([]string{"game", "--out", "o", "--id=x", "--check"})
	want := exportWebOptions{Game: "game", Out: "o", ID: "x", Check: true}
	if err != nil || o != want {
		t.Errorf("引数の読み: %+v %v", o, err)
	}
}

func TestParseExportWebArgsRejectsUnknownFlag(t *testing.T) {
	if _, err := parseExportWebArgs([]string{"game", "--nope"}); err == nil {
		t.Error("知らない引数は誤りのはず")
	}
}

func writeTestFile(t *testing.T, root, rel, body string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func bundleFixture(t *testing.T) string {
	t.Helper()
	game := t.TempDir()
	for _, rel := range []string{
		"project.json", "assets/a.json", "assets/maps/m.map.json", "assets/font.ttf",
		"assets/pic.png", "assets/tex.png", "assets/sfx/hit.wav", "assets/.DS_Store",
	} {
		writeTestFile(t, game, rel, "x")
	}
	return game
}

func bundleFixtureProject() exportProject {
	var pr exportProject
	pr.Title = "t"
	pr.Textures = append(pr.Textures, struct {
		Path string `json:"path"`
	}{"assets/tex.png"})
	pr.Sounds = []webSound{{Name: "hit", Path: "assets/sfx/hit.wav", Looping: true}}
	return pr
}

func TestBuildWebBundleFilesSkipMediaAndDotFiles(t *testing.T) {
	game := bundleFixture(t)
	b, err := buildWebBundle(game, "g", bundleFixtureProject())
	want := []string{"assets/a.json", "assets/maps/m.map.json", "project.json"}
	if err != nil || !reflect.DeepEqual(b.Files, want) {
		t.Errorf("files は絵・音・フォント・点で始まる物を除くはず: %v %v", b.Files, err)
	}
}

func TestBuildWebBundleImagesComeFromTextures(t *testing.T) {
	b, err := buildWebBundle(bundleFixture(t), "g", bundleFixtureProject())
	if err != nil || !reflect.DeepEqual(b.Images, []string{"assets/tex.png"}) {
		t.Errorf("images は textures[].path のはず: %v %v", b.Images, err)
	}
}

func TestBuildWebBundleRejectsMissingSound(t *testing.T) {
	pr := bundleFixtureProject()
	pr.Sounds[0].Path = "assets/sfx/none.wav"
	if _, err := buildWebBundle(bundleFixture(t), "g", pr); err == nil {
		t.Error("無い音を名指ししたら誤りのはず")
	}
}

func TestBuildWebBundleRejectsPathOutsideGame(t *testing.T) {
	pr := bundleFixtureProject()
	pr.Sounds[0].Path = "../x.wav"
	if _, err := buildWebBundle(bundleFixture(t), "g", pr); err == nil {
		t.Error("ゲームの外を指す道は誤りのはず")
	}
}

func TestMarshalWebBundleKeepsKeyOrderAndEmptyLists(t *testing.T) {
	data, _ := marshalWebBundle(webBundle{ID: "g", Title: "<t>", Files: []string{}, Images: []string{}, Sounds: []webSound{}})
	want := "{\n \"id\": \"g\",\n \"title\": \"<t>\",\n \"files\": [],\n \"images\": [],\n \"sounds\": []\n}\n"
	if string(data) != want {
		t.Errorf("bundle.json の形: %q", data)
	}
}

func TestCopyGameTreeSkipsExcludedTopLevel(t *testing.T) {
	game := t.TempDir()
	for _, rel := range []string{"src/Main.flix", "lib/x.fpkg", "build/a", "packages.lock", "assets/build/keep.json"} {
		writeTestFile(t, game, rel, "x")
	}
	dst := filepath.Join(t.TempDir(), "p")
	if err := copyGameTree(game, dst); err != nil {
		t.Fatal(err)
	}
	var got []string
	filepath.WalkDir(dst, func(p string, d os.DirEntry, _ error) error {
		if !d.IsDir() {
			rel, _ := filepath.Rel(dst, p)
			got = append(got, filepath.ToSlash(rel))
		}
		return nil
	})
	want := []string{"assets/build/keep.json", "src/Main.flix"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("根の直下の除く物だけを除くはず: %v", got)
	}
}

func TestFindTeavmJarMatchesBothNamings(t *testing.T) {
	jars := []string{"/a/teavm-core-0.14.1.jar", "/b/teavm-relocated-libs-asm.jar", "/b/teavm-relocated-libs-asm-tree.jar"}
	if findTeavmJar(jars, "teavm-core") != jars[0] || findTeavmJar(jars, "teavm-relocated-libs-asm") != jars[1] {
		t.Error("版のある名前と版の無い名前の両方を引けるはず（asm-tree と取り違えない）")
	}
}
