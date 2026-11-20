package main

import (
	"encoding/json"
	"math"
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
	return g.Globs
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
	if got := s.Deferred[0].Seconds; math.Abs(got-(s.Seconds+2.0+webDeferredRoundTripSeconds)) > 1e-9 {
		t.Errorf("後回しの 400 KB は起動の 2 秒と往復の分の後に届くはず: %.3f（起動 %.3f）", got, s.Seconds)
	}
}

func TestSetWebArrivalSecondsCountsFromDeferredStart(t *testing.T) {
	out, b := startupFixture(t)
	setWebArrivalSeconds(out, &b)
	if got := b.Deferred[0].ArrivalSeconds; got != 2.075 {
		t.Errorf("arrivalSeconds は取り始めから 2 秒と往復の分のはず: %v", got)
	}
}

func tapWaitFixture(t *testing.T, entries ...webDeferredEntry) (string, webBundle) {
	t.Helper()
	out := t.TempDir()
	b := webBundle{Images: []string{"assets/a.webp", "assets/b.webp"}, Sounds: []webSound{{Name: "se", Path: "assets/se.ogg"}}}
	for _, rel := range []string{"assets/a.webp", "assets/b.webp", "assets/se.ogg"} {
		writeServed(t, out, rel, 200000)
	}
	b.Deferred = entries
	return out, b
}

func TestTapWaitWithGroupUsesLastOfGroup(t *testing.T) {
	out, b := tapWaitFixture(t, webDeferredEntry{Path: "assets/a.webp", Group: "start"}, webDeferredEntry{Path: "assets/b.webp", Group: "start"},
		webDeferredEntry{Path: "assets/se.ogg"})
	if got := webTapWaitOf(out, &b, []string{"start"}).Seconds; math.Abs(got-2*(1+webDeferredRoundTripSeconds)) > 1e-9 {
		t.Errorf("group の 2 本目が届く秒のはず: %v", got)
	}
}

func TestTapWaitWithoutGroupStartsAtFirstWaitingImage(t *testing.T) {
	out, b := tapWaitFixture(t, webDeferredEntry{Path: "assets/se.ogg"}, webDeferredEntry{Path: "assets/a.webp"})
	if got := webTapWaitOf(out, &b, nil).FirstPath; got != "assets/a.webp" {
		t.Errorf("鳴らさず進む音を飛ばし、最初の絵が待つ物のはず: %q", got)
	}
}

func TestTapWaitSkipsPlaceholderImages(t *testing.T) {
	out, b := tapWaitFixture(t, webDeferredEntry{Path: "assets/a.webp", OnMissing: "placeholder"})
	if got := webTapWaitOf(out, &b, nil).Count; got != 0 {
		t.Errorf("placeholder の絵は待たないはず: %d 本", got)
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

func TestResolveWebDeferredFontsReturnsNamedFonts(t *testing.T) {
	got, err := resolveWebDeferredFonts(json.RawMessage(`{"deferredFonts": ["gothic"]}`), []string{"default", "gothic"})
	if err != nil || !reflect.DeepEqual(got, []string{"gothic"}) {
		t.Fatalf("got %v, %v", got, err)
	}
}

func TestResolveWebDeferredFontsRejectsUnknownFont(t *testing.T) {
	if _, err := resolveWebDeferredFonts(json.RawMessage(`{"deferredFonts": ["mincho"]}`), []string{"default"}); err == nil {
		t.Fatal("fonts に無い名前を通した")
	}
}

func TestResolveWebDeferredFontsRejectsDeferringEveryFont(t *testing.T) {
	if _, err := resolveWebDeferredFonts(json.RawMessage(`{"deferredFonts": ["default", "gothic"]}`), []string{"default", "gothic"}); err == nil {
		t.Fatal("全部のフォントの後回しを通した")
	}
}

func TestWithDeferredFontsPutsAtlasAtTheHead(t *testing.T) {
	plan, _, _ := withDeferredFonts(webDeferredPlan{Paths: []string{"assets/bg/late.png"}}, []string{"gothic"}, nil, nil, map[string][]string{})
	if !reflect.DeepEqual(plan.Paths, []string{"font-atlas/gothic.fontatlas", "assets/bg/late.png"}) {
		t.Fatalf("got %v", plan.Paths)
	}
}

func TestWithDeferredFontsNamesAtlasByFont(t *testing.T) {
	_, names, _ := withDeferredFonts(webDeferredPlan{}, []string{"gothic"}, nil, nil, map[string][]string{"assets/bg/a.png": {"bg_a"}})
	if !reflect.DeepEqual(names["font-atlas/gothic.fontatlas"], []string{"gothic"}) {
		t.Fatalf("got %v", names)
	}
}

func TestCheckDeferredFontNamesRejectsTextureName(t *testing.T) {
	if err := checkDeferredFontNames([]string{"gothic"}, map[string][]string{"assets/bg/g.png": {"gothic"}}, nil); err == nil {
		t.Fatal("テクスチャと同じ名前を通した")
	}
}

func TestCheckDeferredFontNamesRejectsSoundName(t *testing.T) {
	if err := checkDeferredFontNames([]string{"gothic"}, nil, []webSound{{Name: "gothic", Path: "assets/sfx/g.wav"}}); err == nil {
		t.Fatal("音と同じ名前を通した")
	}
}

func TestTapWaitEstimateWarnsOverTheGamesLogoLimit(t *testing.T) {
	var b strings.Builder
	writeTapWaitEstimate(&b, webTapWait{Group: []string{"start"}, Seconds: 2.5, Until: 2.5, Count: 3}, 2.0)
	if !strings.Contains(b.String(), "知らせ") {
		t.Errorf("ゲームの maxSeconds（2 秒）を超えたら知らせるはず:\n%s", b.String())
	}
}

func TestTapWaitEstimateSaysZeroWithoutWaitingAssets(t *testing.T) {
	var b strings.Builder
	writeTapWaitEstimate(&b, webTapWait{}, webAfterTapMaxSeconds)
	if !strings.Contains(b.String(), ": 0 秒") {
		t.Errorf("待つ物が無ければ 0 秒のはず:\n%s", b.String())
	}
}

func TestTapWaitCountsGroupedFontsAsWaiting(t *testing.T) {
	if !webWaitsWhenMissing(webDeferredEntry{Path: "assets/f.fontatlas", Group: "start"}, "font") {
		t.Error("group を付けたフォントは待つはず（fge-web.js の fgeDeferredPolicy と同じ）")
	}
}

func TestResolveWebDeferredKeepsFontLinePosition(t *testing.T) {
	order, err := resolveWebDeferred(json.RawMessage(`{"deferred": ["assets/bg/*.png", "assets/bgm/*.wav", "font:round"]}`))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(order.Fonts, []webDeferredFontSlot{{Font: "round", Before: 2}}) {
		t.Errorf("font:round は glob 2 本の後のはず: %+v", order.Fonts)
	}
}

func TestResolveWebDeferredRejectsFontLineTwice(t *testing.T) {
	if _, err := resolveWebDeferred(json.RawMessage(`{"deferred": ["font:round", "assets/bg/*.png", "font:round"]}`)); err == nil {
		t.Fatal("同じ font: の 2 行を通した")
	}
}

func TestResolveWebDeferredRejectsFontLineWithoutName(t *testing.T) {
	if _, err := resolveWebDeferred(json.RawMessage(`{"deferred": ["font:"]}`)); err == nil {
		t.Fatal("名前の無い font: を通した")
	}
}

func fontOrderPlan(t *testing.T, raw string) (webDeferredPlan, webDeferredOrder) {
	t.Helper()
	order, err := resolveWebDeferred(json.RawMessage(raw))
	if err != nil {
		t.Fatal(err)
	}
	plan, err := planWebDeferred(deferredFixtureBundle(), order.Globs, webEmbedPlan{}, []string{"default", "round"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	return plan, order
}

func TestWithDeferredFontsPutsAtlasAtItsFontLine(t *testing.T) {
	plan, order := fontOrderPlan(t, `{"deferred": ["assets/bg/sea.png", "font:round", "assets/bgm/*.wav"]}`)
	plan, _, err := withDeferredFonts(plan, []string{"round"}, order.Fonts, nil, map[string][]string{})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"assets/bg/sea.png", "font-atlas/round.fontatlas", "assets/bgm/sea.wav"}
	if !reflect.DeepEqual(plan.Paths, want) {
		t.Errorf("取る順は %v のはず: %v", want, plan.Paths)
	}
}

func TestWithDeferredFontsPutsAtlasLastWhenFontLineIsLast(t *testing.T) {
	plan, order := fontOrderPlan(t, `{"deferred": ["assets/bg/sea.png", "assets/bgm/*.wav", "font:round"]}`)
	plan, _, _ = withDeferredFonts(plan, []string{"round"}, order.Fonts, nil, map[string][]string{})
	if got := plan.Paths[len(plan.Paths)-1]; got != "font-atlas/round.fontatlas" {
		t.Errorf("最後の行の font: は列の最後のはず: %v", plan.Paths)
	}
}

func TestWithDeferredFontsKeepsUnwrittenFontAtTheHead(t *testing.T) {
	plan, order := fontOrderPlan(t, `{"deferred": ["assets/bg/sea.png", "font:round"]}`)
	plan, _, _ = withDeferredFonts(plan, []string{"default", "round"}, order.Fonts, nil, map[string][]string{})
	want := []string{"font-atlas/default.fontatlas", "assets/bg/sea.png", "font-atlas/round.fontatlas"}
	if !reflect.DeepEqual(plan.Paths, want) {
		t.Errorf("font: の行の無いフォントは頭のはず: %v", plan.Paths)
	}
}

func TestWithDeferredFontsRejectsFontLineNotInDeferredFonts(t *testing.T) {
	plan, order := fontOrderPlan(t, `{"deferred": ["assets/bg/sea.png", "font:round"]}`)
	if _, _, err := withDeferredFonts(plan, nil, order.Fonts, nil, map[string][]string{}); err == nil || !strings.Contains(err.Error(), "deferredFonts") {
		t.Fatalf("deferredFonts に無いフォントの font: を通した: %v", err)
	}
}

func TestWithDeferredFontsPutsGroupedFontAtItsGroup(t *testing.T) {
	b := deferredFixtureBundle()
	plan, order := fontOrderPlan(t, `{"deferred": ["assets/bgm/*.wav", "assets/bg/sea.png"]}`)
	pol := mustDeferredPolicy(t, `{"deferredPolicy": [{"match": "assets/bg/sea.png", "group": "start"}, {"match": "font:round", "group": "start"}]}`)
	at := webFontGroupStarts(plan.Paths, []string{"round"}, pol, &b, nil)
	plan, _, _ = withDeferredFonts(plan, []string{"round"}, order.Fonts, at, map[string][]string{})
	want := []string{"assets/bgm/sea.wav", "font-atlas/round.fontatlas", "assets/bg/sea.png"}
	if !reflect.DeepEqual(plan.Paths, want) {
		t.Errorf("group を付けたフォントはその group の最初の素材の前のはず: %v", plan.Paths)
	}
}

func TestWithDeferredFontsKeepsGroupedFontAtHeadWithoutGroupAssets(t *testing.T) {
	b := deferredFixtureBundle()
	plan, order := fontOrderPlan(t, `{"deferred": ["assets/bgm/*.wav"]}`)
	pol := mustDeferredPolicy(t, `{"deferredPolicy": [{"match": "font:round", "group": "start"}]}`)
	at := webFontGroupStarts(plan.Paths, []string{"round"}, pol, &b, nil)
	plan, _, _ = withDeferredFonts(plan, []string{"round"}, order.Fonts, at, map[string][]string{})
	if plan.Paths[0] != "font-atlas/round.fontatlas" {
		t.Errorf("group の素材が列に無ければ頭のはず: %v", plan.Paths)
	}
}

func TestWithDeferredFontsPrefersFontLineOverGroup(t *testing.T) {
	b := deferredFixtureBundle()
	plan, order := fontOrderPlan(t, `{"deferred": ["assets/bg/sea.png", "assets/bgm/*.wav", "font:round"]}`)
	pol := mustDeferredPolicy(t, `{"deferredPolicy": [{"match": "assets/bg/sea.png", "group": "start"}, {"match": "font:round", "group": "start"}]}`)
	at := webFontGroupStarts(plan.Paths, []string{"round"}, pol, &b, nil)
	plan, _, _ = withDeferredFonts(plan, []string{"round"}, order.Fonts, at, map[string][]string{})
	if got := plan.Paths[len(plan.Paths)-1]; got != "font-atlas/round.fontatlas" {
		t.Errorf("font: の行が group の位置より勝つはず: %v", plan.Paths)
	}
}

func TestWithDeferredFontsTakesFontLineWithoutGlobs(t *testing.T) {
	plan, order := fontOrderPlan(t, `{"deferred": ["font:round"]}`)
	plan, _, _ = withDeferredFonts(plan, []string{"round"}, order.Fonts, nil, map[string][]string{})
	if !reflect.DeepEqual(plan.Paths, []string{"font-atlas/round.fontatlas"}) {
		t.Errorf("glob が無くても font: の行のフォントを取るはず: %v", plan.Paths)
	}
}

func TestWithDeferredFontsPlacesFontLineAfterGlobWithNothingNew(t *testing.T) {
	plan, order := fontOrderPlan(t, `{"deferred": ["assets/bg/sea.png", "assets/bgm/*.wav", "assets/bg/sea.png", "font:round", "assets/walk/*.glb"]}`)
	plan, _, _ = withDeferredFonts(plan, []string{"round"}, order.Fonts, nil, map[string][]string{})
	want := []string{"assets/bg/sea.png", "assets/bgm/sea.wav", "font-atlas/round.fontatlas", "assets/walk/gate.glb", "assets/walk/hall.glb"}
	if !reflect.DeepEqual(plan.Paths, want) {
		t.Errorf("取り済みの道しか当てない glob の後の font: は、次の glob の前のはず: %v", plan.Paths)
	}
}

func TestWithDeferredFontsPutsUnwrittenFontBeforeFontLineAtSamePlace(t *testing.T) {
	plan, order := fontOrderPlan(t, `{"deferred": ["font:round", "assets/bg/sea.png"]}`)
	plan, _, _ = withDeferredFonts(plan, []string{"round", "default"}, order.Fonts, nil, map[string][]string{})
	want := []string{"font-atlas/default.fontatlas", "font-atlas/round.fontatlas", "assets/bg/sea.png"}
	if !reflect.DeepEqual(plan.Paths, want) {
		t.Errorf("同じ位置では font: の行の無いフォントが先のはず: %v", plan.Paths)
	}
}

func writeServedIncompressible(t *testing.T, out, rel string, size int) {
	t.Helper()
	data := make([]byte, size)
	x := uint32(2463534242)
	for i := range data {
		x ^= x << 13
		x ^= x >> 17
		x ^= x << 5
		data[i] = byte(x)
	}
	p := exportAssetPath(out, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

// 600 KB のフォントと、group "start" の絵（200 KB）を raw の web.deferred の並びで取る束。
func fontAfterGroupFixture(t *testing.T, raw string) (string, webBundle) {
	t.Helper()
	out := t.TempDir()
	b := webBundle{Images: []string{"assets/a.webp"}}
	writeServed(t, out, "assets/a.webp", 200000)
	writeServedIncompressible(t, out, "font-atlas/round.fontatlas", 600000)
	order, err := resolveWebDeferred(json.RawMessage(raw))
	if err != nil {
		t.Fatal(err)
	}
	plan, err := planWebDeferred(b, order.Globs, webEmbedPlan{}, []string{"default", "round"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if plan, _, err = withDeferredFonts(plan, []string{"round"}, order.Fonts, nil, map[string][]string{}); err != nil {
		t.Fatal(err)
	}
	pol := mustDeferredPolicy(t, `{"deferredPolicy": [{"match": "assets/*.webp", "group": "start"}]}`)
	b.Deferred, _, err = applyWebDeferredPolicy(webDeferredEntries(out, &b, plan.Paths, nil), pol, &b)
	if err != nil {
		t.Fatal(err)
	}
	return out, b
}

func TestTapWaitShrinksWhenFontLineIsAfterTheGroup(t *testing.T) {
	out, b := fontAfterGroupFixture(t, `{"deferred": ["assets/*.webp", "font:round"]}`)
	if got := webTapWaitOf(out, &b, []string{"start"}).Seconds; math.Abs(got-(1+webDeferredRoundTripSeconds)) > 1e-9 {
		t.Errorf("フォントを group の後ろへ回せば group の絵 1 本の秒のはず: %v", got)
	}
}

func TestTapWaitCountsHeadFontBeforeTheGroup(t *testing.T) {
	out, b := fontAfterGroupFixture(t, `{"deferred": ["assets/*.webp"]}`)
	if got := webTapWaitOf(out, &b, []string{"start"}).Seconds; got < 3+1 {
		t.Errorf("頭のフォント（600 KB = 3 秒）の後に group の絵が届くはず: %v", got)
	}
}

func TestArrivalSecondsFollowFontLineOrder(t *testing.T) {
	out, b := fontAfterGroupFixture(t, `{"deferred": ["assets/*.webp", "font:round"]}`)
	setWebArrivalSeconds(out, &b)
	if b.Deferred[1].Path != "font-atlas/round.fontatlas" || b.Deferred[1].ArrivalSeconds <= b.Deferred[0].ArrivalSeconds {
		t.Errorf("arrivalSeconds は font: の行の位置で積むはず: %+v", b.Deferred)
	}
}
