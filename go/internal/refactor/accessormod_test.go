package refactor

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/accmod は口の書き方のお手本: 口を置く mod Box の中（Box.flix）・外（Out.flix）・use で読みの口を
// 取り込んだ外（Imp.flix）から、欄 flag（読みの口 flagOf が在る）と size（口が無い）を読み書きする。
// testdata/accmod-spans-typed.tsv はそれに flixlint --spans --stage typed src を掛けた物（typed の段には use の行が無い）。

var accmodFiles = []string{"flix.toml", "src/Box.flix", "src/Out.flix", "src/Imp.flix"}

func accmod(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, f := range accmodFiles {
		data, err := os.ReadFile(filepath.Join("testdata", "accmod", f))
		must(t, err)
		must(t, os.MkdirAll(filepath.Dir(filepath.Join(root, f)), 0o755))
		must(t, os.WriteFile(filepath.Join(root, f), data, 0o644))
	}
	must(t, os.WriteFile(filepath.Join(root, ".gitignore"), []byte("build/\nflixlint\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "flixlint"), []byte("stand-in\n"), 0o644))
	git(t, root, "init", "-q")
	git(t, root, "add", ".")
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-q", "-m", "fixture")
	return root
}

func accmodRunner(_ Stage, _, _ string, cmd []string, _ string) int {
	for i := 0; i+1 < len(cmd); i++ {
		if cmd[i] == "--spans" {
			data, err := os.ReadFile(filepath.Join("testdata", "accmod-spans-typed.tsv"))
			if err != nil || os.WriteFile(cmd[i+1], data, 0o644) != nil {
				return 4
			}
		}
	}
	return 0
}

func runAccmod(t *testing.T, root string, v VerifyRunner, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")), Options{Run: accmodRunner, Verify: v, Log: io.Discard})
	return code, out.String() + errOut.String()
}

func accmodRows(t *testing.T) []Row {
	t.Helper()
	rows, err := ReadIndex(filepath.Join("testdata", "accmod-spans-typed.tsv"), Typed)
	must(t, err)
	return rows
}

func accmodSrcs(t *testing.T) map[string]string {
	t.Helper()
	srcs := map[string]string{}
	for _, f := range accmodFiles[1:] {
		srcs[f] = read(t, filepath.Join("testdata", "accmod"), f)
	}
	return srcs
}

func contentsOf(t *testing.T, root string) string {
	t.Helper()
	var b strings.Builder
	for _, f := range accmodFiles[1:] {
		b.WriteString(read(t, root, f))
	}
	return b.String()
}

// 口の名前を修飾つき・なし・省く（既定）のどれで渡しても、同じ字に書き換える（mod の中は素・外は Box. つき）。
// Out に同じ名前の def（Out.sizeOf）があっても、修飾なしの sizeOf は Box の口（作る物）を指す。
func TestFieldToAccessorSpellsTheSameWhateverTheNamesLookLike(t *testing.T) {
	var got []string
	for _, names := range [][]string{
		{"--getter", "Box.sizeOf", "--setter", "Box.withSize"},
		{"--getter", "sizeOf", "--setter", "withSize"},
		nil,
	} {
		root := accmod(t)
		var cmds []string
		args := append([]string{"field-to-accessor", "--label", "size", "--receiver", "Box"}, names...)
		code, text := runAccmod(t, root, verifyWith(0, "", &cmds), append(args, "--apply")...)
		if code != 0 {
			t.Fatalf("%v: exit %d\n%s", names, code, text)
		}
		got = append(got, contentsOf(t, root))
	}
	for _, want := range []string{
		"pub def grow(b: Box): Box = withSize(sizeOf(b) + 1, b)",
		"pub def sizeOf(b: Box): Int32 = b#size",
		"pub def sizeTwice(b: Box): Int32 = Box.sizeOf(b) * 2",
	} {
		if !strings.Contains(got[0], want) {
			t.Errorf("%q が無い\n%s", want, got[0])
		}
	}
	if got[0] != got[1] || got[1] != got[2] {
		t.Errorf("渡し方で字が変わった\n--- 修飾つき\n%s\n--- なし\n%s\n--- 既定\n%s", got[0], got[1], got[2])
	}
}

// 在る口（flagOf）を修飾なしで名指ししても、外の所は Box. つきで呼ぶ。
func TestFieldToAccessorQualifiesAnExistingAccessorOutsideItsMod(t *testing.T) {
	root := accmod(t)
	var cmds []string
	code, text := runAccmod(t, root, verifyWith(0, "", &cmds), "field-to-accessor", "--label", "flag", "--receiver", "Box", "--getter", "flagOf", "--setter", "withFlag", "--apply")
	src := contentsOf(t, root)
	for _, want := range []string{
		"pub def raise(b: Box): Box = withFlag(true, b)",
		"pub def shown(b: Box): Bool = flagOf(b)",
		"pub def lower(b: Box): Box = Box.withFlag(false, b)",
		"pub def visible(b: Box): Bool = Box.flagOf(b)",
		"pub def both(b: Box): Bool = flagOf(b) and Box.flagOf(b)",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("%q が無い", want)
		}
	}
	if code != 0 {
		t.Errorf("exit %d\n%s\n%s", code, text, src)
	}
}

// use で取り込んだ名前（索引に use の行が在る時）は、その所では素の名前で呼ぶ。
func TestPlanAccessorUsesAnImportedName(t *testing.T) {
	rows := append(accmodRows(t), Row{Kind: KindUse, File: "src/Imp.flix", Line: 4, Col: 9, EndLine: 4, EndCol: 19, Sym: "Box.flagOf", Owner: "Imp", Extra: "alias=flagOf what=def"})
	p, err := PlanAccessor(accmodSrcs(t), rows, AccessorQuery{Label: "flag", Receiver: "Box", Reader: AccessorName{"Box", "flagOf"}, OwnerSyms: []string{"Box.flagOf"}, Home: "Box"})
	must(t, err)
	for _, e := range p.Edits {
		if e.File != "src/Imp.flix" {
			continue
		}
		got, err := e.Make("b#flag")
		if err != nil || got != "flagOf(b)" {
			t.Errorf("Imp の読み: %q %v（flagOf(b) のはず）", got, err)
		}
	}
}

// 欄を 2 つ渡すと、口を全部作り、1 つの patch・確かめ 1 回。2 つの欄を一緒に書く更新は口を重ねる。
// 最後の行は done で言い切る。
func TestFieldToAccessorMovesSeveralLabelsAtOnce(t *testing.T) {
	root := accmod(t)
	var cmds []string
	code, text := runAccmod(t, root, verifyWith(0, "", &cmds), "field-to-accessor", "--label", "flag,size", "--receiver", "Box", "--apply")
	src := contentsOf(t, root)
	for _, want := range []string{
		"pub def reset(b: Box): Box = withSize(0, withFlag(false, b))",
		"pub def grow(b: Box): Box = withSize(sizeOf(b) + 1, b)",
		"pub def withFlag(v: Bool, b: Box): Box = { flag = v | b }",
		"pub def sizeOf(b: Box): Int32 = b#size",
		"pub def sizeTwice(b: Box): Int32 = Box.sizeOf(b) * 2",
		"pub def lower(b: Box): Box = Box.withFlag(false, b)",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("%q が無い", want)
		}
	}
	lines := strings.Split(strings.TrimSpace(text), "\n")
	// 直の読み書き: flag 6（shown・raise・reset・lower・visible・both）・size 4（grow 2・reset・sizeTwice）。
	if code != 0 || len(cmds) != 1 || lines[len(lines)-1] != "done: 10 sites → 0 left outside Box · check ok" || strings.Contains(text, "next:") {
		t.Errorf("exit %d・確かめ %v\n%s\n%s", code, cmds, text, src)
	}
}

// 欄を 2 つ渡して確かめが落ちれば、全部の欄の書き換え（作った口も）を戻す。
func TestFieldToAccessorRevertsEveryLabelWhenTheCheckFails(t *testing.T) {
	root := accmod(t)
	before := contentsOf(t, root)
	var cmds []string
	code, text := runAccmod(t, root, verifyWith(1, "-- Resolution Error -- src/Out.flix:7\n", &cmds), "field-to-accessor", "--label", "flag,size", "--receiver", "Box", "--apply")
	if code != 1 || contentsOf(t, root) != before || !strings.Contains(text, "reverted") || strings.Contains(text, "done:") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

// 外した所が口の外に残れば、done は残りの数を言い、その欄の field-sites を next に出す。
func TestFieldToAccessorSaysWhatIsLeftOutside(t *testing.T) {
	root := accmod(t)
	var cmds []string
	_, text := runAccmod(t, root, verifyWith(0, "", &cmds), "field-to-accessor", "--label", "flag,size", "--receiver", "Box", "--skip", "src/Out.flix:7", "--apply")
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if lines[len(lines)-1] != "done: 10 sites → 1 left outside Box · check ok" || !strings.Contains(text, "next: bin/fge refactor field-sites --label size --receiver Box --outside Box") || !strings.Contains(text, "src/Out.flix:7") {
		t.Errorf("%s", text)
	}
}

func TestFieldToAccessorRefusesNamesWithSeveralLabels(t *testing.T) {
	code, text := runAccmod(t, accmod(t), nil, "field-to-accessor", "--label", "flag,size", "--receiver", "Box", "--getter", "flagOf")
	if code != 2 || !strings.Contains(text, "口の名前を渡せない") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

// 無い口を alias の mod と違う mod の名前で頼まれたら作らない（作る所と呼ぶ字が食い違うため）。
func TestFieldToAccessorRefusesToMakeAnAccessorInAnotherMod(t *testing.T) {
	code, text := runAccmod(t, accmod(t), nil, "field-to-accessor", "--label", "size", "--receiver", "Box", "--getter", "Out.nope")
	if code != 2 || !strings.Contains(text, "alias の mod（Box）にだけ作る") {
		t.Errorf("exit %d\n%s", code, text)
	}
}
