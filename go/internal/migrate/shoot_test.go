package migrate

import "testing"

func TestParseShootArgsTakesNameThenFlows(t *testing.T) {
	a, err := parseShootArgs([]string{"new", "--jobs", "2", "e2e/a.flow", "e2e/b.flow", "--run", "x"})
	if err != nil || a.name != "new" || len(a.flows) != 2 || a.jobs != 2 || a.run != "x" {
		t.Fatalf("got %+v %v", a, err)
	}
}

func TestParseShootArgsRefusesSameFlowName(t *testing.T) {
	if _, err := parseShootArgs([]string{"new", "--run", "x", "e2e/a.flow", "other/a.flow"}); err == nil {
		t.Fatal("同じ名前の flow を通した")
	}
}

func TestParseShootArgsRefusesPathAsName(t *testing.T) {
	if _, err := parseShootArgs([]string{"../x", "--run", "x", "e2e/a.flow"}); err == nil {
		t.Fatal("フォルダの区切りのある名前を通した")
	}
}

func TestParseShootArgsNeedsAFlow(t *testing.T) {
	if _, err := parseShootArgs([]string{"new", "--run", "x"}); err == nil {
		t.Fatal("flow の無い呼び出しを通した")
	}
}

func TestAutoJobsStaysInRange(t *testing.T) {
	if n := autoJobs(); n < 1 || n > shootMaxJobs {
		t.Fatalf("autoJobs = %d", n)
	}
}
