package main

import (
	"encoding/json"
	"fmt"
	"errors"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func mustBudget(t *testing.T, raw string) webStartupBudget {
	t.Helper()
	b, err := resolveWebStartupBudget(json.RawMessage(raw))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestStartupBudgetWithoutKeyIsDefaultAndUndeclared(t *testing.T) {
	b := mustBudget(t, `{}`)
	if b.Seconds != webStartupTargetSeconds || b.Declared {
		t.Errorf("鍵が無ければ既定の 16 秒で、書いた扱いにしないはず: %+v", b)
	}
}

func TestStartupBudgetDeclaredKeepsSeconds(t *testing.T) {
	if b := mustBudget(t, `{"startupBudget": {"seconds": 12, "why": ""}}`); b.Seconds != 12 || !b.Declared {
		t.Errorf("書いた秒と書いた扱いのはず: %+v", b)
	}
}

func TestStartupBudgetOverDefaultNeedsWhy(t *testing.T) {
	if _, err := resolveWebStartupBudget(json.RawMessage(`{"startupBudget": {"seconds": 20, "why": " "}}`)); err == nil {
		t.Error("16 秒を超えて why が空なら誤りのはず")
	}
}

func TestStartupBudgetOverDefaultWithWhyIsAccepted(t *testing.T) {
	if b := mustBudget(t, `{"startupBudget": {"seconds": 20, "why": "3D の部屋をタイトルで使う"}}`); b.Seconds != 20 {
		t.Errorf("why があれば 20 秒を受けるはず: %+v", b)
	}
}

func TestStartupBudgetRejectsUnknownKey(t *testing.T) {
	if _, err := resolveWebStartupBudget(json.RawMessage(`{"startupBudget": {"second": 12}}`)); err == nil {
		t.Error("書き違いの鍵は誤りのはず")
	}
}

func TestStartupBudgetRejectsOutOfRange(t *testing.T) {
	if _, err := resolveWebStartupBudget(json.RawMessage(`{"startupBudget": {"seconds": 200, "why": "x"}}`)); err == nil {
		t.Error("120 秒を超える予算は誤りのはず")
	}
}

func TestStartupBudgetRejectsMissingSeconds(t *testing.T) {
	if _, err := resolveWebStartupBudget(json.RawMessage(`{"startupBudget": {"why": "x"}}`)); err == nil {
		t.Error("seconds の無い予算は誤りのはず")
	}
}

func TestStartupBudgetRejectsUnknownStartKey(t *testing.T) {
	if _, err := resolveWebStartupBudget(json.RawMessage(`{"startupBudget": {"seconds": 16, "startKeys": ["Return"]}}`)); err == nil {
		t.Error("送れないキーは誤りのはず")
	}
}

func TestStartupBudgetStartKeysDefaultToEnter(t *testing.T) {
	if got := mustBudget(t, `{}`).startKeys(); len(got) != 1 || got[0] != "Enter" {
		t.Errorf("既定は Enter のはず: %v", got)
	}
}

func withLogo(b *webBundle, mode string, waitFor ...string) {
	b.Splash = &webSplash{AfterTap: &webAfterTap{Mode: mode, MinSeconds: webAfterTapMinSeconds, MaxSeconds: webAfterTapMaxSeconds, WaitFor: waitFor}}
}

func groupFixture(t *testing.T) (string, webBundle) {
	return tapWaitFixture(t, webDeferredEntry{Path: "assets/a.webp", Group: "start"}, webDeferredEntry{Path: "assets/b.webp", Group: "start"})
}

func TestGateLogoCoversGroupWait(t *testing.T) {
	out, b := groupFixture(t)
	withLogo(&b, "engine", "start")
	g := webGateOf(out, &b, defaultWebStartupBudget())
	if g.Playable != g.Startup {
		t.Errorf("group の待ち 2.15 秒はロゴの 3 秒に収まり、数字に入らないはず: %+v", g)
	}
}

func TestGateCountsGroupWaitBeyondLogo(t *testing.T) {
	out, b := tapWaitFixture(t, webDeferredEntry{Path: "assets/a.webp", Group: "start"}, webDeferredEntry{Path: "assets/b.webp", Group: "start"},
		webDeferredEntry{Path: "assets/se.ogg", Group: "start"})
	withLogo(&b, "engine", "start")
	g := webGateOf(out, &b, defaultWebStartupBudget())
	if math.Abs(g.Playable-(g.Startup+g.TapWait-webAfterTapMaxSeconds)) > 1e-9 {
		t.Errorf("ロゴの 3 秒を超えた分だけ足すはず: %+v", g)
	}
}

func TestGateLogoNoneDoesNotCover(t *testing.T) {
	out, b := groupFixture(t)
	withLogo(&b, "none", "start")
	g := webGateOf(out, &b, defaultWebStartupBudget())
	if g.LogoCover != 0 {
		t.Errorf("ロゴを出さないゲームは覆わないはず: %+v", g)
	}
}

func TestGateLogoDoesNotCoverWhenGroupArrivesBeforeMinSeconds(t *testing.T) {
	out, b := tapWaitFixture(t, webDeferredEntry{Path: "assets/a.webp", Group: "start"})
	withLogo(&b, "engine", "start")
	b.Splash.AfterTap.MinSeconds = 2
	b.Checks = &webBundleChecks{TapWaitSeconds: ptrFloat(4)}
	g := webGateOf(out, &b, defaultWebStartupBudget())
	if g.LogoCover != 0 {
		t.Errorf("group が minSeconds より前に届けば頁はロゴを出さないので、測った待ちが長くても覆わないはず: %+v", g)
	}
}

func TestGateCapsLogoCoverAtThreeSeconds(t *testing.T) {
	out, b := groupFixture(t)
	withLogo(&b, "engine", "start")
	b.Splash.AfterTap.MaxSeconds = 30
	if g := webGateOf(out, &b, defaultWebStartupBudget()); g.LogoCover != webAfterTapMaxSeconds {
		t.Errorf("bundle.json の maxSeconds を書き換えても 3 秒までしか覆わないはず: %v", g.LogoCover)
	}
}

func TestGateOldBundleWithoutSplashDoesNotCover(t *testing.T) {
	out, b := groupFixture(t)
	b.Checks = &webBundleChecks{TapWaitSeconds: ptrFloat(2)}
	g := webGateOf(out, &b, defaultWebStartupBudget())
	if g.LogoCover != 0 {
		t.Errorf("splash の無い古い束はロゴが出ないので覆わないはず: %+v", g)
	}
}

func TestGateWithoutGroupCountsZeroWhenUnmeasured(t *testing.T) {
	out, b := tapWaitFixture(t, webDeferredEntry{Path: "assets/a.webp"})
	withLogo(&b, "engine")
	g := webGateOf(out, &b, defaultWebStartupBudget())
	if g.TapWait != 0 || !g.Unknown {
		t.Errorf("group が無く測っていなければ 0 秒で数え、分からない印を立てるはず: %+v", g)
	}
}

func TestGateMeasuredWaitIsNotedUncoveredUntilVerified(t *testing.T) {
	out, b := tapWaitFixture(t, webDeferredEntry{Path: "assets/a.webp"})
	withLogo(&b, "engine")
	b.Checks = &webBundleChecks{TapWaitSeconds: ptrFloat(5)}
	g := webGateOf(out, &b, defaultWebStartupBudget())
	if g.Playable != g.Startup || !strings.Contains(strings.Join(g.Notes, "\n"), fmt.Sprintf("遊べるまで %.1f 秒", g.Startup+5)) {
		t.Errorf("揺れを確かめるまで測った値は門に入れず、ロゴの出ない group 無しの 5 秒をそのまま足した数を ★ で出すはず: %+v", g)
	}
}

func TestGateUsesLargerOfMeasuredAndGroupEstimate(t *testing.T) {
	out, b := groupFixture(t)
	withLogo(&b, "engine", "start")
	b.Checks = &webBundleChecks{TapWaitSeconds: ptrFloat(0.5)}
	if g := webGateOf(out, &b, defaultWebStartupBudget()); g.TapWait < 2 {
		t.Errorf("測った値が group の見積もりより短くても、見積もりを使うはず: %+v", g)
	}
}

func TestGateRedWhenOverBudget(t *testing.T) {
	out, b := tapWaitFixture(t)
	if g := webGateOf(out, &b, webStartupBudget{Seconds: 1}); g.green() {
		t.Errorf("予算 1 秒は超えるはず: %+v", g)
	}
}

func TestGateNotesBudgetOverDefault(t *testing.T) {
	out, b := tapWaitFixture(t)
	g := webGateOf(out, &b, webStartupBudget{Seconds: 20, Why: "理由"})
	if len(g.Notes) == 0 || !strings.Contains(g.Notes[0], "★ 予算 20 秒") {
		t.Errorf("既定より上の予算は ★ で出すはず: %v", g.Notes)
	}
}

func ptrFloat(v float64) *float64 { return &v }

// checkFixture は web-check に読ませる束（bundle.json・sums.json・version.txt を書いた物）。
func checkFixture(t *testing.T, edit func(b *webBundle)) (string, webBundle) {
	t.Helper()
	out, b := tapWaitFixture(t)
	for _, name := range []string{"fge-web.js", "wasm-gc-runtime.js", "classes.wasm"} {
		if err := os.WriteFile(filepath.Join(out, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	b.Checks = &webBundleChecks{Title4g: "ok"}
	if edit != nil {
		edit(&b)
	}
	sealBundle(t, out, b)
	return out, b
}

func sealBundle(t *testing.T, out string, b webBundle) {
	t.Helper()
	raw, err := marshalWebBundle(b)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(out, "bundle.json"), raw, 0o644); err != nil {
		t.Fatal(err)
	}
	hash, err := writeWebSums(out)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(out, "version.txt"), []byte(hash+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func mustWebCheck(t *testing.T, dir string) webCheckResult {
	t.Helper()
	r, err := runWebCheck(dir, false)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestWebCheckPassesGreenBundle(t *testing.T) {
	out, _ := checkFixture(t, nil)
	if r := mustWebCheck(t, out); !r.Gate.green() {
		t.Errorf("小さな束は通るはず: %v", r.Gate.Red)
	}
}

func TestWebCheckUsesDefaultBudgetWhenBundleHasNone(t *testing.T) {
	out, _ := checkFixture(t, nil)
	if r := mustWebCheck(t, out); !r.Gate.BudgetDefault || r.Gate.Budget.Seconds != webStartupTargetSeconds {
		t.Errorf("予算の無い束は既定の 16 秒のはず: %+v", r.Gate)
	}
}

func TestWebCheckRejectsOverBudgetFromBundle(t *testing.T) {
	out, _ := checkFixture(t, func(b *webBundle) { b.StartupBudget = &webStartupBudget{Seconds: 1} })
	if r := mustWebCheck(t, out); r.Gate.green() {
		t.Error("bundle.json の予算 1 秒を超えるので止めるはず")
	}
}

func TestWebCheckRejectsBundleBudgetWithoutWhy(t *testing.T) {
	out, _ := checkFixture(t, func(b *webBundle) { b.StartupBudget = &webStartupBudget{Seconds: 30} })
	if r := mustWebCheck(t, out); r.Gate.green() {
		t.Error("bundle.json の予算が 16 秒を超えて why が無ければ止めるはず")
	}
}

func TestWebCheckRejectsDraft(t *testing.T) {
	out, _ := checkFixture(t, func(b *webBundle) { b.Draft, b.DraftReasons = true, []string{"予算"} })
	if r := mustWebCheck(t, out); r.Gate.green() {
		t.Error("draft のマーカーの付いた束は止めるはず")
	}
}

func TestWebCheckRejectsStoppedTitle(t *testing.T) {
	out, _ := checkFixture(t, func(b *webBundle) { b.Checks.Title4g = "stopped" })
	if r := mustWebCheck(t, out); r.Gate.green() {
		t.Error("4G のタイトルで止まった束は止めるはず")
	}
}

func TestWebCheckNotesSkippedTitle(t *testing.T) {
	out, _ := checkFixture(t, func(b *webBundle) { b.Checks.Title4g, b.Checks.SkippedWhy = "skipped", "--no-browser-check" })
	r := mustWebCheck(t, out)
	if !r.Gate.green() || !strings.Contains(strings.Join(r.Gate.Notes, "\n"), "--no-browser-check") {
		t.Errorf("飛ばした確かめは止めずに ★ で出すはず: %v %v", r.Gate.Red, r.Gate.Notes)
	}
}

func TestWebCheckRejectsFileChangedAfterExport(t *testing.T) {
	out, _ := checkFixture(t, nil)
	writeServed(t, out, "assets/a.webp", 10)
	if r := mustWebCheck(t, out); len(r.Sums.Mismatch) != 1 || r.Gate.green() {
		t.Errorf("書き出した後に替えた絵を見抜いて止めるはず: %+v", r.Sums)
	}
}

func TestWebCheckRejectsEditedBundleJson(t *testing.T) {
	out, b := checkFixture(t, nil)
	b.StartupBudget = &webStartupBudget{Seconds: 100, Why: "手で上げた"}
	raw, _ := marshalWebBundle(b)
	if err := os.WriteFile(filepath.Join(out, "bundle.json"), raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if r := mustWebCheck(t, out); r.Gate.green() {
		t.Error("bundle.json だけを手で書き換えた束は sums.json と合わず止めるはず")
	}
}

func TestWebCheckRejectsMissingServedFile(t *testing.T) {
	out, _ := checkFixture(t, nil)
	if err := os.Remove(exportAssetPath(out, "assets/a.webp")); err != nil {
		t.Fatal(err)
	}
	if r := mustWebCheck(t, out); len(r.Sums.MissingUsed) != 1 || r.Gate.green() {
		t.Errorf("頁が取る絵が無ければ止めるはず: %+v", r.Sums)
	}
}

func TestWebCheckOnlyNotesMissingSpareWav(t *testing.T) {
	out, _ := checkFixture(t, func(b *webBundle) { b.Transcoded = map[string]string{"assets/se.ogg": "assets/se.opus.webm"} })
	writeServed(t, out, "assets/se.opus.webm", 10)
	b, _ := loadWebBundle(out)
	sealBundle(t, out, b)
	if err := os.Remove(exportAssetPath(out, "assets/se.ogg")); err != nil {
		t.Fatal(err)
	}
	r := mustWebCheck(t, out)
	if len(r.Sums.MissingSpare) != 1 || !r.Gate.green() {
		t.Errorf("頁が取らない元の音の控えが無いだけなら止めないはず: %+v %v", r.Sums, r.Gate.Red)
	}
}

func TestWebCheckIgnoresFilesOutsideSums(t *testing.T) {
	out, _ := checkFixture(t, nil)
	if err := os.WriteFile(filepath.Join(out, "measure.js"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if r := mustWebCheck(t, out); !r.Gate.green() {
		t.Errorf("書き出しの後に足したファイルは数えないはず: %v", r.Gate.Red)
	}
}

func TestWebCheckRejectsHomePathInWasm(t *testing.T) {
	t.Setenv("HOME", "/Users/tester-home")
	out, _ := checkFixture(t, nil)
	if err := os.WriteFile(filepath.Join(out, "classes.wasm"), []byte("\x00/Users/tester-home/game/src/A.flix\x00"), 0o644); err != nil {
		t.Fatal(err)
	}
	b, _ := loadWebBundle(out)
	sealBundle(t, out, b)
	if r := mustWebCheck(t, out); r.Leaks == 0 || r.Gate.green() {
		t.Errorf("wasm にホームのパスが残れば止めるはず: %d", r.Leaks)
	}
}

func TestWebCheckDirsTakesBundleFolderOnceFromFiles(t *testing.T) {
	out, _ := checkFixture(t, nil)
	dirs, err := webCheckDirs([]string{filepath.Join(out, "bundle.json"), filepath.Join(out, "classes.wasm")})
	if err != nil || len(dirs) != 1 {
		t.Errorf("同じ束のファイル 2 本は 1 つのフォルダのはず: %v %v", dirs, err)
	}
}

func TestWebCheckDirsSkipsFileOutsideBundle(t *testing.T) {
	p := filepath.Join(t.TempDir(), "bundle.json")
	if err := os.WriteFile(p, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if dirs, err := webCheckDirs([]string{p}); err != nil || len(dirs) != 0 {
		t.Errorf("sums.json の無いフォルダの bundle.json は束でないので飛ばすはず: %v %v", dirs, err)
	}
}

func TestTitle4gStoppedWhenTitleWaited(t *testing.T) {
	if got, _ := webTitle4gOf(&webMissingReport{Waits: []webMissingWait{{Kind: "stopped"}}}, nil); got != "stopped" {
		t.Errorf("タイトルで止まった待ちは stopped のはず: %s", got)
	}
}

func TestTitle4gOkWhenOnlyPressedWait(t *testing.T) {
	if got, _ := webTitle4gOf(&webMissingReport{Waits: []webMissingWait{{Kind: "pressed"}}}, nil); got != "ok" {
		t.Errorf("押した時の待ちはタイトルの門にしないはず: %s", got)
	}
}

func TestTitle4gSkippedOnError(t *testing.T) {
	if got, _ := webTitle4gOf(nil, errors.New("x")); got != "skipped" {
		t.Errorf("確かめが落ちたら skipped のはず: %s", got)
	}
}

func TestPlaceholderImageRowWithoutWhyIsListed(t *testing.T) {
	_, b := tapWaitFixture(t)
	pol, err := resolveWebDeferredPolicy(json.RawMessage(`{"deferredPolicy": [{"match": "assets/a.webp", "onMissing": "placeholder"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := placeholderImageRowsWithoutWhy([]webDeferredEntry{{Path: "assets/a.webp"}}, pol, &b); len(got) != 1 {
		t.Errorf("why の無い絵の placeholder の行を挙げるはず: %v", got)
	}
}

func TestPlaceholderImageRowWithWhyIsAccepted(t *testing.T) {
	_, b := tapWaitFixture(t)
	pol, err := resolveWebDeferredPolicy(json.RawMessage(`{"deferredPolicy": [{"match": "assets/a.webp", "onMissing": "placeholder", "why": "カードの絵は枠だけで遊べる"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if got := placeholderImageRowsWithoutWhy([]webDeferredEntry{{Path: "assets/a.webp"}}, pol, &b); len(got) != 0 {
		t.Errorf("why があれば挙げないはず: %v", got)
	}
}

func TestTapMeasureCappedUsesLimit(t *testing.T) {
	m := &webTapMeasure{Seconds: 12, Capped: true}
	if got := m.tapSeconds(); got == nil || *got != webTapMeasureLimit.Seconds() {
		t.Errorf("明けなかった待ちは上限の秒で残すはず: %v", got)
	}
}

func TestTapMeasureWithoutRecordLeavesNothing(t *testing.T) {
	if got := (&webTapMeasure{NoRecord: true}).tapSeconds(); got != nil {
		t.Errorf("待ちの記録が無ければ測った値を残さないはず: %v", *got)
	}
}
