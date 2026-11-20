package main

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/cdp"
)

// probeOnPage は fge-web.js の待ちの記録をまねた頁で webTapProbe を評価する（Chrome が無ければ飛ばす）。
func probeOnPage(t *testing.T, script string) webTapProbeResult {
	t.Helper()
	if _, err := cdp.FindChrome(); err != nil {
		t.Skip("Chrome が無い")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<script>"+script+"</script>"), 0o644); err != nil {
		t.Fatal(err)
	}
	ln, closeServer, err := serveWebCheck(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer closeServer()
	page, err := cdp.OpenPage(cdp.PageOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer page.Close()
	if err := page.Navigate(fmt.Sprintf("http://%s/index.html", ln.Addr().String())); err != nil {
		t.Fatal(err)
	}
	if err := page.WaitFor(`typeof fgeTapMark !== "undefined"`, 10*time.Second); err != nil {
		t.Fatal(err)
	}
	var r webTapProbeResult
	if err := page.Eval(webTapProbe, &r); err != nil {
		t.Fatal(err)
	}
	return r
}

const probeRecords = `
var fgeNetClock = { at: 1000 }, fgeFrameNo = 400;
var pressed = { kind: "pressed", startedAt: 3000, seconds: 2.5 };
window.fgeMissingWaits = [{ kind: "stopped", startedAt: 500, seconds: 9 }, pressed, { kind: "stopped", startedAt: 6000, seconds: 1 }];
window.fgeMissingSkips = [{ kind: "texture", why: "placeholder", frame: 100, name: "card" }, { kind: "texture", why: "placeholder", frame: 10, name: "early" }];
window.fgeTapMark = { at: 2990, frame: 90 };
`

func TestTapOutcomeCutAtLimitWithoutFramesIsSkipped(t *testing.T) {
	if _, skipped := webTapOutcome(webTapProbeResult{State: "none", Frames: 12, SinceTap: 40}); skipped == "" {
		t.Error("記録が無いまま上限で切れた（コマが進まなかった）なら、待たずに動いたでなく測れなかったのはず")
	}
}

func TestTapOutcomeNoRecordAfterEnoughFrames(t *testing.T) {
	m, skipped := webTapOutcome(webTapProbeResult{State: "none", Frames: webTapNoRecordFrames, SinceTap: 6})
	if skipped != "" || !m.NoRecord {
		t.Errorf("コマが十分進んで記録が無ければ、待たずに動いたのはず: %+v %q", m, skipped)
	}
}

func TestTapOutcomeOpenAtLimitIsCapped(t *testing.T) {
	if m, _ := webTapOutcome(webTapProbeResult{State: "open", Seconds: 41, SinceTap: 40}); !m.Capped {
		t.Errorf("明けないまま上限で切れた待ちは打ち切りのはず: %+v", m)
	}
}

func TestTapProbeCountsFromStartClockToWaitEnd(t *testing.T) {
	r := probeOnPage(t, probeRecords+`var fgeMissingWaitOpen = null;`)
	if math.Abs(r.Seconds-4.5) > 1e-9 || r.State != "closed" {
		t.Errorf("開始を押した 1000 ms から待ちの明けた 5500 ms まで 4.5 秒のはず: %+v", r)
	}
}

func TestTapProbeCountsOnlyStoppedWaitsAfterTap(t *testing.T) {
	r := probeOnPage(t, probeRecords+`var fgeMissingWaitOpen = null;`)
	if r.Stopped != 1 {
		t.Errorf("押す前のタイトルの待ちは数えず、押した後の途中の待ち 1 回のはず: %+v", r)
	}
}

func TestTapProbeListsPlaceholdersAfterTap(t *testing.T) {
	r := probeOnPage(t, probeRecords+`var fgeMissingWaitOpen = null;`)
	if len(r.Placeholders) != 1 || r.Placeholders[0] != "card" {
		t.Errorf("押した後に placeholder で進んだ絵だけのはず: %+v", r.Placeholders)
	}
}

func TestTapProbeOpenWaitCountsUntilNow(t *testing.T) {
	r := probeOnPage(t, probeRecords+`var fgeMissingWaitOpen = pressed;
fgeNetClock.at = performance.now() - 3000; pressed.startedAt = performance.now() - 1000; fgeTapMark.at = pressed.startedAt - 10;`)
	if r.State != "open" || r.Seconds < 2.9 {
		t.Errorf("開いたままの待ちは今まで数えるはず: %+v", r)
	}
}
