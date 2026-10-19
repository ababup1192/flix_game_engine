package resident

import (
	"strings"
	"testing"
	"time"
)

const helloBody = "ok hello\npid=123\ndir=/g\nmanifest=abc\nserved=7\nbusy=\nidle.left=170\nidle.window=180\n" +
	"env.LANG=ja_JP.UTF-8\nenv.HEADLESS_PORT=0\njob=SceneRender.one still\njob=FlowVideo.play video\n"

func mustHello(t *testing.T) Hello {
	t.Helper()
	h, err := ParseHello(helloBody)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func TestParseHelloReadsManifest(t *testing.T) {
	if got := mustHello(t).Manifest; got != "abc" {
		t.Fatalf("manifest = %q", got)
	}
}

func TestParseHelloReadsEnv(t *testing.T) {
	if got := mustHello(t).Env["LANG"]; got != "ja_JP.UTF-8" {
		t.Fatalf("env.LANG = %q", got)
	}
}

func TestParseHelloReadsJobKinds(t *testing.T) {
	j, _ := mustHello(t).FindJob("FlowVideo.play")
	if j.Kind != JobKindVideo {
		t.Fatalf("kind = %q", j.Kind)
	}
}

func TestParseHelloReadsIdleLeft(t *testing.T) {
	if got := mustHello(t).IdleLeft; got != 170 {
		t.Fatalf("idle.left = %d", got)
	}
}

func TestParseHelloReadsIdleWindow(t *testing.T) {
	if got := mustHello(t).IdleWindow; got != 180 {
		t.Fatalf("idle.window = %d", got)
	}
}

func TestParseHelloWithoutIdleIsMinusOne(t *testing.T) {
	h, _ := ParseHello("ok hello\npid=1\n")
	if h.IdleLeft != -1 {
		t.Fatalf("idle.left = %d", h.IdleLeft)
	}
}

func TestParseHelloRejectsOtherFirstLine(t *testing.T) {
	if _, err := ParseHello("ok quit\n"); err == nil {
		t.Fatal("誤りにならない")
	}
}

func TestEnvMismatchSameIsEmpty(t *testing.T) {
	if k := EnvMismatch(map[string]string{"LANG": "C"}, map[string]string{"LANG": "C", "PATH": "/x"}); k != "" {
		t.Fatalf("食い違い = %q", k)
	}
}

func TestEnvMismatchFindsChangedValue(t *testing.T) {
	if k := EnvMismatch(map[string]string{"LANG": "C"}, map[string]string{"LANG": "ja"}); k != "LANG" {
		t.Fatalf("食い違い = %q", k)
	}
}

func TestEnvMismatchFindsKeyOnlyInMine(t *testing.T) {
	if k := EnvMismatch(map[string]string{}, map[string]string{"HEADLESS_X": "1"}); k != "HEADLESS_X" {
		t.Fatalf("食い違い = %q", k)
	}
}

func TestEnvMismatchIgnoresClientSetKeys(t *testing.T) {
	if k := EnvMismatch(map[string]string{"HEADLESS_PORT": "0"}, map[string]string{"HEADLESS_RESIDENT": "1"}); k != "" {
		t.Fatalf("食い違い = %q", k)
	}
}

func baseWant() Want {
	return Want{Dir: "/g", Manifest: "abc", Env: map[string]string{"LANG": "ja_JP.UTF-8"}, Entry: "SceneRender.one"}
}

func TestJudgeUsesMatchingResident(t *testing.T) {
	if v, why := Judge(mustHello(t), baseWant()); v != Use {
		t.Fatalf("verdict = %v (%s)", v, why)
	}
}

func TestJudgeQuitsOnManifestMismatch(t *testing.T) {
	w := baseWant()
	w.Manifest = "zzz"
	if v, _ := Judge(mustHello(t), w); v != QuitAndRefuse {
		t.Fatalf("verdict = %v", v)
	}
}

func TestJudgeQuitsOnEnvMismatch(t *testing.T) {
	w := baseWant()
	w.Env = map[string]string{"LANG": "C"}
	if v, _ := Judge(mustHello(t), w); v != QuitAndRefuse {
		t.Fatalf("verdict = %v", v)
	}
}

func TestJudgeKeepsOtherRootsResident(t *testing.T) {
	w := baseWant()
	w.Dir, w.Manifest = "/other", "zzz"
	if v, _ := Judge(mustHello(t), w); v != Refuse {
		t.Fatalf("verdict = %v", v)
	}
}

func TestJudgeRefusesBusy(t *testing.T) {
	h := mustHello(t)
	h.Busy = "SceneRender.all"
	if v, _ := Judge(h, baseWant()); v != Refuse {
		t.Fatalf("verdict = %v", v)
	}
}

func TestJudgeRefusesUnknownJob(t *testing.T) {
	w := baseWant()
	w.Entry = "Nope.x"
	if v, _ := Judge(mustHello(t), w); v != Refuse {
		t.Fatalf("verdict = %v", v)
	}
}

func TestJudgeRefusesVideoUnlessGPUOff(t *testing.T) {
	w := baseWant()
	w.Entry = "FlowVideo.play"
	if v, _ := Judge(mustHello(t), w); v != Refuse {
		t.Fatalf("verdict = %v", v)
	}
}

func TestJudgeUsesVideoWhenGPUOff(t *testing.T) {
	w := baseWant()
	w.Entry = "FlowVideo.play"
	w.Env = map[string]string{"LANG": "ja_JP.UTF-8", "FGE_GPU": "off"}
	if v, _ := Judge(mustHello(t), w); v != Use {
		t.Fatalf("verdict = %v", v)
	}
}

func TestJudgeRefusesWithoutManifestFile(t *testing.T) {
	w := baseWant()
	w.Manifest = ""
	if v, _ := Judge(mustHello(t), w); v != Refuse {
		t.Fatalf("verdict = %v", v)
	}
}

func TestParseLineOut(t *testing.T) {
	if k, s := ParseLine("o x 0"); k != LineOut || s != "x 0" {
		t.Fatalf("%v %q", k, s)
	}
}

func TestParseLineEmptyErr(t *testing.T) {
	if k, s := ParseLine("e"); k != LineErr || s != "" {
		t.Fatalf("%v %q", k, s)
	}
}

func TestParseLineRejectsMissingSpace(t *testing.T) {
	if k, _ := ParseLine("ox"); k != LineBad {
		t.Fatalf("%v", k)
	}
}

func TestParseEndCode(t *testing.T) {
	if e, n := ParseEnd("3"); e != EndExit || n != 3 {
		t.Fatalf("%v %d", e, n)
	}
}

func TestParseEndNeedsGL(t *testing.T) {
	if e, _ := ParseEnd("needs-gl"); e != EndNeedsGL {
		t.Fatalf("%v", e)
	}
}

func TestParseEndGarbageIsBroken(t *testing.T) {
	if e, _ := ParseEnd("??"); e != EndBroken {
		t.Fatalf("%v", e)
	}
}

func TestSettlePassesEntryCode(t *testing.T) {
	if code, _, _ := Settle(Outcome{End: EndExit, Code: 4}); code != 4 {
		t.Fatalf("code = %d", code)
	}
}

func TestSettleBrokenBeforeOutputIsSilent125(t *testing.T) {
	if code, notice, _ := Settle(Outcome{End: EndBroken}); code != Unusable || notice != "" {
		t.Fatalf("%d %q", code, notice)
	}
}

func TestSettleBrokenAfterOutputPrintsSeparator(t *testing.T) {
	if _, notice, _ := Settle(Outcome{End: EndBroken, Emitted: true}); !strings.Contains(notice, "素の道で流し直す") {
		t.Fatalf("区切り = %q", notice)
	}
}

func TestSettleOOMPrintsSeparator(t *testing.T) {
	if _, notice, _ := Settle(Outcome{End: EndOOM}); !strings.HasPrefix(notice, "[resident] メモリが足りず") {
		t.Fatalf("区切り = %q", notice)
	}
}

func TestSettleSilentKillsResident(t *testing.T) {
	if _, _, after := Settle(Outcome{End: EndSilent}); after != KillResident {
		t.Fatalf("after = %v", after)
	}
}

func TestSettleStaleQuitsResident(t *testing.T) {
	if _, _, after := Settle(Outcome{End: EndStale}); after != QuitResident {
		t.Fatalf("after = %v", after)
	}
}

func TestRunBodyDropsMultilineValues(t *testing.T) {
	if got := RunBody(map[string]string{"B": "2", "A": "1", "M": "x\ny"}); got != "A=1\nB=2\n" {
		t.Fatalf("本文 = %q", got)
	}
}

func TestSpawnEnvDropsUnlistedKeys(t *testing.T) {
	env := strings.Join(SpawnEnv(map[string]string{"FOO": "1", "HOME": "/h"}, "E2e.serveHeadless", ""), "\n")
	if strings.Contains(env, "FOO=") {
		t.Fatalf("env = %q", env)
	}
}

func TestSpawnEnvOverridesPort(t *testing.T) {
	env := SpawnEnv(map[string]string{"HEADLESS_PORT": "9999"}, "E2e.serveHeadless", "")
	if strings.Contains(strings.Join(env, "\n"), "HEADLESS_PORT=9999") {
		t.Fatalf("env = %q", env)
	}
}

func TestSpawnEnvNamesResidentEntry(t *testing.T) {
	env := strings.Join(SpawnEnv(nil, "E2e.serveHeadless", "A.b C.d"), "\n")
	if !strings.Contains(env, "FGE_ENTRY=E2e.serveHeadless") {
		t.Fatalf("env = %q", env)
	}
}

func TestJavaArgsAddsHeapCap(t *testing.T) {
	if got := strings.Join(JavaArgs("-Xss64m", 3000), " "); !strings.Contains(got, "-Xmx3000m -Xss64m") {
		t.Fatalf("args = %q", got)
	}
}

func TestJavaArgsKeepsCallersXmx(t *testing.T) {
	if got := strings.Join(JavaArgs("-Xmx1g", 3000), " "); strings.Contains(got, "-Xmx3000m") {
		t.Fatalf("args = %q", got)
	}
}

func TestJavaArgsEndsWithJar(t *testing.T) {
	args := JavaArgs("", 1)
	if args[len(args)-1] != "build/headless/headless.jar" {
		t.Fatalf("args = %q", args)
	}
}

func TestParseReadyReadsPort(t *testing.T) {
	if port, _, ok := ParseReady("[headless] ready port=45678 pid=12"); !ok || port != 45678 {
		t.Fatalf("%d %v", port, ok)
	}
}

func TestParseReadyIgnoresOtherLines(t *testing.T) {
	if _, _, ok := ParseReady("[headless] starting"); ok {
		t.Fatal("ready と読んだ")
	}
}

func testHeap() Heap {
	share, min, max, fb, env := 0.4, 2048, 6144, 3072, "X"
	return Heap{MemoryShare: &share, MinMB: &min, MaxMB: &max, FallbackMB: &fb, EnvVar: &env}
}

func TestHeapDividesByAtLeastTwo(t *testing.T) {
	if got := computeHeapMB(testHeap(), 1, 20480, true, ""); got != 4096 {
		t.Fatalf("heap = %d", got)
	}
}

func TestHeapClampsToMax(t *testing.T) {
	if got := computeHeapMB(testHeap(), 2, 1<<20, true, ""); got != 6144 {
		t.Fatalf("heap = %d", got)
	}
}

func TestHeapUnknownMemoryUsesFallback(t *testing.T) {
	if got := computeHeapMB(testHeap(), 2, 0, false, ""); got != 3072 {
		t.Fatalf("heap = %d", got)
	}
}

func TestHeapOverride(t *testing.T) {
	if got := computeHeapMB(testHeap(), 2, 20480, true, "777"); got != 777 {
		t.Fatalf("heap = %d", got)
	}
}

func TestRelayStopsOnSilence(t *testing.T) {
	lines := make(chan string)
	got := relay(lines, make(chan struct{}), 50*time.Millisecond, &strings.Builder{}, &strings.Builder{}, Outcome{})
	if got.End != EndSilent {
		t.Fatalf("end = %v", got.End)
	}
}

func TestAftercareOfQuitsAfterVideo(t *testing.T) {
	if got := AftercareOf(Job{Name: "FlowVideo.play", Kind: JobKindVideo}, KeepResident); got != QuitResident {
		t.Fatalf("got %v", got)
	}
}

func TestAftercareOfKeepsAfterStill(t *testing.T) {
	if got := AftercareOf(Job{Name: "SceneRender.one", Kind: "still"}, KeepResident); got != KeepResident {
		t.Fatalf("got %v", got)
	}
}

func TestAftercareOfKeepsKillAfterVideo(t *testing.T) {
	if got := AftercareOf(Job{Name: "FlowVideo.play", Kind: JobKindVideo}, KillResident); got != KillResident {
		t.Fatalf("got %v", got)
	}
}
