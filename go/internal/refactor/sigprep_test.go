package refactor

import (
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/sigprep は change-signature の下ごしらえ（Extract Variable）・改行の形・use を足すと、remove-dead の doc を
// 移すお手本。testdata/sigprep-spans-resolved.tsv はそれに flixlint 0.7.1 の --spans --stage resolved src test を掛けた物。
// 期待の字は「本体の式が --args の式（とその def の record の欄）と同じなら引数から読む・並びは元の形・
// 引けない型の名前には use」の規則から手で書いた物。

func sigprepRoot(t *testing.T) string { return fixtureRoot(t, "sigprep") }

// fixtureRoot は testdata/<name> を git の作業場として写した根（flixlint の代わりの印のファイルつき）。
func fixtureRoot(t *testing.T, name string) string {
	t.Helper()
	root := t.TempDir()
	base := filepath.Join("testdata", name)
	must(t, filepath.WalkDir(base, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(base, p)
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(filepath.Join(root, rel)), 0o755); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(root, rel), data, 0o644)
	}))
	must(t, os.WriteFile(filepath.Join(root, ".gitignore"), []byte("build/\nflixlint\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "flixlint"), []byte("stand-in\n"), 0o644))
	git(t, root, "init", "-q")
	git(t, root, "add", ".")
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-q", "-m", "fixture")
	return root
}

var sigprepRunner = spansRunner("sigprep")

// spansRunner は索引を作る代わりに testdata/<name>-spans-<段>.tsv を置く Runner。
func spansRunner(name string) Runner {
	return func(stage Stage, _, _ string, cmd []string, _ string) int {
		for i := 0; i+1 < len(cmd); i++ {
			if cmd[i] == "--spans" {
				data, err := os.ReadFile(filepath.Join("testdata", name+"-spans-"+string(stage)+".tsv"))
				if err != nil || os.WriteFile(cmd[i+1], data, 0o644) != nil {
					return 4
				}
			}
		}
		return 0
	}
}

func runSigprep(t *testing.T, root string, args ...string) (int, string, []string) {
	t.Helper()
	var out, errOut strings.Builder
	var cmds []string
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")),
		Options{Run: sigprepRunner, Verify: verifyWith(0, "", &cmds), Log: io.Discard})
	return code, out.String() + errOut.String(), cmds
}

// 下ごしらえ無し: 本体の ViewEnv.of の欄と同じ式（ctx・w#theme・use の別名で書いた Clock.nowOf(w)）と --args の式（w#dialog）を
// 引数から読む形に替え、決まった桁で折った並びは同じ桁で折る。
func TestSignatureLiftsTheRecordFieldsWithoutPreparation(t *testing.T) {
	root := sigprepRoot(t)
	code, out, _ := runSigprep(t, root, "change-signature", "--def", "Talk.box",
		"--params", "env: ViewEnv.Env, dialog: Int32, lines", "--args", "ViewEnv.of(ctx, w), w#dialog, lines", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Talk.flix"),
		"    pub def box(env: ViewEnv.Env, dialog: Int32,\n                lines: Int32): Int32 =\n        env#ctx#atlas + env#res#theme * lines + env#now + dialog\n",
		"box(ViewEnv.of(ctx, w), w#dialog, 1) + box(ViewEnv.of(ctx, w), w#dialog, 2)")
	mustContain(t, out, "done: 3 sites（宣言 1・呼ぶ所 2）→ 0 left · check ok")
}

// 1 つずつ改行した並びは 1 つずつ改行して書く。let に別の名前で置いた式は let ごと引数の名前に。
func TestSignatureKeepsOneParameterPerLine(t *testing.T) {
	root := sigprepRoot(t)
	code, out, _ := runSigprep(t, root, "change-signature", "--def", "Talk.tag",
		"--params", "env: ViewEnv.Env, n", "--args", "ViewEnv.of(ctx, w), n", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Talk.flix"),
		"    pub def tag(env: ViewEnv.Env,\n                n: Int32): Int32 =\n        let e = env;\n        e#res#script + n + env#now\n",
		"tag(ViewEnv.of(ctx, w), 3)")
}

// 式の一部だけが同じ（{ theme = 1 | w } を渡す resOf）は替えずに人へ回し、効果のある def を呼ぶ --args の式も人へ回す。
func TestSignatureLeavesPartialMatchesAndEffectsToAPerson(t *testing.T) {
	root := sigprepRoot(t)
	before := read(t, root, "src/Talk.flix")
	code, out, cmds := runSigprep(t, root, "change-signature", "--def", "Talk.odd",
		"--params", "env: ViewEnv.Env", "--args", "ViewEnv.of(ctx, w)", "--apply")
	if code != 2 || len(cmds) != 0 || read(t, root, "src/Talk.flix") != before {
		t.Fatalf("書かずに断るはず（終了コード %d）:\n%s", code, out)
	}
	mustContain(t, out, "src/Talk.flix:22:13  fix  替えた後も本体が消える引数 w を使う（2 か所。最初: `env#ctx#atlas + ViewEnv.resOf({ theme = …`）")
	code, out, _ = runSigprep(t, root, "change-signature", "--def", "Talk.odd",
		"--params", "env: ViewEnv.Env, t: Int32", "--args", "ViewEnv.of(ctx, w), Lib.tick(w)")
	if code != 0 {
		t.Fatalf("dry-run の終了コード %d:\n%s", code, out)
	}
	mustContain(t, out, "fix  --args の `Lib.tick(w)` は効果のある def Lib.tick を呼ぶ")
}

// 新しい引数の型の名前（Clock.Time の Clock）が引けないファイルには use を足す。出どころは索引の use の行（Talk の
// use Lib.Clock）。同じ親の波括弧の並びがあれば字の順の位置へ・use の無い mod は mod の行の次へ。
func TestSignatureAddsTheUseForTheNewParameterType(t *testing.T) {
	root := sigprepRoot(t)
	code, out, _ := runSigprep(t, root, "change-signature", "--def", "Stand.stand,Plain.stand",
		"--params", "now: Clock.Time, h", "--args", "Lib.Clock.nowOf(w), h", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Stand.flix"), "    use Lib.{Clock, Ctx}\n",
		"pub def stand(now: Clock.Time, h: Int32): Int32 = now + h\n")
	mustContain(t, read(t, root, "src/Plain.flix"), "mod Plain {\n    use Lib.{Clock}\n\n    pub def stand(now: Clock.Time, h: Int32): Int32 = now * h\n")
	mustContain(t, read(t, root, "test/TestSigprep.flix"), "Stand.stand(Lib.Clock.nowOf(w), 1) + Plain.stand(Lib.Clock.nowOf(w), 2)")
	mustContain(t, out, "use を足す: Clock（Lib.） → src/Stand.flix・Clock（Lib.） → src/Plain.flix")
}

// remove-dead が転送するだけの包みを消す時、包みの doc を転送先へ移す: 転送先の doc が包みを指せば置き換え、
// 転送先に doc が無ければ足し、包みを指さない doc（人の書いた物）は残す。
func TestRemoveDeadMovesTheWrappersDocToItsTarget(t *testing.T) {
	for _, c := range []struct{ def, want, gone, note string }{
		{"Wrap.stand", "    /// 立ち絵 1 体（表情の絵を 1 枚貼る）。\n    pub def standIn(", "stand の、", "転送するだけの包みの doc を転送先へ: Wrap.standIn"},
		{"Wrap.plain", "    /// 台本の番号に 1 を足す。\n    pub def blank(", "pub def plain", "転送するだけの包みの doc を転送先へ: Wrap.blank"},
		{"Wrap.keep", "    /// 時計の値に 2 を足す。\n    pub def kept(", "包みの説明", ""},
	} {
		root := sigprepRoot(t)
		code, out, _ := runSigprep(t, root, "remove-dead", "--def", c.def, "--apply")
		if code != 0 {
			t.Fatalf("%s: 終了コード %d:\n%s", c.def, code, out)
		}
		wrap := read(t, root, "src/Wrap.flix")
		mustContain(t, wrap, c.want)
		if strings.Contains(wrap, c.gone) {
			t.Errorf("%s: %q が残る:\n%s", c.def, c.gone, wrap)
		}
		if c.note != "" {
			mustContain(t, out, c.note)
		} else if strings.Contains(out, "転送するだけの包み") {
			t.Errorf("%s: doc を移さないはず:\n%s", c.def, out)
		}
	}
}

// 同じ転送先へ移す包みが 2 つなら、書き換えを 1 つにまとめて両方の doc を並べる（重なった書き換えで断らない）。
func TestRemoveDeadMergesTwoWrappersDocsIntoOneTarget(t *testing.T) {
	root := sigprepRoot(t)
	code, out, _ := runSigprep(t, root, "remove-dead", "--def", "Wrap.stand,Wrap.standZero", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, read(t, root, "src/Wrap.flix"),
		"    /// 立ち絵 1 体（表情の絵を 1 枚貼る）。\n    /// 立ち絵 1 体（時計を 0 で描く）。\n    pub def standIn(")
	mustContain(t, out, "転送するだけの包みの doc を転送先へ: Wrap.standIn（doc を Wrap.stand・Wrap.standZero から移す）")
}
