package docrefs

import (
	"os/exec"
	"strings"
	"testing"
)

func claimsOf(text string) []string {
	var got []string
	for _, c := range ScanCallerClaims(text, map[string]bool{"flix": true}, []string{"（予定）"}) {
		got = append(got, c.Text())
	}
	return got
}

// コメント（/// と //）の、名前（Mod.name・素の名前・` ` の中）の直後（閉じ括弧の後も）の動詞を拾う。区切りで並ぶ名前は 1 つに。
// 動詞の直前が名前でない物・消し線・予定の印・引用（` ` の中の '…'）・コードの字（"…"）は拾わない。
func TestScanCallerClaimsCountsNamesBeforeCallerVerbs(t *testing.T) {
	text := strings.Join([]string{
		"/// `World.step` が呼ぶ。",
		"    /// 盤の光（`View.paint`）が読む。",
		"    /// `Aa.first`・`Bb.second` から呼ぶ。",
		"    // inputOf が組む。View が読む入力。",
		"    /// `World.step(w)` で受け取る。Pointer.at が受け取る。",
		"    /// Float32 で受け取る。ゲームが読む Doc。EndScreen の入りと音が読む。WorldFight と ReplayTrack だけが使う。",
		"    /// ~~`Old.gone` が呼ぶ~~ 消した。",
		"    /// `Next.later`（予定）が呼ぶ。`'Q.x'` が呼ぶ。",
		`    let s = "View が読む"; // 字の中は数えない`,
		"    def tick(): Int32 = 1",
	}, "\n")
	want := []string{
		"World.step が呼ぶ",
		"View.paint が読む",
		"Aa.first・Bb.second から呼ぶ",
		"inputOf が組む",
		"View が読む",
		"World.step で受け取る",
		"Pointer.at が受け取る",
		"WorldFight・ReplayTrack が使う",
	}
	if got := claimsOf(text); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("got\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

const callsFlix = "mod Calls {\n" +
	"    /// `World.step` が呼ぶ。\n" +
	"    /// 盤の View が読む入力。\n" +
	"    pub def tick(): Int32 = 1\n" +
	"}\n"

func callerHitsOf(got []string) []string {
	var out []string
	for _, g := range got {
		if strings.HasSuffix(g, " "+CodeCaller) {
			out = append(out, g)
		}
	}
	return out
}

// 全部を見る時は上限のファイル（lint/limits/doc-refs-callers.json）と比べる: 超えれば並べて止め、同じなら並べず、
// 減っていれば上限を下げるよう言って止める。hint は呼び手を書かず道具で引くこと。
func TestCallerClaimsAreRatchetedByTheLimitFile(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "src/Calls.flix", callsFlix)
	want := []string{
		"src/Calls.flix:2 World.step が呼ぶ doc-refs.caller",
		"src/Calls.flix:3 View が読む doc-refs.caller",
	}
	if got := callerHitsOf(hitsOf(t, root)); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("got\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	write(t, root, "lint/limits/doc-refs-callers.json", "{\"limit\": 2}\n")
	if got := callerHitsOf(hitsOf(t, root)); len(got) != 0 {
		t.Errorf("上限と同じなら並べない: %v", got)
	}
	write(t, root, "lint/limits/doc-refs-callers.json", "{\"limit\": 3}\n")
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, nil)
	if err != nil || code != 1 || !strings.Contains(errOut.String(), "lint/limits/doc-refs-callers.json の limit を 2 に下げる") {
		t.Errorf("減った時に下げるよう言っていない: code %d err %v\n%s", code, err, errOut.String())
	}
	write(t, root, "lint/limits/doc-refs-callers.json", "{\"limit\": 1}\n")
	out.Reset()
	errOut.Reset()
	if _, err := Run(&out, &errOut, root, nil); err != nil || !strings.Contains(errOut.String(), "bin/fge refactor usages --callers <def>") {
		t.Errorf("hint が無い: %v\n%s", err, errOut.String())
	}
}

// 名指しの .flix（コミットの時の触ったファイル）は、HEAD の中身より増えた物だけで止める。
func TestNamedFlixStopsOnlyOnCallerClaimsAddedSinceHead(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "src/Calls.flix", callsFlix)
	for _, args := range [][]string{{"init", "-q"}, {"add", "."}, {"-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-q", "-m", "fixture"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Skipf("git が使えない: %v %s", err, out)
		}
	}
	if got := callerHitsOf(hitsOf(t, root, "src/Calls.flix")); len(got) != 0 {
		t.Errorf("HEAD からある物だけなら止めない: %v", got)
	}
	write(t, root, "src/Calls.flix", strings.Replace(callsFlix, "    pub def", "    /// `Fight.tick` から呼ぶ。\n    pub def", 1))
	if got := callerHitsOf(hitsOf(t, root, "src/Calls.flix")); strings.Join(got, "\n") != "src/Calls.flix:4 Fight.tick から呼ぶ doc-refs.caller" {
		t.Errorf("増えた 1 件だけ: %v", got)
	}
}

// 生成物の .flix（頭に「手で直さない」）は数えない。
func TestGeneratedFlixCallerClaimsAreNotCounted(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "src/Gen.flix", "// 手で直さない（gen.go が作る）\n"+callsFlix)
	if got := callerHitsOf(hitsOf(t, root)); len(got) != 0 {
		t.Errorf("生成物を数えた: %v", got)
	}
}
