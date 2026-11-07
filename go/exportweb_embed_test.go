package main

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func mustWebEmbed(t *testing.T, raw string) webEmbed {
	t.Helper()
	e, err := resolveWebEmbed(json.RawMessage(raw))
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func embedFixtureBundle() webBundle {
	return webBundle{
		Files:  []string{"assets/novel.story.json", "assets/talk/dialogue.json", "assets/talk/main.yarn", "assets/talk/vocab.json", "project.json"},
		Images: []string{"assets/bg/sea.png"},
		Sounds: []webSound{{Name: "se", Path: "assets/sfx/se.wav"}},
	}
}

func TestResolveWebEmbedWithoutKeysEmbedsNothing(t *testing.T) {
	e := mustWebEmbed(t, `{"orientation": "portrait"}`)
	if len(e.Embed) != 0 || len(e.Omit) != 0 {
		t.Errorf("鍵が無ければ何も埋め込まないはず: %+v", e)
	}
}

func TestResolveWebEmbedRejectsAbsoluteGlob(t *testing.T) {
	if _, err := resolveWebEmbed(json.RawMessage(`{"embed": ["/assets/talk/dialogue.json"]}`)); err == nil {
		t.Error("/ で始まる glob は誤りのはず")
	}
}

func TestPlanWebEmbedSplitsEmbeddedAndOmitted(t *testing.T) {
	e := mustWebEmbed(t, `{"embed": ["assets/talk/dialogue.json"], "omit": ["assets/talk/*.yarn"]}`)
	plan, err := planWebEmbed(embedFixtureBundle(), e)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(plan.Embedded, []string{"assets/talk/dialogue.json"}) || !reflect.DeepEqual(plan.Omitted, []string{"assets/talk/main.yarn"}) {
		t.Errorf("埋め込む物と配らない物の分け方が違う: %+v", plan)
	}
}

func TestWithoutHiddenDropsEmbeddedAndOmittedFiles(t *testing.T) {
	e := mustWebEmbed(t, `{"embed": ["assets/talk/dialogue.json"], "omit": ["assets/talk/*.yarn"]}`)
	plan, err := planWebEmbed(embedFixtureBundle(), e)
	if err != nil {
		t.Fatal(err)
	}
	got := plan.withoutHidden(embedFixtureBundle().Files)
	want := []string{"assets/novel.story.json", "assets/talk/vocab.json", "project.json"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("配る files は %v のはず: %v", want, got)
	}
}

func TestPlanWebEmbedRejectsGlobMatchingNothing(t *testing.T) {
	e := mustWebEmbed(t, `{"embed": ["assets/talk/dialog.json"]}`)
	if _, err := planWebEmbed(embedFixtureBundle(), e); err == nil || !strings.Contains(err.Error(), "dialog.json") {
		t.Errorf("当たらない glob は名前つきの誤りのはず: %v", err)
	}
}

func TestPlanWebEmbedRejectsOmitGlobMatchingNothing(t *testing.T) {
	e := mustWebEmbed(t, `{"embed": ["assets/talk/dialogue.json"], "omit": ["assets/story/*.yarn"]}`)
	if _, err := planWebEmbed(embedFixtureBundle(), e); err == nil || !strings.Contains(err.Error(), "web.omit") {
		t.Errorf("当たらない omit の glob は誤りのはず: %v", err)
	}
}

func TestPlanWebEmbedRejectsSameFileInEmbedAndOmit(t *testing.T) {
	e := mustWebEmbed(t, `{"embed": ["assets/talk/*.json"], "omit": ["assets/talk/dialogue.json"]}`)
	if _, err := planWebEmbed(embedFixtureBundle(), e); err == nil {
		t.Error("両方に当たるファイルは誤りのはず")
	}
}

func TestPlanWebEmbedRejectsProjectJSON(t *testing.T) {
	e := mustWebEmbed(t, `{"omit": ["*.json"]}`)
	if _, err := planWebEmbed(embedFixtureBundle(), e); err == nil || !strings.Contains(err.Error(), "project.json") {
		t.Errorf("project.json に当たる glob は誤りのはず: %v", err)
	}
}

func TestPlanWebEmbedRejectsTooManyFiles(t *testing.T) {
	b := webBundle{Files: []string{"project.json"}}
	for i := 0; i <= webEmbedLimit; i++ {
		b.Files = append(b.Files, "assets/talk/"+strconv.Itoa(i)+".json")
	}
	if _, err := planWebEmbed(b, mustWebEmbed(t, `{"embed": ["assets/talk/*.json"]}`)); err == nil {
		t.Error("上限を超える数は誤りのはず")
	}
}

func TestPlanWebEmbedRejectsSoundAndImage(t *testing.T) {
	for _, raw := range []string{`{"embed": ["assets/talk/dialogue.json", "assets/sfx/*.wav"]}`, `{"omit": ["assets/bg/**"]}`} {
		if _, err := planWebEmbed(embedFixtureBundle(), mustWebEmbed(t, raw)); err == nil {
			t.Errorf("絵や音に当たる glob は誤りのはず: %s", raw)
		}
	}
}

func TestEmbedLeakSamplesPrefersNonASCIIRuns(t *testing.T) {
	data := []byte(`{"kind": "line", "text": "おや、あんた海の者でないね。", "speaker": "witch"}`)
	got := embedLeakSamples(data)
	if len(got) != 1 || string(got[0]) != "おや、あんた海の者でないね。" {
		t.Errorf("台詞の字の続きを 1 つ取るはず: %q", got)
	}
}

func TestEmbedLeakSamplesSkipsShortRuns(t *testing.T) {
	got := embedLeakSamples([]byte(`{"names": {"witch": "魔女", "girl": "少女"}, "title": "a long enough ascii title line"}`))
	for _, s := range got {
		if string(s) == "魔女" {
			t.Errorf("短い字の続き（よくある語）は取らないはず: %q", got)
		}
	}
}

func TestEmbedLeakSamplesSkipsASCIILines(t *testing.T) {
	if got := embedLeakSamples([]byte(`{"kind": "choice", "options": ["a long enough ascii option line"]}`)); len(got) != 0 {
		t.Errorf("ASCII の行（ほかの Doc と同じ形）は取らないはず: %q", got)
	}
}

func TestEmbedLeakSamplesSkipsRepeatedMark(t *testing.T) {
	if got := embedLeakSamples([]byte(`{"text": "…………………………"}`)); len(got) != 0 {
		t.Errorf("同じ字の繰り返しは取らないはず: %q", got)
	}
}

func TestEmbedSeedOfDependsOnContent(t *testing.T) {
	game := t.TempDir()
	write := func(text string) {
		if err := os.WriteFile(filepath.Join(game, "d.json"), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("一")
	a1, _ := embedSeedOf(game, []string{"d.json"})
	a2, _ := embedSeedOf(game, []string{"d.json"})
	write("二")
	b, _ := embedSeedOf(game, []string{"d.json"})
	if a1 != a2 || a1 == b || a1 <= 0 {
		t.Errorf("鍵は同じ中身なら同じ・違えば違う正の数のはず: %d %d %d", a1, a2, b)
	}
}

func TestEmbedLeakSamplesThinsOutToLimit(t *testing.T) {
	var b strings.Builder
	for i := 0; i < 100; i++ {
		b.WriteString("台詞の行がここに並んでいる" + strings.Repeat("あ", i%3) + "\n")
	}
	if got := embedLeakSamples([]byte(b.String())); len(got) != 16 {
		t.Errorf("16 個に間引くはず: %d", len(got))
	}
}

func writeEmbedLeakFixture(t *testing.T) (out, game string) {
	t.Helper()
	game = t.TempDir()
	out = t.TempDir()
	if err := os.MkdirAll(filepath.Join(game, "assets", "talk"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(game, "assets", "talk", "dialogue.json"), []byte(`{"text": "そんなに空気の泡を吐いてりゃすぐ分かる"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(out, "classes.wasm"), []byte("\x00asm prejPFHuvnI1VW"), 0o644); err != nil {
		t.Fatal(err)
	}
	return out, game
}

func TestCheckEmbedLeaksPassesWhenOnlyCipherTextShips(t *testing.T) {
	out, game := writeEmbedLeakFixture(t)
	unchecked, err := checkEmbedLeaks(out, game, []string{"assets/talk/dialogue.json"})
	if err != nil || len(unchecked) != 0 {
		t.Errorf("平文が無ければ通るはず: %v %v", unchecked, err)
	}
}

func TestCheckEmbedLeaksReportsFileWithoutSamples(t *testing.T) {
	out, game := writeEmbedLeakFixture(t)
	if err := os.WriteFile(filepath.Join(game, "ascii.json"), []byte(`{"a": 1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	unchecked, err := checkEmbedLeaks(out, game, []string{"ascii.json"})
	if err != nil || !reflect.DeepEqual(unchecked, []string{"ascii.json"}) {
		t.Errorf("探せなかった素材の道を返すはず: %v %v", unchecked, err)
	}
}

func TestCheckEmbedLeaksNamesFileHoldingPlainText(t *testing.T) {
	out, game := writeEmbedLeakFixture(t)
	if err := os.MkdirAll(filepath.Join(out, "assets", "assets", "talk"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(out, "assets", "assets", "talk", "main.yarn"), []byte("witch: そんなに空気の泡を吐いてりゃすぐ分かる\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := checkEmbedLeaks(out, game, []string{"assets/talk/dialogue.json"})
	if err == nil || !strings.Contains(err.Error(), "assets/assets/talk/main.yarn") || !strings.Contains(err.Error(), "web.omit") {
		t.Errorf("平文の残るファイルの名前と直し方を言うはず: %v", err)
	}
}

// 組んだ fge-web.jar と fge-web-tools.jar（make web-jar）がある時だけ、本物の Embed を流す。
func embedToolJars(t *testing.T) (java, asm, tools, web string) {
	t.Helper()
	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	version := ""
	if data, err := os.ReadFile(filepath.Join(root, "Makefile")); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "VERSION := ") {
				version = strings.TrimSpace(strings.TrimPrefix(line, "VERSION := "))
			}
		}
	}
	web = filepath.Join(root, "build", "web-jar", "fge-web-"+version+".jar")
	tools = filepath.Join(root, "build", "web-jar", "fge-web-tools-"+version+".jar")
	asm = filepath.Join(root, "build", "web-jar", "deps", "teavm-relocated-libs-asm-"+teavmVersion+".jar")
	java = exportWebJava(root)
	if _, err := exec.LookPath(java); err != nil || !fileExists(web) || !fileExists(tools) || !fileExists(asm) {
		t.Skip("java か make web-jar の jar が無い")
	}
	return java, asm, tools, web
}

func readZipFile(t *testing.T, jar, name string) []byte {
	t.Helper()
	r, err := zip.OpenReader(jar)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	for _, f := range r.File {
		if f.Name == name {
			rc, err := f.Open()
			if err != nil {
				t.Fatal(err)
			}
			defer rc.Close()
			data, err := io.ReadAll(rc)
			if err != nil {
				t.Fatal(err)
			}
			return data
		}
	}
	return nil
}

func TestEmbedToolReplacesStubWithoutPlainText(t *testing.T) {
	java, asm, tools, web := embedToolJars(t)
	game := t.TempDir()
	plain := strings.Repeat("おや、あんた海の者でないね。そんなに空気の泡を吐いてりゃすぐ分かるさ\n", 40)
	if err := os.MkdirAll(filepath.Join(game, "assets", "talk"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(game, "assets", "talk", "dialogue.json"), []byte(plain), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(t.TempDir(), "embedded.jar")
	log := filepath.Join(t.TempDir(), "embed.log")
	if code := runEmbed(java, asm, tools, web, game, web, dst, log, []string{"assets/talk/dialogue.json"}, 12345); code != 0 {
		text, _ := os.ReadFile(log)
		t.Fatalf("Embed が失敗した（%d）: %s", code, text)
	}
	before := readZipFile(t, web, "fge/web/EmbeddedData.class")
	after := readZipFile(t, dst, "fge/web/EmbeddedData.class")
	if after == nil || bytes.Equal(before, after) {
		t.Fatal("EmbeddedData は中身入りに差し替わるはず")
	}
	if bytes.Contains(after, []byte("海の者")) {
		t.Error("差し替えた class に平文が残っている")
	}
	if !bytes.Contains(after, []byte("assets/talk/dialogue.json")) {
		t.Error("道は引けるよう平文で入るはず")
	}
	if readZipFile(t, dst, "fge/web/AssetTable.class") == nil {
		t.Error("ほかの class はそのまま残るはず")
	}
}

func TestEmbedToolFailsWithoutStubClass(t *testing.T) {
	java, asm, tools, web := embedToolJars(t)
	game := t.TempDir()
	if err := os.WriteFile(filepath.Join(game, "a.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(t.TempDir(), "embedded.jar")
	log := filepath.Join(t.TempDir(), "embed.log")
	if code := runEmbed(java, asm, tools, web, game, asm, dst, log, []string{"a.json"}, 1); code == 0 {
		t.Error("EmbeddedData の無い jar では止まるはず")
	}
}
