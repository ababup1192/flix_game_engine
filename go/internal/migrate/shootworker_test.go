package migrate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadyPortInReadsTheReadyLine(t *testing.T) {
	log := filepath.Join(t.TempDir(), "w.log")
	if err := os.WriteFile(log, []byte("jar を読む\n[headless] ready port=45123 pid=77\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if port, ok := readyPortIn(log); !ok || port != 45123 {
		t.Fatalf("port=%d ok=%v", port, ok)
	}
}

func TestCopyLogTailCopiesOnlyTheNewPart(t *testing.T) {
	dir := t.TempDir()
	src, dst := filepath.Join(dir, "w.log"), filepath.Join(dir, "job.log")
	if err := os.WriteFile(src, []byte("前の仕事\n今の仕事\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	copyLogTail(src, int64(len("前の仕事\n")), dst)
	if b, _ := os.ReadFile(dst); string(b) != "今の仕事\n" {
		t.Fatalf("got %q", b)
	}
}

func TestPoolFallsBackWhenTheWorkerCannotStart(t *testing.T) {
	dir := t.TempDir()
	p := newShootPool("exit 3 #", nil, dir, 1, true, []string{"FlowVideo.play"})
	job := &shootJob{Kind: "flow", Name: "a", Log: filepath.Join(dir, "a.log"), entry: "FlowVideo.play"}
	p.exec(0, job)
	if job.Code != 3 || !p.broken[0] {
		t.Fatalf("起こせない枠で 1 本の JVM へ回らない: code=%d broken=%v", job.Code, p.broken[0])
	}
}

func TestPoolWithoutResidentRunsEachJobAlone(t *testing.T) {
	dir := t.TempDir()
	p := newShootPool("echo ran", nil, dir, 1, false, nil)
	job := &shootJob{Kind: "flow", Name: "a", Log: filepath.Join(dir, "a.log"), entry: "FlowVideo.play"}
	p.exec(0, job)
	if b, _ := os.ReadFile(job.Log); job.Code != 0 || !strings.Contains(string(b), "ran FlowVideo.play") {
		t.Fatalf("code=%d log=%q", job.Code, b)
	}
}

func TestPaintStageDropsTheKeysOnlyPaintSettings(t *testing.T) {
	w := newPlanWorld(t)
	keyedRec(keyA, keyB).writeFlow(t, w.base, "route", "design")
	keysOnly(t, keyedRec(keyC, keyB), w.cur, "route")
	base, _ := LoadSide(w.base)
	first := &shootJob{Kind: "flow", Name: "route", entry: "FlowVideo.play", env: append([]string{"FLOW=e2e/route.flow"}, paintEnv(nil)...)}
	_, jobs, err := paintStage(w.cur, base, map[string]*shootJob{"route": first}, t.TempDir())
	if err != nil || len(jobs) != 1 {
		t.Fatalf("jobs=%d err=%v", len(jobs), err)
	}
	got := strings.Join(jobs[0].env, " ")
	if got != "FLOW=e2e/route.flow "+PaintWorldEnv+"=frames:1-1 "+PaintAllEnv+"=none" {
		t.Fatalf("env=%s", got)
	}
}
