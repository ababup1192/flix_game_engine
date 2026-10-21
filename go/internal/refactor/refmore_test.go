package refactor

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/refmore は make-private・remove-param・change-signature の呼ぶ所の局所の名前（@名前）のお手本。
// testdata/refmore-spans-resolved.tsv はそれに flixlint 0.7.2 の --spans --stage resolved src test を掛けた物。
// 期待の字は「外の mod の使い手（呼び出し・use・テスト）が 0 の時だけ pub を外す・本体が使わない引数を宣言と呼ぶ所から
// 消す・@名前 は呼ぶ所を囲む def で束ねた名前をそのまま書く」の規則から手で書いた物。

var refmoreRunner = spansRunner("refmore")

func runRefmore(t *testing.T, root string, v VerifyRunner, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")),
		Options{Run: refmoreRunner, Verify: v, Log: io.Discard})
	return code, out.String() + errOut.String()
}

// verifySeq は確かめを呼ばれた順に、logs の中身を書いて codes の終了コードを返す（最後の物を繰り返す）。
func verifySeq(codes []int, logs []string) VerifyRunner {
	n := 0
	return func(_, _, log string) int {
		i := n
		if i >= len(codes) {
			i = len(codes) - 1
		}
		n++
		os.WriteFile(log, []byte(logs[i]), 0o644)
		return codes[i]
	}
}

// --def を省くと、同じ mod の中からだけ呼ばれる pub の def が全部当たる（外の mod の use・テスト・どこからも呼ばれない物は当たらない）。
func TestMakePrivateFindsTheDefsUsedOnlyInTheirModule(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	var cmds []string
	code, out := runRefmore(t, root, verifyWith(0, "", &cmds), "make-private")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	for _, want := range []string{"pub を外す def 2", "A.helper（同じ mod の中だけ 1 か所）", "A.wrap（同じ mod の中だけ 3 か所）"} {
		if !strings.Contains(out, want) {
			t.Errorf("%q が無い:\n%s", want, out)
		}
	}
	for _, not := range []string{"A.keep", "A.onlyUsed", "A.lonely"} {
		if strings.Contains(out, not) {
			t.Errorf("%s が当たった:\n%s", not, out)
		}
	}
}

// --def で名指しすると pub だけを消し、確かめが通れば done の行で言い切る。
func TestMakePrivateRemovesOnlyThePubWord(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	var cmds []string
	code, out := runRefmore(t, root, verifyWith(0, "", &cmds), "make-private", "--def", "A.helper", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	src := read(t, root, "src/A.flix")
	if !strings.Contains(src, "    def helper(x: Int32, unused: Int32): Int32 = x + 1") || !strings.Contains(src, "pub を外せる") {
		t.Errorf("宣言の pub だけが消えていない:\n%s", src)
	}
	if !strings.Contains(out, "done: 1 defs → pub を外した · check ok") {
		t.Errorf("done の行が無い:\n%s", out)
	}
}

// 外の mod が use だけする def・どこからも呼ばれない def は書かずに fix（理由つき）。
func TestMakePrivateHandsUsesAndUnreferencedDefsToAPerson(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	var cmds []string
	code, out := runRefmore(t, root, verifyWith(0, "", &cmds), "make-private", "--def", "A.onlyUsed,A.lonely", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	for _, want := range []string{"src/B.flix:2:18（use）", "remove-dead --def A.lonely", "nothing"} {
		if !strings.Contains(out, want) {
			t.Errorf("%q が無い:\n%s", want, out)
		}
	}
	if len(cmds) != 0 || !strings.Contains(read(t, root, "src/A.flix"), "pub def onlyUsed") {
		t.Errorf("書いた（確かめ %d 回）", len(cmds))
	}
}

// --param を省くと本体が使わない引数を消し、呼ぶ所の同じ位置の式も消す。
func TestRemoveParamDropsTheUnusedParameterAndItsArguments(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	code, out := runRefmore(t, root, verifySeq([]int{0}, []string{""}), "remove-param", "--def", "A.helper", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	src := read(t, root, "src/A.flix")
	for _, want := range []string{"pub def helper(x: Int32): Int32 = x + 1", "pub def keep(x: Int32): Int32 = helper(x)"} {
		if !strings.Contains(src, want) {
			t.Errorf("%q が無い:\n%s", want, src)
		}
	}
	if !strings.Contains(out, "done: 1 params（呼ぶ所 1）→ 0 left · check ok") {
		t.Errorf("done の行が無い:\n%s", out)
	}
}

// 確かめが書く前から落ちている時: 書いた後の誤りが書く前の誤りに収まれば通し、新しい誤りが出れば戻す。
func TestRemoveParamComparesWithTheCheckBeforeWriting(t *testing.T) {
	before := "-- Redundancy Error [E8405] ---------- src/A.flix\n\n>> Unused formal parameter 'unused'.\n\n" +
		"-- Type Error [E8752] ---------- src/B.flix\n"
	same := "-- Type Error [E8752] ---------- src/B.flix\n"
	worse := same + "\n残り 1 件:\n  src/A.flix:4 — Resolution Error [E2136]\n"
	root := fixtureRoot(t, "refmore")
	code, out := runRefmore(t, root, verifySeq([]int{1, 1}, []string{before, same}), "remove-param", "--def", "A.helper", "--param", "unused", "--apply")
	if code != 0 || !strings.Contains(out, "誤り 前 2 → 後 1・新しい誤り 0") {
		t.Fatalf("前から落ちている確かめで通していない（終了コード %d）:\n%s", code, out)
	}
	root = fixtureRoot(t, "refmore")
	code, out = runRefmore(t, root, verifySeq([]int{1, 1}, []string{before, worse}), "remove-param", "--def", "A.helper", "--apply")
	if code != 1 || !strings.Contains(out, "新しい誤り: src/A.flix Resolution Error [E2136] ×1") {
		t.Fatalf("新しい誤りで戻していない（終了コード %d）:\n%s", code, out)
	}
	if !strings.Contains(read(t, root, "src/A.flix"), "helper(x: Int32, unused: Int32)") {
		t.Errorf("戻していない")
	}
}

// 本体が使う引数を --param で名指しすると、消さずに fix。
func TestRemoveParamRefusesAParameterTheBodyUses(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	code, out := runRefmore(t, root, verifySeq([]int{0}, []string{""}), "remove-param", "--def", "A.helper", "--param", "x", "--apply")
	if code != 2 || !strings.Contains(out, "本体が引数 x を使う") {
		t.Fatalf("断っていない（終了コード %d）:\n%s", code, out)
	}
}

// --args の @名前 は呼ぶ所の局所の名前: let で束ねた所はそのまま書き、束ねていない所は fix。
func TestSignatureTakesTheCallSitesLocalName(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	var cmds []string
	code, out := runRefmore(t, root, verifyWith(0, "", &cmds), "change-signature", "--def", "A.wrap", "--params", "a, _n: Int32", "--args", "a, @n")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	for _, want := range []string{"呼ぶ所に局所の名前 @n が無い", "@n は呼ぶ所の局所の名前", "人へ回す 2"} {
		if !strings.Contains(out, want) {
			t.Errorf("%q が無い:\n%s", want, out)
		}
	}
	diff := read(t, root, "build/refactor/last.diff")
	if !strings.Contains(diff, "+        wrap(n, n)") {
		t.Errorf("let で束ねた呼ぶ所の式が wrap(n, n) でない:\n%s", diff)
	}
}

// commitFiles は fixture の根に files（パス → 中身）を書いてコミットする（git の知るファイルだけが入口として数わる）。
func commitFiles(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for f, body := range files {
		must(t, os.MkdirAll(filepath.Dir(filepath.Join(root, f)), 0o755))
		must(t, os.WriteFile(filepath.Join(root, f), []byte(body), 0o644))
	}
	git(t, root, "add", ".")
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-q", "-m", "files")
}

// docRefsRules は doc-refs の規約の小さな物（NOTES.md と src・test の .flix のコメントを見る）。
const docRefsRules = `{"docDirs": ["docs"], "docFiles": ["NOTES.md"], "sources": ["src", "test"], "fileExts": ["flix", "md"],
 "limit": 10, "fullOut": "build/doc-refs/last.txt", "plannedMarks": ["（予定）"], "flixComments": true}`

// 文章（NOTES.md・計画の diff）に名前が出るだけでは断らない。doc-refs の決まりで文書が名指す所（` ` の中・.flix の
// コメント）は消した後に next で doc-refs を示す。消える宣言の中のコメントは数えない。
func TestRemoveDeadRemovesADefTheDocsNameAndPointsToDocRefs(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	a := strings.Replace(read(t, root, "src/A.flix"), "/// どこからも呼ばれない。", "/// `A.lonely` はどこからも呼ばれない。", 1)
	commitFiles(t, root, map[string]string{
		"bin/lint-rules/doc-refs.json": docRefsRules,
		"NOTES.md":                     "# 記録\n\n`A.lonely` は呼ばれない。lonely と A.lonely は地の文。\n`A.lonely`（予定）\n",
		"plans/old.diff":               "+    pub def x(): Int32 = A.lonely()\n",
		"src/A.flix":                   a,
		"src/B.flix":                   read(t, root, "src/B.flix") + "// `A.lonely` を呼ぶ所は無い\n",
	})
	var cmds []string
	code, out := runRefmore(t, root, verifyWith(0, "", &cmds), "remove-dead", "--def", "A.lonely", "--apply")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	if strings.Contains(read(t, root, "src/A.flix"), "def lonely") {
		t.Errorf("消していない:\n%s", out)
	}
	mustContain(t, out, "文書が名指す def 2 か所（消すと doc-refs が止める）: NOTES.md:3 A.lonely・src/B.flix:7 A.lonely",
		"next: bin/fge doc-refs NOTES.md src/B.flix")
}

// make-private は文書の名指しを見ない（名前は残る）・JSON の文（note）の中の名前も入口と数えない。入口のファイル（Makefile）に
// 字で出る def は fix。
func TestMakePrivateIgnoresDocsButKeepsEntryNames(t *testing.T) {
	root := fixtureRoot(t, "refmore")
	commitFiles(t, root, map[string]string{
		"bin/lint-rules/doc-refs.json": docRefsRules,
		"NOTES.md":                     "`A.helper` は同じ mod の中だけ。\n",
		"Makefile":                     "run:\n\techo A.wrap\n",
		"lint/limits/x.json":           "{\"note\": \"A.helper は同じ mod の中だけ\", \"limit\": 1}\n",
	})
	var cmds []string
	code, out := runRefmore(t, root, verifyWith(0, "", &cmds), "make-private")
	if code != 0 {
		t.Fatalf("終了コード %d:\n%s", code, out)
	}
	mustContain(t, out, "pub を外す def 1", "A.helper（同じ mod の中だけ 1 か所）", "名前が入口のファイルに字で出る（"+filepath.Base(root)+"/Makefile")
}
