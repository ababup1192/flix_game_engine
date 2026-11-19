package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func mustWebDeferred(t *testing.T, raw string) []webGlob {
	t.Helper()
	g, err := resolveWebDeferred(json.RawMessage(raw))
	if err != nil {
		t.Fatal(err)
	}
	return g
}

func deferredFixtureBundle() webBundle {
	return webBundle{
		Files:  []string{"assets/novel.story.json", "assets/talk/dialogue.json", "assets/walk/hall.glb", "assets/walk/gate.glb", "project.json"},
		Images: []string{"assets/bg/gate.png", "assets/bg/sea.png", "assets/bg/title.png"},
		Sounds: []webSound{{Name: "bgm_sea", Path: "assets/bgm/sea.wav", Looping: true}, {Name: "se_hit", Path: "assets/sfx/hit.wav"}},
	}
}

func TestResolveWebDeferredWithoutKeyDefersNothing(t *testing.T) {
	if g := mustWebDeferred(t, `{"orientation": "portrait"}`); len(g) != 0 {
		t.Errorf("鍵が無ければ何も後回しにしないはず: %+v", g)
	}
}

func TestPlanWebDeferredKeepsGlobOrderThenPathOrder(t *testing.T) {
	g := mustWebDeferred(t, `{"deferred": ["assets/bgm/*.wav", "assets/walk/*.glb", "assets/bg/sea.png"]}`)
	plan, err := planWebDeferred(deferredFixtureBundle(), g, webEmbedPlan{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"assets/bgm/sea.wav", "assets/walk/gate.glb", "assets/walk/hall.glb", "assets/bg/sea.png"}
	if !reflect.DeepEqual(plan.Paths, want) {
		t.Errorf("取る順は %v のはず: %v", want, plan.Paths)
	}
}

func TestPlanWebDeferredTakesPathOnceWhenTwoGlobsMatch(t *testing.T) {
	g := mustWebDeferred(t, `{"deferred": ["assets/walk/gate.glb", "assets/walk/*.glb"]}`)
	plan, err := planWebDeferred(deferredFixtureBundle(), g, webEmbedPlan{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"assets/walk/gate.glb", "assets/walk/hall.glb"}
	if !reflect.DeepEqual(plan.Paths, want) {
		t.Errorf("2 つの glob に当たる道は 1 回だけのはず: %v", plan.Paths)
	}
}

func TestPlanWebDeferredRejectsGlobMatchingNothing(t *testing.T) {
	g := mustWebDeferred(t, `{"deferred": ["assets/bgm/*.ogg"]}`)
	if _, err := planWebDeferred(deferredFixtureBundle(), g, webEmbedPlan{}, nil, nil); err == nil || !strings.Contains(err.Error(), "*.ogg") {
		t.Errorf("当たらない glob は名前つきの誤りのはず: %v", err)
	}
}

func TestPlanWebDeferredRejectsProjectJson(t *testing.T) {
	g := mustWebDeferred(t, `{"deferred": ["*.json"]}`)
	if _, err := planWebDeferred(deferredFixtureBundle(), g, webEmbedPlan{}, nil, nil); err == nil || !strings.Contains(err.Error(), "project.json") {
		t.Errorf("project.json に当たる glob は誤りのはず: %v", err)
	}
}

func TestPlanWebDeferredRejectsEmbeddedFile(t *testing.T) {
	g := mustWebDeferred(t, `{"deferred": ["assets/talk/*.json"]}`)
	embed := webEmbedPlan{Embedded: []string{"assets/talk/dialogue.json"}}
	if _, err := planWebDeferred(deferredFixtureBundle(), g, embed, nil, nil); err == nil || !strings.Contains(err.Error(), "web.embed") {
		t.Errorf("web.embed の素材に当たる glob は誤りのはず: %v", err)
	}
}

func TestPlanWebDeferredRejectsOmittedFile(t *testing.T) {
	g := mustWebDeferred(t, `{"deferred": ["assets/novel.story.json"]}`)
	embed := webEmbedPlan{Omitted: []string{"assets/novel.story.json"}}
	if _, err := planWebDeferred(deferredFixtureBundle(), g, embed, nil, nil); err == nil || !strings.Contains(err.Error(), "web.omit") {
		t.Errorf("web.omit の素材に当たる glob は誤りのはず: %v", err)
	}
}

func TestPlanWebDeferredRejectsFontAtlas(t *testing.T) {
	g := mustWebDeferred(t, `{"deferred": ["**/*.fontatlas"]}`)
	if _, err := planWebDeferred(deferredFixtureBundle(), g, webEmbedPlan{}, []string{"default"}, nil); err == nil || !strings.Contains(err.Error(), "アトラス") {
		t.Errorf("フォントのアトラスに当たる glob は誤りのはず: %v", err)
	}
}

func TestPlanWebDeferredWarnsOnTitleImage(t *testing.T) {
	g := mustWebDeferred(t, `{"deferred": ["assets/bg/*.png"]}`)
	plan, err := planWebDeferred(deferredFixtureBundle(), g, webEmbedPlan{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Warnings) != 1 || !strings.Contains(plan.Warnings[0], "assets/bg/title.png") {
		t.Errorf("タイトルの絵に当たる時は 1 行知らせるはず: %v", plan.Warnings)
	}
}

func TestPlanWebDeferredWarnsOnTextureNamedTitle(t *testing.T) {
	g := mustWebDeferred(t, `{"deferred": ["assets/bg/gate.png"]}`)
	names := map[string][]string{"assets/bg/gate.png": {"title_back"}}
	plan, err := planWebDeferred(deferredFixtureBundle(), g, webEmbedPlan{}, nil, names)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Warnings) != 1 {
		t.Errorf("textures の名前に title を含む絵は知らせるはず: %v", plan.Warnings)
	}
}

func writeServed(t *testing.T, out, rel string, size int) {
	t.Helper()
	p := exportAssetPath(out, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestWebDeferredEntriesUseServedSizeAndNames(t *testing.T) {
	out := t.TempDir()
	b := deferredFixtureBundle()
	b.Transcoded = map[string]string{"assets/bgm/sea.wav": "assets/bgm/sea.wav.opus", "assets/bg/sea.png": "assets/bg/sea.png.webp"}
	writeServed(t, out, "assets/bgm/sea.wav.opus", 300)
	writeServed(t, out, "assets/bg/sea.png.webp", 200)
	got := webDeferredEntries(out, &b, []string{"assets/bgm/sea.wav", "assets/bg/sea.png"}, map[string][]string{"assets/bg/sea.png": {"bg_sea"}})
	want := []webDeferredEntry{{Path: "assets/bgm/sea.wav", Bytes: 300, Names: []string{"bgm_sea"}}, {Path: "assets/bg/sea.png", Bytes: 200, Names: []string{"bg_sea"}}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("配る大きさと名前は %+v のはず: %+v", want, got)
	}
}

func TestWebStartupSizeSplitsStartAndDeferred(t *testing.T) {
	out := t.TempDir()
	b := webBundle{Files: []string{"project.json", "assets/a.json"}, Images: []string{"assets/bg/sea.png"},
		Sounds: []webSound{{Name: "bgm", Path: "assets/bgm/sea.wav"}}}
	writeServed(t, out, "project.json", 10)
	writeServed(t, out, "assets/a.json", 20)
	writeServed(t, out, "assets/bg/sea.png", 40)
	writeServed(t, out, "assets/bgm/sea.wav", 80)
	b.Deferred = []webDeferredEntry{{Path: "assets/bgm/sea.wav", Bytes: 80}}
	got := webStartupSizeOf(out, &b)
	want := webStartupSize{StartCount: 3, StartBytes: 70, DeferredCount: 1, DeferredBytes: 80}
	if got != want {
		t.Errorf("起動と後回しの数と大きさは %+v のはず: %+v", want, got)
	}
}

func TestMarshalWebBundleOmitsEmptyDeferred(t *testing.T) {
	data, err := marshalWebBundle(webBundle{ID: "g", Files: []string{}, Images: []string{}, Sounds: []webSound{}})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "deferred") {
		t.Errorf("後回しが無ければ bundle.json に deferred の欄を書かないはず: %s", data)
	}
}

func TestTextureNamesByPathKeepsEveryNameOfOnePath(t *testing.T) {
	pr := exportProject{Textures: []webTexture{{Name: "bg_sea", Path: "assets/bg/sea.png"}, {Name: "bg_town", Path: "assets/bg/town.png"}, {Name: "bg_sea_night", Path: "./assets/bg/sea.png"}}}
	got := textureNamesByPath(pr)["assets/bg/sea.png"]
	want := []string{"bg_sea", "bg_sea_night"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("1 本の道の名前は %v のはず: %v", want, got)
	}
}

func TestWebDeferredEntriesListEverySoundNameOfOnePath(t *testing.T) {
	out := t.TempDir()
	b := webBundle{Sounds: []webSound{{Name: "bgm_sea", Path: "assets/bgm/sea.wav", Looping: true}, {Name: "se_wave", Path: "assets/bgm/sea.wav"}}}
	writeServed(t, out, "assets/bgm/sea.wav", 80)
	got := webDeferredEntries(out, &b, []string{"assets/bgm/sea.wav"}, map[string][]string{})
	want := []webDeferredEntry{{Path: "assets/bgm/sea.wav", Bytes: 80, Names: []string{"bgm_sea", "se_wave"}}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("同じ道の音は 1 本の後回しに全部の名前を持つはず %+v: %+v", want, got)
	}
}

func startupFixture(t *testing.T) (string, webBundle) {
	out := t.TempDir()
	b := webBundle{Images: []string{"assets/bg/gate.webp", "assets/bg/late.webp"}}
	writeServed(t, out, "assets/bg/gate.webp", 200000)
	writeServed(t, out, "assets/bg/late.webp", 400000)
	b.Deferred = []webDeferredEntry{{Path: "assets/bg/late.webp", Bytes: 400000}}
	return out, b
}

func TestWebStartupEstimateCountsOnlyStartAssets(t *testing.T) {
	out, b := startupFixture(t)
	if got := webStartupEstimateOf(out, &b).Boot.AssetsWire; got != 200000 {
		t.Errorf("起動の素材は 200000 のはず: %d", got)
	}
}

func TestWebStartupEstimateSecondsAddPreludeToBandwidthTime(t *testing.T) {
	out, b := startupFixture(t)
	if got := webStartupEstimateOf(out, &b).Seconds; got != webStartupPreludeSeconds+1.0 {
		t.Errorf("200 KB は 1.6 Mbps で 1 秒・前置きを足して %.1f 秒のはず: %.3f", webStartupPreludeSeconds+1.0, got)
	}
}

func TestWebStartupEstimateDeferredArrivesAfterStartup(t *testing.T) {
	out, b := startupFixture(t)
	s := webStartupEstimateOf(out, &b)
	if got := s.Deferred[0].Seconds; got != s.Seconds+2.0 {
		t.Errorf("後回しの 400 KB は起動の 2 秒後に届くはず: %.3f（起動 %.3f）", got, s.Seconds)
	}
}

func TestWebWireSizeGzipsText(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a.json")
	if err := os.WriteFile(p, []byte(strings.Repeat("a", 10000)), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := webWireSize(p); got >= 1000 {
		t.Errorf("同じ字の続く JSON は gzip で小さくなるはず: %d", got)
	}
}

func TestWebStartupBytesUseBrotliWasmAndDecoder(t *testing.T) {
	out, b := startupFixture(t)
	writeServed(t, out, "../classes.wasm", 9000)
	if err := os.WriteFile(filepath.Join(out, webWasmBrotliFile), make([]byte, 3000), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(out, webBrotliDecoderFile), make([]byte, 100), 0o644); err != nil {
		t.Fatal(err)
	}
	b.WasmBrotli = webWasmBrotliFile
	got := webStartupBytesOf(out, &b)
	if got.Wasm != 3000 || got.WasmWire <= 3000 || got.WasmWire > 3100 {
		t.Errorf("wasm は br の 3000 と、解き手の gzip を足した回線の量のはず: %+v", got)
	}
}
