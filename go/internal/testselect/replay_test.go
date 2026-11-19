package testselect

import (
	"reflect"
	"testing"
)

const testOut = "[test] PASS .layers/engine_world\n[test] FAIL templates/rpg-starter\n[test] PASS bench/hd2d_town\n[test] PASS engine\n"

// make test の行をパッケージ id → 緑か にする（.layers・templates・bench の頭を外す）。
func TestParseTestLinesMapsDirsToPackages(t *testing.T) {
	want := map[string]bool{"engine_world": true, "rpg-starter": false, "hd2d_town": true, "engine": true}
	if got := ParseTestLines(testOut); !reflect.DeepEqual(got, want) {
		t.Errorf("got %v", got)
	}
}

// check-pkgs の赤の行のフォルダを読む。
func TestParseCheckPkgsRedReadsDirs(t *testing.T) {
	got := ParseCheckPkgsRed("===== bench/crowd2d =====\n[check-pkgs] 赤: bench/crowd2d bench/scene3d\n")
	if !reflect.DeepEqual(got, []string{"bench/crowd2d", "bench/scene3d"}) {
		t.Errorf("got %v", got)
	}
}

// 戻すのはテストでない .flix だけ（test・sample-test の下と .flix 以外は戻さない）。
func TestIsRevertSourceKeepsTests(t *testing.T) {
	got := []bool{
		IsRevertSource("engine_world/src/Timeline.flix"),
		IsRevertSource("engine_world/test/TestTimeline.flix"),
		IsRevertSource("templates/rpg-starter/sample-test/TestX.flix"),
		IsRevertSource("gates.json"),
	}
	if !reflect.DeepEqual(got, []bool{true, false, false, false}) {
		t.Errorf("got %v", got)
	}
}

func set(xs ...string) map[string]bool {
	m := map[string]bool{}
	for _, x := range xs {
		m[x] = true
	}
	return m
}

func judgeBase() JudgeInput {
	return JudgeInput{FullTestFail: set(), FullCheckFail: set(), SelectedTest: set(), SelectedCheck: set(), SelectedRed: set(), TypeRed: set(),
		AllTest: set("engine_world", "rpg-starter"), AllCheck: set("crowd2d")}
}

// 全量で赤のパッケージを選ばず、型検査も赤にならなければ拾い漏れ。
func TestJudgeCountsMissed(t *testing.T) {
	in := judgeBase()
	in.FullTestFail = set("rpg-starter")
	in.SelectedTest = set("engine_world")
	if v := Judge(in); !reflect.DeepEqual(v.Missed, []string{"rpg-starter"}) {
		t.Errorf("verdict %+v", v)
	}
}

// 選んで流して赤なら「選んで拾った」。
func TestJudgeCountsCaughtBySelect(t *testing.T) {
	in := judgeBase()
	in.FullTestFail = set("rpg-starter")
	in.SelectedTest = set("rpg-starter")
	in.SelectedRed = set("rpg-starter")
	if v := Judge(in); !reflect.DeepEqual(v.BySelect, []string{"rpg-starter"}) || len(v.Missed) != 0 {
		t.Errorf("verdict %+v", v)
	}
}

// 選ばなくても、選んだ型検査の門の赤が覆えば「型検査で拾った」。
func TestJudgeCountsCaughtByType(t *testing.T) {
	in := judgeBase()
	in.FullTestFail = set("rpg-starter")
	in.TypeRed = set("rpg-starter")
	if v := Judge(in); !reflect.DeepEqual(v.ByType, []string{"rpg-starter"}) || len(v.Missed) != 0 {
		t.Errorf("verdict %+v", v)
	}
}

// 選んで流したのに全量と答えが違えば食い違い（拾ったに数えない）。
func TestJudgeCountsMismatch(t *testing.T) {
	in := judgeBase()
	in.FullTestFail = set("rpg-starter")
	in.SelectedTest = set("rpg-starter")
	if v := Judge(in); !reflect.DeepEqual(v.Mismatch, []string{"rpg-starter"}) || len(v.BySelect) != 0 {
		t.Errorf("verdict %+v", v)
	}
}

// 全量で緑なのに選んだ物で赤も食い違い。
func TestJudgeCountsRedOnlyInSelected(t *testing.T) {
	in := judgeBase()
	in.SelectedTest = set("engine_world")
	in.SelectedRed = set("engine_world")
	if v := Judge(in); !reflect.DeepEqual(v.Mismatch, []string{"engine_world"}) {
		t.Errorf("verdict %+v", v)
	}
}

// check だけの物の赤を選ばなければ拾い漏れ。
func TestJudgeCountsMissedCheck(t *testing.T) {
	in := judgeBase()
	in.FullCheckFail = set("crowd2d")
	if v := Judge(in); !reflect.DeepEqual(v.Missed, []string{"crowd2d"}) {
		t.Errorf("verdict %+v", v)
	}
}

// 全量と同じ物を選んだら倒れた。
func TestJudgeFellBackWhenAllSelected(t *testing.T) {
	in := judgeBase()
	in.SelectedTest = set("engine_world", "rpg-starter")
	in.SelectedCheck = set("crowd2d")
	if v := Judge(in); !v.FellBack {
		t.Errorf("verdict %+v", v)
	}
}

// 1 つでも選ばなかった物があれば倒れていない。
func TestJudgeNotFellBackWhenNarrowed(t *testing.T) {
	in := judgeBase()
	in.SelectedTest = set("engine_world")
	in.SelectedCheck = set("crowd2d")
	if v := Judge(in); v.FellBack {
		t.Errorf("verdict %+v", v)
	}
}
