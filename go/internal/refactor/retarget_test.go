package refactor

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/retarget は段 2a（設計 semantic-index-design §2.6.1・2.6.2）のお手本: 葉の本体の w#tutorialDoc を res#tutorialDoc へ
// 読み替える形（ゲームの c7a02a01 の tutorial）。testdata/propagate-view は --propagate の型の比べ（短い名前が同じ別の型・
// 別名・中間の def が 2 段）。索引はどちらも testdata/regen.json のとおり flixlint で作った物（param・aparam・alias の fields）。

func runFixture(t *testing.T, name, root string, args ...string) (int, string, []string) {
	t.Helper()
	var out, errOut strings.Builder
	var cmds []string
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")),
		Options{Run: spansRunner(name), Verify: verifyWith(0, "", &cmds), Log: io.Discard})
	return code, out.String() + errOut.String(), cmds
}

// K1: 当てるのは受け手が引数 w そのもの（rparam）の読みだけ。別の World（prev）・式（nextOf(w)）の読みは書かずに並べる。
func TestRetargetFieldRewritesOnlyReadsOfTheNamedParameter(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	code, out, cmds := runFixture(t, "retarget", root, "retarget-field", "--label", "tutorialDoc", "--from", "w", "--to", "res",
		"--def", "Tutorial.changed", "--apply", "--all")
	if code != 0 || len(cmds) != 1 {
		t.Fatalf("終了コード %d・確かめ %d 回:\n%s", code, len(cmds), out)
	}
	mustContain(t, read(t, root, "src/Tutorial.flix"),
		"res#tutorialDoc#pen != prev#tutorialDoc#pen and nextOf(w)#tutorialDoc#pen > res#theme")
	mustContain(t, out, "書かない（受け手が引数 w そのものでない）")
}

// 書き込み（{ tutorialDoc = … | w }）は人へ。同じ def の読みは替える。
func TestRetargetFieldLeavesWritesToTheHuman(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	code, out, _ := runFixture(t, "retarget", root, "retarget-field", "--label", "tutorialDoc", "--from", "w", "--to", "res",
		"--def", "Tutorial.withPen", "--apply", "--all")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Tutorial.flix"), "{ tutorialDoc = res#tutorialDoc | w }")
	mustContain(t, out, "書かない（書き込み。読み替えるかは人）")
}

// K2: 読み替えると w を読む所が 0 になる def は、既定では書かずに断る（Flix は使わない引数を誤りにする）。
func TestRetargetFieldRefusesWhenTheParameterWouldBecomeUnused(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	before := read(t, root, "src/Tutorial.flix")
	code, out, cmds := runFixture(t, "retarget", root, "retarget-field", "--label", "tutorialDoc", "--from", "w", "--to", "res",
		"--def", "Tutorial.penOnly", "--apply", "--all")
	if code != 2 || len(cmds) != 0 || read(t, root, "src/Tutorial.flix") != before {
		t.Fatalf("書かずに断るはず（終了コード %d・確かめ %d 回）:\n%s", code, len(cmds), out)
	}
	mustContain(t, out, "引数 w を読む所が全部消える", "--drop-from")
}

// --drop-from: 読み替えと w を外す並び（呼ぶ所の w も捨てる）を 1 つの計画にし、確かめは 1 回。
func TestRetargetFieldDropFromRemovesTheParameterInOnePlan(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	code, out, cmds := runFixture(t, "retarget", root, "retarget-field", "--label", "tutorialDoc", "--from", "w", "--to", "res",
		"--def", "Tutorial.penOnly", "--drop-from", "--apply")
	if code != 0 || len(cmds) != 1 {
		t.Fatalf("終了コード %d・確かめ %d 回:\n%s", code, len(cmds), out)
	}
	mustContain(t, read(t, root, "src/Tutorial.flix"), "pub def penOnly(res: Res): Int32 = res#tutorialDoc#pen + res#theme")
	mustContain(t, read(t, root, "src/Shots.flix"), "Tutorial.penOnly(res) + w#step")
}

// b: --propagate --retarget は葉の読み替えを change-signature の計画の内側に入れる（仮の関数も dry-run の git apply も無し）。
// 葉から w を外し（--params に w を書かない）、呼び手 top に res を足し、res を持つ view で止まる。確かめは 1 回。
func TestPropagateRetargetComposesTheLeafBodyInOnePlan(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	code, out, cmds := runFixture(t, "retarget", root, "change-signature", "--def", "Tutorial.penOf",
		"--params", "res: Res", "--args", "@res", "--propagate", "--retarget", "tutorialDoc", "--from", "w", "--apply")
	if code != 0 || len(cmds) != 1 {
		t.Fatalf("終了コード %d・確かめ %d 回:\n%s", code, len(cmds), out)
	}
	mustContain(t, read(t, root, "src/Tutorial.flix"), "pub def penOf(res: Res): Int32 = res#tutorialDoc#pen")
	mustContain(t, read(t, root, "src/Shots.flix"),
		"Tutorial.penOf(res) + w#step",
		"top(res, w) + res#theme")
}

// R2: 葉から w を外すと、w を葉へ渡すだけだった呼び手（shownAge）の w が空く。書かずに、その呼び手と引数を fix に出す。
func TestPropagateRetargetListsTheCallerWhoseParameterBecomesUnused(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	before := read(t, root, "src/Shots.flix")
	code, out, cmds := runFixture(t, "retarget", root, "change-signature", "--def", "Tutorial.penSeconds",
		"--params", "res: Res", "--args", "@res", "--propagate", "--retarget", "tutorialDoc", "--from", "w", "--apply", "--all")
	if code != 2 || len(cmds) != 0 || read(t, root, "src/Shots.flix") != before {
		t.Fatalf("書かずに断るはず（終了コード %d・確かめ %d 回）:\n%s", code, len(cmds), out)
	}
	mustContain(t, out, "引数 w を読む所が全部消える", "Shots.shownAge")
}

// 葉の本体に局所の res がある: 読み替えた res#… が局所を読むので、読み替えずに人へ。
func TestPropagateRetargetStopsWhenTheBodyBindsTheTargetName(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	code, out, _ := runFixture(t, "retarget", root, "change-signature", "--def", "Tutorial.localRes",
		"--params", "res: Res", "--args", "@res", "--propagate", "--retarget", "tutorialDoc", "--from", "w", "--all")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, out, "本体に名前 res がある")
}

// K3-2: 足す引数を使うかは計画が書く数で見る。元から局所の res を持つ葉は、字では「使う」に見えても使わない。
func TestPropagateCountsTheNewParameterFromThePlanForALocalOfTheSameName(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	code, out, _ := runFixture(t, "retarget", root, "change-signature", "--def", "Tutorial.localRes",
		"--params", "res: Res, w", "--args", "@res, w", "--propagate", "--all")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, out, "葉の本体が res を使わない")
}

// K3-2（R1）: 中間の def（mid・mid2）は呼ぶ所の Edit が書く res だけで新しい引数を使う。それを数えて、断らずに書く。
func TestPropagateCountsTheNewParameterFromThePlanForIntermediateDefs(t *testing.T) {
	root := fixtureRoot(t, "propagate-view")
	code, out, cmds := runFixture(t, "propagate-view", root, "change-signature", "--def", "View.leaf",
		"--params", "res: Res, w", "--args", "@res=Res.defaults(), w", "--propagate", "--apply")
	if code != 0 || len(cmds) != 1 {
		t.Fatalf("終了コード %d・確かめ %d 回:\n%s", code, len(cmds), out)
	}
	mustContain(t, read(t, root, "src/View.flix"),
		"pub def mid(res: Res, w: Int32): Int32 = endTree(res, { res = { atlas = 1 }, n = 2 }, w) + 1",
		"pub def mid2(res: Res, w: Int32): Int32 = mid(res, w) * 2")
}

// f: env#res は ViewEnv.Res で、葉の res（Res.Res）と短い名前が同じだけ。書かずに endTree へも res を足す。
// 別名（Model = Res）の引数 m は同じ型なので、top は m を書いて止まる。--params の Res は葉のファイルの use で引く（M2）。
func TestPropagateProvidesOnlyAFieldOfTheSameResolvedType(t *testing.T) {
	root := fixtureRoot(t, "propagate-view")
	code, out, _ := runFixture(t, "propagate-view", root, "change-signature", "--def", "View.leaf",
		"--params", "res: Res, w", "--args", "@res=Res.defaults(), w", "--propagate", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	view := read(t, root, "src/View.flix")
	mustContain(t, view,
		"pub def endTree(res: Res, env: ViewEnv.Env, w: Int32): Int32 = leaf(res, w) + env#n",
		"mid2(m, w) + m#scale")
	if strings.Contains(view, "(env#res") || strings.Contains(view, ", env#res") {
		t.Errorf("ViewEnv.Res の欄を書いた:\n%s", view)
	}
}

func TestNeedsReturnsBothStagesForRetarget(t *testing.T) {
	a, err := parseArgs([]string{"change-signature", "--def", "A.f", "--params", "res: Res", "--args", "@res", "--propagate", "--retarget", "x", "--from", "w"})
	must(t, err)
	if got := a.stages(); len(got) != 2 || got[0] != Resolved || got[1] != Typed {
		t.Fatalf("段 %v（resolved と typed のはず）", got)
	}
	b, err := parseArgs([]string{"change-signature", "--def", "A.f", "--params", "res: Res", "--args", "@res", "--propagate"})
	must(t, err)
	if got := b.stages(); len(got) != 1 || got[0] != Resolved {
		t.Fatalf("段 %v（resolved だけのはず）", got)
	}
}

// 2 本の索引は同じソースから作る: 2 本目を作る間にソースが変わったら止める（行の位置を 2 本の間で引けない）。
func TestTwoIndexesMustShareTheSourceKey(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	cfg, err := LoadConfig(root)
	must(t, err)
	inner := spansRunner("retarget")
	run := func(stage Stage, desc, dir string, cmd []string, log string) int {
		if stage == Typed {
			must(t, os.WriteFile(filepath.Join(root, "src", "Doc.flix"), []byte("mod Doc {\n    pub type alias TutorialDoc = { pen = Int32 }\n}\n"), 0o644))
		}
		return inner(stage, desc, dir, cmd, log)
	}
	b := Builder{Root: root, Config: cfg, Flixlint: filepath.Join(root, "flixlint"), Run: run, Log: io.Discard}
	if _, err := b.LoadAll([]Stage{Resolved, Typed}); err == nil || !strings.Contains(err.Error(), "ソースが変わった") {
		t.Fatalf("止まるはず: %v", err)
	}
}

// M3: 操作が要る adds=（param など）を書く flixlint より古いと、索引を作る前に止まる（JVM を立てない）。
func TestOldFlixlintStopsBeforeTheIndexForAnOpThatNeedsParam(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	var out, errOut strings.Builder
	ran := false
	code := Run(&out, &errOut, root, []string{"retarget-field", "--label", "tutorialDoc", "--from", "w", "--to", "res", "--flixlint", filepath.Join(root, "flixlint")},
		Options{Run: func(Stage, string, string, []string, string) int { ran = true; return 0 }, Log: io.Discard,
			Version: func(string) string { return "flixlint " + MinFlixlint }})
	if code != 2 || ran {
		t.Fatalf("止まるはず（終了コード %d・索引を作った %v）:\n%s%s", code, ran, out.String(), errOut.String())
	}
	mustContain(t, errOut.String(), MinFlixlintParam, "param")
}

// M3: make check の常駐の shim（hooks.json の版）が adds=param を書かない版なら、その shim を使わずに前面の flixlint で作る。
func TestSharedShimOlderThanTheOpNeedsIsNotUsed(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	// 名指しの flixlint は常駐の shim を使わない（段 1 の直し）ので、ゲームと同じ submodule の置き場（flixlint/bin/flixlint）で流す。
	must(t, os.Remove(filepath.Join(root, "flixlint")))
	must(t, os.MkdirAll(filepath.Join(root, "flixlint", "bin"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, "flixlint", "bin", "flixlint"), []byte("stand-in\n"), 0o755))
	t.Setenv("FGE_FLIXLINT", "")
	var out, errOut strings.Builder
	var got [][]string
	var log strings.Builder
	inner := spansRunner("retarget")
	code := Run(&out, &errOut, root, []string{"retarget-field", "--label", "tutorialDoc", "--from", "w", "--to", "res", "--def", "Tutorial.changed"},
		Options{Run: func(s Stage, d, dir string, cmd []string, l string) int {
			got = append(got, cmd)
			return inner(s, d, dir, cmd, l)
		},
			Log: &log, Verify: verifyWith(0, "", new([]string)),
			Shared: Shared{ShimJar: filepath.Join(root, "cache", "flixlint", "0.8.6", "flixlint-shim-0.78.0.jar"), HeapMB: 4096, IdleMinutes: 30}})
	if code != 0 || len(got) == 0 {
		t.Fatalf("終了コード %d:\n%s%s", code, out.String(), errOut.String())
	}
	if !strings.Contains(log.String(), "前面の flixlint の shim で索引を作ります") {
		t.Errorf("共有しない訳を言っていない:\n%s", log.String())
	}
	for _, c := range got {
		if strings.Contains(strings.Join(c, " "), "--shim") {
			t.Fatalf("古い常駐の shim を渡した: %v", c)
		}
	}
}

// 索引の頭の行に、操作が要る adds= が無ければ止まる（書いた shim が古い）。
func TestIndexWithoutTheAddsTheOpNeedsIsRefused(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	var out, errOut strings.Builder
	old := func(_ Stage, _, _ string, cmd []string, _ string) int {
		for i := 0; i+1 < len(cmd); i++ {
			if cmd[i] == "--spans" {
				os.WriteFile(cmd[i+1], []byte("# flixlint-spans 3 stage=typed columns=kind,file,sl,sc,el,ec,sym,owner,extra adds=arg,alias-decl\n"), 0o644)
			}
		}
		return 0
	}
	code := Run(&out, &errOut, root, []string{"retarget-field", "--label", "tutorialDoc", "--from", "w", "--to", "res", "--flixlint", filepath.Join(root, "flixlint")},
		Options{Run: old, Log: io.Discard})
	if code != 2 {
		t.Fatalf("止まるはず（終了コード %d）:\n%s%s", code, out.String(), errOut.String())
	}
	mustContain(t, errOut.String(), "adds=", "param")
}

// 中-1: 1 つのファイルに 2 つの mod。TwoA の use ViewEnv.Res は TwoB の中では効かないので、TwoB の葉の --params の Res は
// TwoB.Res。TwoB.top の r（TwoB.Res）は同じ型なので、広げずに r を書く（別の mod の use で引くと top にも res を足してしまう）。
func TestPropagateResolvesTheTypeOnlyWithUsesOfTheSameMod(t *testing.T) {
	root := fixtureRoot(t, "propagate-view")
	code, out, _ := runFixture(t, "propagate-view", root, "change-signature", "--def", "TwoB.leaf",
		"--params", "res: Res, w", "--args", "@res=TwoB.defaults(), w", "--propagate", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Two.flix"), "pub def top(r: Res, w: Int32): Int32 = leaf(r, w) + r#scale")
}

// 中-3: 呼ぶ所を囲む def が同じ名前・別の型の引数（res: ViewEnv.Res）を持つ。res を書くと型が合わず、res を足すと名前が
// 重なるので、その def へは広げずに止める（@res=式 があるので呼ぶ所には式を書く）。
func TestPropagateStopsAtADefWithAParameterOfTheSameNameAndAnotherType(t *testing.T) {
	root := fixtureRoot(t, "propagate-view")
	code, out, _ := runFixture(t, "propagate-view", root, "change-signature", "--def", "Clash.leaf",
		"--params", "res: Res, w", "--args", "@res=Res.defaults(), w", "--propagate", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Clash.flix"), "pub def other(res: ViewEnv.Res, w: Int32): Int32 = leaf(Res.defaults(), w) + res#atlas")
	mustContain(t, out, "同じ名前・別の型の引数 res を持つ")
}

// 中-2: @res=式 の式が --from（w）を読むと、読み替えが先に式の中の w#… を替え、本体の式を res に替えられずに意味が変わる。
// --retarget を fix で断る。
func TestPropagateRetargetRefusesAFallbackThatReadsTheFromParameter(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	before := read(t, root, "src/Tutorial.flix")
	code, out, cmds := runFixture(t, "retarget", root, "change-signature", "--def", "Tutorial.penOf",
		"--params", "res: Res", "--args", "@res={ tutorialDoc = w#tutorialDoc, theme = 0 }", "--propagate", "--retarget", "tutorialDoc", "--from", "w", "--apply", "--all")
	if code != 2 || len(cmds) != 0 || read(t, root, "src/Tutorial.flix") != before {
		t.Fatalf("書かずに断るはず（終了コード %d・確かめ %d 回）:\n%s", code, len(cmds), out)
	}
	mustContain(t, out, "@res=式 の式が --from の w を読む")
}

// 軽-5: --def で名指しした def に --from の引数が無ければ、黙って 0 件にせず fix にする。
func TestRetargetFieldReportsANamedDefWithoutTheFromParameter(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	code, out, cmds := runFixture(t, "retarget", root, "retarget-field", "--label", "tutorialDoc", "--from", "prev", "--to", "res",
		"--def", "Tutorial.penOf", "--apply", "--all")
	if code != 2 || len(cmds) != 0 {
		t.Fatalf("断るはず（終了コード %d・確かめ %d 回）:\n%s", code, len(cmds), out)
	}
	mustContain(t, out, "引数 prev が無い")
}

// --retarget は --propagate と組む旗（使い方の行）。付けなければ索引を作る前に止める。
func TestRetargetWithoutPropagateIsRefused(t *testing.T) {
	root := fixtureRoot(t, "retarget")
	code, out, cmds := runFixture(t, "retarget", root, "change-signature", "--def", "Tutorial.penOf",
		"--params", "res: Res", "--args", "@res", "--retarget", "tutorialDoc", "--from", "w")
	if code != 2 || len(cmds) != 0 {
		t.Fatalf("止まるはず（終了コード %d）:\n%s", code, out)
	}
	mustContain(t, out, "--retarget は --propagate と組む")
}
