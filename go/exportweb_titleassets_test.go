package main

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// titleFixture は書き出し先に配る物を置き、束と project.json の形を返す。大きさは道ごとに sizes の通り。
func titleFixture(t *testing.T, sizes map[string]int) (string, webBundle, exportProject) {
	t.Helper()
	out := t.TempDir()
	for rel, n := range sizes {
		p := exportAssetPath(out, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		// WhyNot: 0 で埋めない — wav などは gzip の量で見積もるので、0 の並びは数十バイトに縮んで大きさの順が出ない。
		data := make([]byte, n)
		rand.New(rand.NewSource(int64(n))).Read(data)
		if err := os.WriteFile(p, data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	b := webBundle{
		Files:  []string{"project.json", "assets/novel.story.json", "assets/walk/hall.glb", "font-atlas/gothic.fontatlas", "font-atlas/mincho.fontatlas"},
		Images: []string{"assets/bg/title.png", "assets/bg/sea.png", "assets/bg/gate.png", "assets/cast/a_smile.png", "assets/cast/a_sad.png", "assets/cast/b_plain.png"},
		Sounds: []webSound{{Name: "bgm_title", Path: "assets/bgm/title.wav"}, {Name: "bgm_sea", Path: "assets/bgm/sea.wav"}, {Name: "se_hit", Path: "assets/sfx/hit.wav"}},
	}
	var pr exportProject
	for _, rel := range b.Images {
		name := strings.TrimSuffix(filepath.Base(rel), ".png")
		pr.Textures = append(pr.Textures, webTexture{Name: name, Path: rel})
	}
	pr.Sounds = b.Sounds
	for _, n := range []string{"gothic", "mincho"} {
		pr.Fonts = append(pr.Fonts, struct {
			Name string `json:"name"`
		}{n})
	}
	return out, b, pr
}

func titleUsed() webUsedAssets {
	return webUsedAssets{
		Frame:   130,
		Texture: map[string]int{"title": 1, "font_gothic": 2, "sea": 125},
		Sound:   map[string]int{"bgm_title": 1},
		File:    map[string]int{"project.json": 0, "font-atlas/gothic.fontatlas": 0, "font-atlas/mincho.fontatlas": 0},
	}
}

func candidatePaths(s webDeferredSuggestion) []string {
	var out []string
	for _, c := range s.Candidates {
		out = append(out, c.Path)
	}
	return out
}

func TestSuggestWebDeferredLeavesOutWhatTitleUsed(t *testing.T) {
	out, b, pr := titleFixture(t, nil)
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	for _, rel := range candidatePaths(s) {
		if rel == "assets/bg/title.png" || rel == "assets/bgm/title.wav" || rel == "font-atlas/gothic.fontatlas" {
			t.Errorf("タイトルで使った %s は候補に出ないはず: %v", rel, candidatePaths(s))
		}
	}
}

func TestSuggestWebDeferredCountsUseAfterTitleFramesAsUnused(t *testing.T) {
	out, b, pr := titleFixture(t, nil)
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	found := false
	for _, rel := range candidatePaths(s) {
		found = found || rel == "assets/bg/sea.png"
	}
	if !found {
		t.Errorf("%d コマより後に初めて使った絵は候補に出るはず: %v", webTitleFrames, candidatePaths(s))
	}
}

func TestSuggestWebDeferredSkipsDocsAndProjectJSON(t *testing.T) {
	out, b, pr := titleFixture(t, nil)
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	for _, rel := range candidatePaths(s) {
		if strings.HasSuffix(rel, ".json") {
			t.Errorf("Doc と project.json は候補に出ないはず: %v", candidatePaths(s))
		}
	}
}

func TestSuggestWebDeferredListsUnreadBinaryFileApart(t *testing.T) {
	out, b, pr := titleFixture(t, nil)
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	if len(s.Files) != 1 || s.Files[0].Path != "assets/walk/hall.glb" {
		t.Errorf("読まなかった glb は読まなかったファイルの一覧に出るはず: %+v", s.Files)
	}
}

func TestSuggestWebDeferredKeepsUnreadFileOutOfGlobs(t *testing.T) {
	out, b, pr := titleFixture(t, nil)
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	for _, g := range s.Globs {
		if strings.Contains(g, "walk") {
			t.Errorf("読まなかったファイルは貼る形に入れないはず（読み込みは届くのを待たない）: %v", s.Globs)
		}
	}
}

func TestSuggestWebDeferredOffersUnusedFontByGlyphTexture(t *testing.T) {
	out, b, pr := titleFixture(t, nil)
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	if !reflect.DeepEqual(s.Fonts, []string{"mincho"}) {
		t.Errorf("字を描かなかったフォントだけが deferredFonts の候補のはず（アトラスを読んだかは見ない）: %v", s.Fonts)
	}
}

func TestSuggestWebDeferredKeepsOneFontWhenAllWouldBeDeferred(t *testing.T) {
	out, b, pr := titleFixture(t, nil)
	used := titleUsed()
	delete(used.Texture, "font_gothic")
	s := suggestWebDeferred(out, &b, pr, nil, nil, used, webTitleFrames)
	if !reflect.DeepEqual(s.Fonts, []string{"mincho"}) || s.KeptFont != "gothic" {
		t.Errorf("全部のフォントが候補なら fonts の先頭を外すはず: fonts=%v kept=%q", s.Fonts, s.KeptFont)
	}
}

func TestSuggestWebDeferredSkipsAlreadyDeferredAndHidden(t *testing.T) {
	out, b, pr := titleFixture(t, nil)
	b.Deferred = []webDeferredEntry{{Path: "assets/bgm/sea.wav"}}
	s := suggestWebDeferred(out, &b, pr, nil, map[string]bool{"assets/walk/hall.glb": true}, titleUsed(), webTitleFrames)
	for _, rel := range candidatePaths(s) {
		if rel == "assets/bgm/sea.wav" || rel == "assets/walk/hall.glb" {
			t.Errorf("後回しの物と web.embed・web.omit の物は候補に出ないはず: %v", candidatePaths(s))
		}
	}
}

func TestSuggestWebDeferredWarnsWhenDeferredIsUsedBeforeArrival(t *testing.T) {
	out, b, pr := titleFixture(t, nil)
	b.Deferred = []webDeferredEntry{{Path: "assets/bgm/title.wav", Names: []string{"bgm_title"}}}
	used := titleUsed()
	used.Early = map[string]int{"bgm_title": 1}
	s := suggestWebDeferred(out, &b, pr, nil, nil, used, webTitleFrames)
	if !reflect.DeepEqual(s.UsedLate, []string{"assets/bgm/title.wav"}) {
		t.Errorf("届く前に鳴らそうとした後回しの音を知らせるはず: %v", s.UsedLate)
	}
}

func TestSuggestWebDeferredStaysQuietWhenDeferredIsUsedAfterArrival(t *testing.T) {
	out, b, pr := titleFixture(t, nil)
	b.Deferred = []webDeferredEntry{{Path: "assets/bgm/title.wav", Names: []string{"bgm_title"}}}
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	if len(s.UsedLate) != 0 {
		t.Errorf("届いた後に使った後回しの物は知らせないはず: %v", s.UsedLate)
	}
}

func TestSuggestWebDeferredSortsBySizeLargestFirst(t *testing.T) {
	out, b, pr := titleFixture(t, map[string]int{"assets/bg/gate.png": 9000, "assets/sfx/hit.wav": 20000, "assets/cast/b_plain.png": 100})
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	if got := candidatePaths(s); len(got) < 2 || got[0] != "assets/sfx/hit.wav" || got[1] != "assets/bg/gate.png" {
		t.Errorf("候補は大きい順のはず: %v", got)
	}
}

func TestSuggestWebDeferredSecondsDropByMovedBytes(t *testing.T) {
	out, b, pr := titleFixture(t, map[string]int{"assets/sfx/hit.wav": 200000})
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	var moved int64
	for _, c := range s.Candidates {
		moved += c.Wire
	}
	if diff := s.Before - s.After; fmt.Sprintf("%.3f", diff) != fmt.Sprintf("%.3f", webSecondsFor(moved)) {
		t.Errorf("起動の秒は候補の量の分だけ減るはず: %.3f → %.3f（%d B）", s.Before, s.After, moved)
	}
}

func TestSuggestWebDeferredArrivalsFollowCurrentDeferred(t *testing.T) {
	out, b, pr := titleFixture(t, map[string]int{"assets/bgm/sea.wav": 200000, "assets/sfx/hit.wav": 1000})
	b.Deferred = []webDeferredEntry{{Path: "assets/bgm/sea.wav"}}
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	for _, a := range s.Arrivals {
		if a.Path == "assets/sfx/hit.wav" && a.Seconds < s.After+webSecondsFor(200000) {
			t.Errorf("足した物は今の後回しの後に届くはず: %.2f 秒目（起動 %.2f）", a.Seconds, s.After)
		}
	}
}

func TestSuggestWebDeferredFontArrivesBeforeFontPlacedLater(t *testing.T) {
	out, b, pr := titleFixture(t, map[string]int{"assets/bgm/sea.wav": 200000, "font-atlas/gothic.fontatlas": 400000, "font-atlas/mincho.fontatlas": 1000})
	b.Deferred = []webDeferredEntry{{Path: "assets/bgm/sea.wav"}, {Path: "font-atlas/gothic.fontatlas"}}
	s := suggestWebDeferred(out, &b, pr, nil, nil, titleUsed(), webTitleFrames)
	for _, a := range s.Arrivals {
		if a.Path == "font-atlas/mincho.fontatlas" && a.Seconds >= s.After+webSecondsFor(200000) {
			t.Errorf("足したフォントは列の頭に入り、font: の行で後ろに置いたフォントより先に届くはず: %.2f 秒目（起動 %.2f）", a.Seconds, s.After)
		}
	}
}

func TestDeferredGlobsOfJoinsWholeFolder(t *testing.T) {
	paths := []string{"assets/cast/a_smile.png", "assets/cast/a_sad.png"}
	all := []string{"assets/cast/a_smile.png", "assets/cast/a_sad.png", "assets/bg/title.png"}
	got := deferredGlobsOf(paths, all, map[string]bool{"assets/cast/a_smile.png": true, "assets/cast/a_sad.png": true})
	if !reflect.DeepEqual(got, []string{"assets/cast/*.png"}) {
		t.Errorf("フォルダの同じ拡張子が全部候補なら 1 本の glob のはず: %v", got)
	}
}

func TestDeferredGlobsOfUsesPrefixWhenFolderHasTitleAsset(t *testing.T) {
	paths := []string{"assets/cast/a_smile.png", "assets/cast/a_sad.png"}
	all := append(paths, "assets/cast/b_plain.png")
	got := deferredGlobsOf(paths, all, map[string]bool{"assets/cast/a_smile.png": true, "assets/cast/a_sad.png": true})
	if !reflect.DeepEqual(got, []string{"assets/cast/a_*.png"}) {
		t.Errorf("タイトルで使う物がフォルダにあれば、頭の名前でまとめるはず: %v", got)
	}
}

func TestDeferredGlobsOfKeepsSinglePathWhenGlobWouldCatchUsedAsset(t *testing.T) {
	paths := []string{"assets/cast/a_smile.png"}
	all := []string{"assets/cast/a_smile.png", "assets/cast/a_sad.png"}
	got := deferredGlobsOf(paths, all, map[string]bool{"assets/cast/a_smile.png": true})
	if !reflect.DeepEqual(got, []string{"assets/cast/a_smile.png"}) {
		t.Errorf("1 本だけなら道のまま: %v", got)
	}
}

func TestDeferredGlobsOfCountsAlreadyDeferredAsAllowed(t *testing.T) {
	paths := []string{"assets/sfx/ui_save.wav", "assets/sfx/ui_open.wav"}
	all := append(paths, "assets/sfx/ui_page.wav")
	allowed := map[string]bool{"assets/sfx/ui_save.wav": true, "assets/sfx/ui_open.wav": true, "assets/sfx/ui_page.wav": true}
	if got := deferredGlobsOf(paths, all, allowed); !reflect.DeepEqual(got, []string{"assets/sfx/*.wav"}) {
		t.Errorf("もう後回しの物に当たる glob は使ってよいはず: %v", got)
	}
}

const projectWithDeferred = `{
  "title": "x",
  "web": {
    "orientation": "portrait",
    "// deferred": "シナリオの順。",
    "deferred": [
      "assets/bg/sea.png"
    ]
  }
}
`

func mustAppend(t *testing.T, data string, globs, fonts []string) (string, bool) {
	t.Helper()
	got, changed, err := withDeferredAppended([]byte(data), globs, fonts)
	if err != nil {
		t.Fatal(err)
	}
	var check map[string]any
	if err := json.Unmarshal(got, &check); err != nil {
		t.Fatalf("書き換えた字が JSON でない: %v\n%s", err, got)
	}
	return string(got), changed
}

func TestWithDeferredAppendedAddsToMultilineArrayWithSameIndent(t *testing.T) {
	got, _ := mustAppend(t, projectWithDeferred, []string{"assets/sfx/*.wav"}, nil)
	if !strings.Contains(got, "      \"assets/bg/sea.png\",\n      \"assets/sfx/*.wav\"\n    ]") {
		t.Errorf("今の列の後ろへ同じ字下げで足すはず:\n%s", got)
	}
}

func TestWithDeferredAppendedSkipsItemsAlreadyListed(t *testing.T) {
	got, changed := mustAppend(t, projectWithDeferred, []string{"assets/bg/sea.png"}, nil)
	if changed || got != projectWithDeferred {
		t.Errorf("もうある物だけなら何も変えないはず:\n%s", got)
	}
}

func TestWithDeferredAppendedAppendsNoteOnce(t *testing.T) {
	got, _ := mustAppend(t, projectWithDeferred, []string{"assets/sfx/*.wav"}, nil)
	again, _ := mustAppend(t, got, []string{"assets/x.wav"}, nil)
	if strings.Count(again, "--apply-deferred") != 1 || !strings.Contains(again, "シナリオの順。"+webApplyDeferredNote) {
		t.Errorf("今の説明の後ろに 1 度だけ足すはず:\n%s", again)
	}
}

func TestWithDeferredAppendedCreatesFontsKeyInWeb(t *testing.T) {
	got, _ := mustAppend(t, projectWithDeferred, nil, []string{"mincho"})
	var pr struct {
		Web struct {
			DeferredFonts []string `json:"deferredFonts"`
		} `json:"web"`
	}
	if err := json.Unmarshal([]byte(got), &pr); err != nil || !reflect.DeepEqual(pr.Web.DeferredFonts, []string{"mincho"}) {
		t.Errorf("web に deferredFonts を作るはず:\n%s", got)
	}
}

func TestWithDeferredAppendedCreatesWebWhenMissing(t *testing.T) {
	got, _ := mustAppend(t, "{\n  \"title\": \"x\"\n}\n", []string{"assets/a.png"}, nil)
	var pr struct {
		Web map[string]any `json:"web"`
	}
	if err := json.Unmarshal([]byte(got), &pr); err != nil || pr.Web["deferred"] == nil || pr.Web["// deferred"] == nil {
		t.Errorf("web が無ければ作り、deferred と説明を入れるはず:\n%s", got)
	}
}

func TestWithDeferredAppendedAddsInlineToOneLineArray(t *testing.T) {
	got, _ := mustAppend(t, `{"web": {"deferredFonts": ["round"]}}`, nil, []string{"label"})
	if !strings.Contains(got, `["round", "label"]`) {
		t.Errorf("1 行の配列には 1 行のまま足すはず: %s", got)
	}
}

func TestWithDeferredAppendedFillsEmptyArray(t *testing.T) {
	got, _ := mustAppend(t, `{"web": {"deferred": []}}`, []string{"assets/a.png", "assets/b.png"}, nil)
	if !strings.Contains(got, `"deferred": ["assets/a.png", "assets/b.png"]`) {
		t.Errorf("空の配列を埋めるはず: %s", got)
	}
}

func TestDeferredGlobsOfKeepsPathsWhenExtensionCaseDiffers(t *testing.T) {
	paths := []string{"assets/cast/a.PNG", "assets/cast/b.png"}
	got := deferredGlobsOf(paths, paths, map[string]bool{"assets/cast/a.PNG": true, "assets/cast/b.png": true})
	if !reflect.DeepEqual(got, []string{"assets/cast/a.PNG", "assets/cast/b.png"}) {
		t.Errorf("1 本の glob で全部に当たらない時は道のまま: %v", got)
	}
}

func TestWithDeferredAppendedJoinsNoteWithPeriod(t *testing.T) {
	got, _ := mustAppend(t, `{"web": {"// deferred": "シナリオの順", "deferred": ["a.png"]}}`, []string{"b.png"}, nil)
	if !strings.Contains(got, "シナリオの順。"+webApplyDeferredNote) {
		t.Errorf("句点で終わらない説明には句点を挟んで足すはず: %s", got)
	}
}

func TestWithDeferredAppendedRejectsNonStringDeferred(t *testing.T) {
	if _, _, err := withDeferredAppended([]byte(`{"web": {"deferred": [{"glob": "a.png"}]}}`), []string{"b.png"}, nil); err == nil {
		t.Error("web.deferred が字の配列でなければ書かずに止まるはず")
	}
}

func TestWithDeferredAppendedRejectsNonObjectWeb(t *testing.T) {
	if _, _, err := withDeferredAppended([]byte(`{"web": []}`), []string{"b.png"}, nil); err == nil {
		t.Error("web が object でなければ止まるはず")
	}
}

func TestWithDeferredAppendedWritesControlCharAsJSON(t *testing.T) {
	got, _ := mustAppend(t, `{"web": {"deferred": ["a.png"]}}`, []string{"b\x01.png"}, nil)
	if !strings.Contains(got, `"b\u0001.png"`) {
		t.Errorf("制御文字は JSON の書き方で書くはず: %s", got)
	}
}

func TestParseExportWebArgsRejectsApplyDeferredWithCheck(t *testing.T) {
	if _, err := parseExportWebArgs([]string{"g", "--apply-deferred", "--check"}); err == nil {
		t.Error("--apply-deferred は --check と一緒に使えないはず")
	}
}

func TestWriteTitleAssetsStopsApplyWithoutRecord(t *testing.T) {
	game := t.TempDir()
	file := filepath.Join(game, "project.json")
	if err := os.WriteFile(file, []byte(projectWithDeferred), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	code := writeTitleAssets(&out, &errOut, exportWebOptions{ApplyDeferred: true}, exportWebPaths{Game: game}, &webBundle{}, exportProject{}, nil, webEmbedPlan{}, nil)
	data, _ := os.ReadFile(file)
	if code != 1 || string(data) != projectWithDeferred {
		t.Errorf("記録が無い時の --apply-deferred は 1 で止まり project.json を変えないはず: code=%d", code)
	}
}

func TestParseExportWebArgsRejectsApplyDeferredWithoutBrowserCheck(t *testing.T) {
	if _, err := parseExportWebArgs([]string{"g", "--apply-deferred", "--no-browser-check"}); err == nil {
		t.Error("--apply-deferred は --no-browser-check と一緒に使えないはず")
	}
}

func TestExportWebUsageNamesTitleFrames(t *testing.T) {
	if !strings.Contains(exportWebUsage, fmt.Sprintf("タイトルの %d コマ", webTitleFrames)) {
		t.Errorf("使い方のコマ数は webTitleFrames（%d）と同じはず", webTitleFrames)
	}
}
