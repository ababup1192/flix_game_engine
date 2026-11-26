package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func declaredBudget() webStartupBudget {
	return webStartupBudget{Seconds: webStartupTargetSeconds, Declared: true}
}

func TestExportVerdictGreenPublishes(t *testing.T) {
	if got := exportVerdictOf(false, false, declaredBudget()); got != exportPublish {
		t.Errorf("緑なら書き出すはず: %v", got)
	}
}

func TestExportVerdictRedWithDraftKeepsDraft(t *testing.T) {
	if got := exportVerdictOf(true, true, declaredBudget()); got != exportDraft {
		t.Errorf("赤で --draft なら draft で残すはず: %v", got)
	}
}

func TestExportVerdictRedWithDeclaredBudgetStops(t *testing.T) {
	if got := exportVerdictOf(true, false, declaredBudget()); got != exportStop {
		t.Errorf("赤で予算を書いたゲームは止めるはず: %v", got)
	}
}

func TestExportVerdictRedWithoutBudgetIsMigrating(t *testing.T) {
	if got := exportVerdictOf(true, false, defaultWebStartupBudget()); got != exportMigrating {
		t.Errorf("赤で予算を書いていないゲームは止めずに ★ のはず: %v", got)
	}
}

func TestExportGateAddsTitle4gStoppedRed(t *testing.T) {
	b := webBundle{Checks: &webBundleChecks{Title4g: "stopped"}}
	g := exportGateOf(newWebSizeTable(t.TempDir()), &b, defaultWebStartupBudget())
	if len(g.Red) != 1 || g.Red[0] != webTitle4gStoppedRed {
		t.Errorf("4G のタイトルで止まった束は赤の 1 行が付くはず: %v", g.Red)
	}
}

func TestExportGateWithoutChecksHasNoTitle4gRed(t *testing.T) {
	b := webBundle{}
	if g := exportGateOf(newWebSizeTable(t.TempDir()), &b, defaultWebStartupBudget()); !g.green() {
		t.Errorf("空の束で確かめの記録が無ければ緑のはず: %v", g.Red)
	}
}

func TestExportStopTextListsRedAndDraftHint(t *testing.T) {
	text := exportStopText("/x/out", webGate{Red: []string{"赤の理由"}})
	if !strings.Contains(text, "  止めた: 赤の理由\n") || !strings.HasSuffix(text, "作業中に開くだけなら --draft（web-check が拒む draft のマーカーが付く）\n") {
		t.Errorf("赤の行と --draft の案内を書くはず: %q", text)
	}
}

func TestGateSummaryDraftNamesDraft(t *testing.T) {
	var w strings.Builder
	writeWebGateSummary(&w, webGate{Red: []string{"赤"}}, exportDraft)
	if !strings.Contains(w.String(), "--draft で書き出した") {
		t.Errorf("draft の時は draft で書き出したと書くはず: %q", w.String())
	}
}

func TestGateSummaryMigratingWritesAdvice(t *testing.T) {
	var w strings.Builder
	writeWebGateSummary(&w, webGate{Red: []string{"赤"}, Advice: []string{"手 1"}}, exportMigrating)
	if !strings.Contains(w.String(), "    1. 手 1\n") {
		t.Errorf("移行中の赤は次に打つ手を書くはず: %q", w.String())
	}
}

func TestGateSummaryStopWritesOnlyGateLine(t *testing.T) {
	var w strings.Builder
	g := webGate{Red: []string{"赤"}, Advice: []string{"手 1"}}
	writeWebGateSummary(&w, g, exportStop)
	if w.String() != "  "+g.line()+"\n" {
		t.Errorf("止める時の表は門の 1 行だけ（理由は errOut）のはず: %q", w.String())
	}
}

func TestCandidateAdviceWithoutSuggestionIsEmpty(t *testing.T) {
	if got := webCandidateAdvice(nil); got != "" {
		t.Errorf("記録が無ければ空のはず: %q", got)
	}
}

func TestCandidateAdviceWithoutGainIsEmpty(t *testing.T) {
	s := &webDeferredSuggestion{Candidates: []webDeferredCandidate{{Path: "a"}}, Before: 5, After: 5}
	if got := webCandidateAdvice(s); got != "" {
		t.Errorf("起動が減らなければ空のはず: %q", got)
	}
}

func TestCandidateAdviceNamesCountAndGain(t *testing.T) {
	s := &webDeferredSuggestion{Candidates: []webDeferredCandidate{{Path: "a"}, {Path: "b"}}, Before: 9, After: 7.5}
	if got := webCandidateAdvice(s); !strings.HasPrefix(got, "後回しの候補 2 本") || !strings.Contains(got, "約 -1.5 秒") {
		t.Errorf("本数と減る秒を書くはず: %q", got)
	}
}

func TestResetExportOutRefusesFolderWithoutBundle(t *testing.T) {
	out := t.TempDir()
	keep := filepath.Join(out, "mine.txt")
	if err := os.WriteFile(keep, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := resetExportOut(out); err == nil || !fileExists(keep) {
		t.Errorf("bundle.json の無いフォルダは消さずに誤りを返すはず: err=%v", err)
	}
}

func TestResetExportOutClearsPreviousExport(t *testing.T) {
	out := t.TempDir()
	for _, name := range []string{"bundle.json", "old.wasm"} {
		if err := os.WriteFile(filepath.Join(out, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := resetExportOut(out); err != nil || fileExists(filepath.Join(out, "old.wasm")) || !dirExists(filepath.Join(out, "assets")) {
		t.Errorf("前の書き出しは空にして assets/ だけ作るはず: err=%v", err)
	}
}

func TestResetExportOutCreatesMissingFolder(t *testing.T) {
	out := filepath.Join(t.TempDir(), "new")
	if err := resetExportOut(out); err != nil || !dirExists(filepath.Join(out, "assets")) {
		t.Errorf("無いフォルダは作るはず: err=%v", err)
	}
}

func TestSizeTableReadsEachFileOnce(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "bundle.json")
	if err := os.WriteFile(p, []byte("12345"), 0o644); err != nil {
		t.Fatal(err)
	}
	sizes := newWebSizeTable(dir)
	sizes.rawOf("bundle.json")
	if err := os.WriteFile(p, []byte("1234567890"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := sizes.rawOf("bundle.json"); got != 5 {
		t.Errorf("一度引いた大きさを覚えているはず（書き直したら表を作り直す）: %d", got)
	}
}

func TestSizeTableAssetUsesServedPath(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "assets", "assets", "bg"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "assets", "assets", "bg", "sea.webp"), make([]byte, 300), 0o644); err != nil {
		t.Fatal(err)
	}
	b := webBundle{Transcoded: map[string]string{"assets/bg/sea.png": "assets/bg/sea.webp"}}
	if got := newWebSizeTable(dir).assetWire(&b, "assets/bg/sea.png"); got != 300 {
		t.Errorf("配る形（WebP）の大きさをそのまま数えるはず: %d", got)
	}
}

func TestStartupEstimateLineNamesSecondsAndPrelude(t *testing.T) {
	var w strings.Builder
	writeStartupEstimate(&w, webStartupEstimate{Seconds: 9.8}, webStartupSize{StartCount: 3})
	if !strings.Contains(w.String(), "3 本") || !strings.Contains(w.String(), "約 9.8 秒（前置き 1.5 秒を含む）") {
		t.Errorf("本数と秒と前置きを書くはず: %q", w.String())
	}
}

func TestTapWaitEstimateWithoutWaitsIsZero(t *testing.T) {
	var w strings.Builder
	writeTapWaitEstimate(&w, webTapWait{})
	if !strings.Contains(w.String(), ": 0 秒（届く前に使うと engine が待つ後回しの物が無い）") {
		t.Errorf("待つ物が無ければ 0 秒のはず: %q", w.String())
	}
}

func TestTapWaitEstimateLeavesLateWaitsToTheGate(t *testing.T) {
	var w strings.Builder
	writeTapWaitEstimate(&w, webTapWait{Group: []string{"start"}, Count: 2, Seconds: 5})
	if strings.Contains(w.String(), "知らせ") {
		t.Errorf("遅く届く物は門の 1 行で言い、見積もりの行に並べないはず: %q", w.String())
	}
}

func TestTitle4gOfStoppedWait(t *testing.T) {
	if got, _ := webTitle4gOf(&webMissingReport{Waits: []webMissingWait{{Kind: "stopped"}}}, nil); got != "stopped" {
		t.Errorf("止まった待ちがあれば stopped のはず: %s", got)
	}
}

func TestTitle4gOfGaveUpSkip(t *testing.T) {
	if got, _ := webTitle4gOf(&webMissingReport{Skips: []webMissingSkip{{Why: "gaveUp"}}}, nil); got != "stopped" {
		t.Errorf("待つはずの物を諦めたら stopped のはず: %s", got)
	}
}

func TestTitle4gOfWithoutRecordIsSkipped(t *testing.T) {
	if got, why := webTitle4gOf(nil, nil); got != "skipped" || why == "" {
		t.Errorf("記録が無ければ理由付きで skipped のはず: %s %q", got, why)
	}
}

func TestWebCheckReportRedSaysStop(t *testing.T) {
	var w strings.Builder
	writeWebCheck(&w, webCheckResult{Dir: "/x", Gate: webGate{Red: []string{"赤"}, Budget: defaultWebStartupBudget()}})
	if !strings.Contains(w.String(), "（止める）\n") || !strings.Contains(w.String(), "  止めた: 赤\n") {
		t.Errorf("赤なら止めると赤の行を書くはず: %q", w.String())
	}
}

func TestRunExportWebWithoutGameFolderIsCallError(t *testing.T) {
	var out, errOut strings.Builder
	code := runExportWeb(&out, &errOut, exportWebOptions{Game: filepath.Join(t.TempDir(), "none")})
	if code != 2 || !strings.HasPrefix(errOut.String(), "fge export-web: ゲームのフォルダが無い") {
		t.Errorf("ゲームのフォルダが無ければ 2 と理由のはず: code=%d %q", code, errOut.String())
	}
}

func TestRunExportWebRemovesDiscardedOut(t *testing.T) {
	out := t.TempDir()
	f := exportFailf(1, "止めた\n").discarding(out)
	var errOut strings.Builder
	if code := reportExportFailure(&errOut, f); code != 1 || dirExists(out) || errOut.String() != "止めた\n" {
		t.Errorf("消す書き出し先を消して字を書き、番号を返すはず: code=%d exists=%v", code, dirExists(out))
	}
}

func TestBrotliWindowBitsEmptyIsSmallest(t *testing.T) {
	if got := brotliWindowBits(0); got != 10 {
		t.Errorf("空は最も小さいウィンドウ 10 のはず: %d", got)
	}
}

func TestBrotliWindowBitsFitsSmallestWindowExactly(t *testing.T) {
	if got := brotliWindowBits(1008); got != 10 {
		t.Errorf("2^10−16 = 1008 バイトはウィンドウ 10 に収まるはず: %d", got)
	}
}

func TestBrotliWindowBitsGrowsPastSmallestWindow(t *testing.T) {
	if got := brotliWindowBits(1009); got != 11 {
		t.Errorf("1009 バイトはウィンドウ 11 のはず: %d", got)
	}
}

func TestBrotliWindowBitsCapsAtLargestWindow(t *testing.T) {
	if got := brotliWindowBits(1<<24 - 15); got != 24 {
		t.Errorf("2^24−16 を超えてもウィンドウは 24 で止まるはず: %d", got)
	}
}

func TestGateAdviceNamesWasmBrotliFalseWhenOff(t *testing.T) {
	b := webBundle{}
	g := webGateOf(newWebSizeTable(t.TempDir()), &b, defaultWebStartupBudget())
	if len(g.Advice) != 1 || !strings.Contains(g.Advice[0], "wasmBrotli: false を外すと") {
		t.Errorf("brotli で配らない束は wasmBrotli: false を外す手を出すはず: %v", g.Advice)
	}
}

func TestGateAdviceOmitsBrotliWhenOn(t *testing.T) {
	b := webBundle{WasmBrotli: webWasmBrotliFile}
	if g := webGateOf(newWebSizeTable(t.TempDir()), &b, defaultWebStartupBudget()); len(g.Advice) != 0 {
		t.Errorf("brotli で配る束は brotli の手を出さないはず: %v", g.Advice)
	}
}

func TestBundleBudgetWithoutBudgetIsDefault(t *testing.T) {
	if got := webBundleBudget(&webBundle{}); got.Seconds != webStartupTargetSeconds || got.Declared {
		t.Errorf("束に予算が無ければ既定の 16 秒で書いた扱いにしないはず: %+v", got)
	}
}

func TestBundleBudgetCopiedIsDeclared(t *testing.T) {
	b := webBundle{StartupBudget: &webStartupBudget{Seconds: 12}}
	if got := webBundleBudget(&b); got.Seconds != 12 || !got.Declared {
		t.Errorf("束の予算は書いた扱いのはず: %+v", got)
	}
}
