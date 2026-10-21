package refactor

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 本番で詰まった所（手の直しの途中で道具を流す）: 型検査が通らない時の索引・計画の後の外からの書き込み。

// typedFailing は typed の段で、型の誤りを出した後に AST を歩いて例外で止まる flixlint の代わり（resolved は testdata を写す）。
func typedFailing(calls *map[Stage]int) Runner {
	inner := fakeRunner(new(int))
	return func(s Stage, desc, dir string, cmd []string, log string) int {
		(*calls)[s]++
		if s == Resolved {
			return inner(s, desc, dir, cmd, log)
		}
		os.WriteFile(log, []byte("\x1b[31m-- Type Error [E7796] ---------------------------------- src/Shapes.flix\x1b[0m\n\n"+
			">> Unable to unify the types: '{count = Int32}' and '{}'.\n\n12 |     w#count\n          ^^^^^\n"+
			"flixlint: the fact walker failed: java.lang.ClassCastException: boom\n\tat flixlint.Spans$.typed(Spans.scala:250)\n"), 0o644)
		return 4
	}
}

func runWith(t *testing.T, root string, r Runner, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut, log strings.Builder
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")), Options{Run: r, Log: &log})
	return code, out.String() + errOut.String(), log.String()
}

func TestTypedIndexOnBrokenTypesSaysToolFirstInOneLine(t *testing.T) {
	calls := map[Stage]int{}
	code, text, log := runWith(t, project(t), typedFailing(&calls), "field-sites", "--label", "count")
	next := ""
	for _, l := range strings.Split(text, "\n") {
		if strings.HasPrefix(l, "next: ") {
			next = l
		}
	}
	if code != 2 || !strings.Contains(text, "src/Shapes.flix:12 Type Error: Unable to unify") || !strings.Contains(next, "先に道具、手の直しは後") {
		t.Errorf("exit %d\n%s", code, text)
	}
	if strings.Contains(text+log, "ClassCastException") {
		t.Errorf("例外の中身を出した\n%s\n%s", text, log)
	}
}

func TestTypedFailureIsNotRebuiltForTheSameSources(t *testing.T) {
	root := project(t)
	calls := map[Stage]int{}
	runWith(t, root, typedFailing(&calls), "field-sites", "--label", "count")
	code, text, _ := runWith(t, root, typedFailing(&calls), "field-sites", "--label", "count")
	if code != 2 || calls[Typed] != 1 || !strings.Contains(text, "先に道具、手の直しは後") {
		t.Errorf("exit %d・typed を作った回数 %d（1 のはず）\n%s", code, calls[Typed], text)
	}
}

func TestOpThatNeedsNoTypesFallsBackToResolved(t *testing.T) {
	calls := map[Stage]int{}
	code, text, _ := runWith(t, project(t), typedFailing(&calls), "refs", "Shapes.area", "--stage", "typed")
	if code != 0 || calls[Resolved] != 1 || !strings.Contains(text, "参照") {
		t.Errorf("exit %d・resolved %d\n%s", code, calls[Resolved], text)
	}
}

// 型から欄を先に手で消した後の remove-field は、索引を作らずに fix-construction へ回す。
func TestRemoveFieldAfterTheHandEditPointsToFixConstruction(t *testing.T) {
	root := project(t)
	p := filepath.Join(root, "src", "Shapes.flix")
	src := strings.Replace(read(t, root, "src/Shapes.flix"), "{ shape = Shape, count = Int32 }", "{ shape = Shape }", 1)
	must(t, os.WriteFile(p, []byte(src), 0o644))
	calls := map[Stage]int{}
	code, text, _ := runWith(t, root, typedFailing(&calls), "remove-field", "--label", "count", "--receiver", "World")
	if code != 2 || calls[Typed]+calls[Resolved] != 0 || !strings.Contains(text, "next: bin/fge refactor fix-construction --label count --receiver World") {
		t.Errorf("exit %d・索引を作った回数 %v\n%s", code, calls, text)
	}
}

// 計画を作った後・書く前に外から変わったファイルは書かず、その中身を残す。
func TestApplyRefusesAFileChangedAfterThePlan(t *testing.T) {
	root := t.TempDir()
	p := filepath.Join(root, "A.flix")
	must(t, os.WriteFile(p, []byte("abc\n"), 0o644))
	e := Edit{File: "A.flix", Start: 0, End: 1, Make: func(string) (string, error) {
		os.WriteFile(p, []byte("someone else\n"), 0o644)
		return "X", nil
	}}
	out := Change(root, []Edit{e}, Apply{On: true, Verify: "true", Run: func(string, string, string) int { return 0 }})
	if out.State != StateRefused || !strings.Contains(out.Reason, "外から変わった") || read(t, root, "A.flix") != "someone else\n" {
		t.Errorf("%+v", out)
	}
}

func TestFirstCompileErrorReadsBothHeadings(t *testing.T) {
	for _, head := range []string{"-- Type Error [E7796] ------- src/A.flix", "-- Resolution Error ------- src/A.flix"} {
		got := firstCompileError(head + "\n\n>> Undefined name 'x'.\n\n7 | x\n")
		if !strings.HasPrefix(got, "src/A.flix:7 ") || !strings.HasSuffix(got, ": Undefined name 'x'.") {
			t.Errorf("%q → %q", head, got)
		}
	}
}
