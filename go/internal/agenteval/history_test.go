package agenteval

import (
	"strings"
	"testing"
)

func runs(id string, points ...int) []Result {
	var rs []Result
	for i, p := range points {
		// Want 3 の点に合わせて Hit を逆算する（100 / 67 / 33 / 0）。
		rs = append(rs, Result{ID: id, Run: i + 1, Want: 3, Hit: p * 3 / 100, InputTokens: 1000})
	}
	return rs
}

// 3 回のうち 1 回 1 語を外す程度のぶれ（平均で 11 点）は鳴らさず、1 回丸ごと外したら鳴らす。
func TestRegressionsUsesMeanDrop(t *testing.T) {
	prev := BuildHistory("0.1.0", 3, 0, runs("a", 100, 100, 100))
	if got := Regressions(prev, BuildHistory("0.1.1", 3, 0, runs("a", 100, 100, 67))); len(got) != 0 {
		t.Errorf("1 語のぶれで鳴った: %v", got)
	}
	if got := Regressions(prev, BuildHistory("0.1.1", 3, 0, runs("a", 100, 100, 0))); len(got) != 1 {
		t.Errorf("1 回丸ごと外したのに鳴らない")
	}
}

// 前の版に無いお題は比べない（足したばかりのお題で鳴らさない）。
func TestRegressionsSkipsNewTask(t *testing.T) {
	prev := BuildHistory("0.1.0", 1, 0, runs("a", 100))
	if got := Regressions(prev, BuildHistory("0.1.1", 1, 0, runs("b", 0))); len(got) != 0 {
		t.Errorf("新しいお題で鳴った: %v", got)
	}
}

// 前の版は数の並びで探す（文字の並びだと 0.35.9 が 0.35.21 より新しく見える）。
func TestPreviousHistoryOrdersVersionsNumerically(t *testing.T) {
	dir := t.TempDir()
	for _, v := range []string{"0.35.9", "0.35.21", "0.35.10"} {
		if _, err := WriteHistory(dir, BuildHistory(v, 1, 0, runs("a", 100))); err != nil {
			t.Fatal(err)
		}
	}
	if p := PreviousHistory(dir, "0.35.21"); p == nil || p.Engine != "0.35.10" {
		t.Errorf("want 0.35.10, got %+v", p)
	}
}

// status の 1 行は最新の版を出し、1 つ前より下がったお題の名前を添える。
func TestStatusLineNamesRegressedTask(t *testing.T) {
	dir := t.TempDir()
	WriteHistory(dir, BuildHistory("0.1.0", 2, 0, runs("hud", 100, 100)))
	WriteHistory(dir, BuildHistory("0.1.1", 2, 0, runs("hud", 0, 100)))
	line := StatusLine(dir)
	if !strings.Contains(line, "v0.1.1") || !strings.Contains(line, "下がった: hud") {
		t.Errorf("got %q", line)
	}
}

// 失敗した回（打ち切りなど）は平均に入れない。0 点が混ざって「下がった」に化けないように。
func TestFailedRunIsLeftOutOfMeans(t *testing.T) {
	rs := runs("a", 100, 100)
	rs = append(rs, Result{ID: "a", Run: 3, Want: 3, Err: "timeout"})
	h := BuildHistory("0.1.1", 3, 0, rs)
	if h.MeanPoints() != 100 || h.Tasks[0].Failed != 1 || h.Totals.Failed != 1 {
		t.Errorf("mean %.0f failed %d", h.MeanPoints(), h.Tasks[0].Failed)
	}
}

// 何回か流した記録は、--repeat を付け忘れて付け直しても回数を記録から読む。
func TestDetectRepeatCountsRunLogs(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"a.1.jsonl", "a.2.jsonl", "a.3.jsonl"} {
		if err := writeFile(dir+"/"+n, ""); err != nil {
			t.Fatal(err)
		}
	}
	if got := detectRepeat(dir, "a"); got != 3 {
		t.Errorf("got %d", got)
	}
}

// 同じ版の記録が既にあれば、claude を呼ぶ前に止まる（開発中のエンジンで前の版を上書きしない）。
func TestExistingHistoryStopsBeforeRunning(t *testing.T) {
	dir := t.TempDir()
	tasks := dir + "/t.json"
	if err := writeFile(tasks, `{"version":1,"tasks":[{"id":"a","prompt":"p","expect":[{"re":"x"}]}]}`); err != nil {
		t.Fatal(err)
	}
	if _, err := WriteHistory(dir+"/h", BuildHistory("0.1.0", 1, 0, runs("a", 100))); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, []string{"--tasks", tasks, "--out", dir + "/o", "--claude", "/nonexistent",
		"--history", dir + "/h", "--version", "0.1.0"})
	if code != 2 || err == nil || !strings.Contains(err.Error(), "--overwrite") {
		t.Errorf("code %d err %v", code, err)
	}
}
