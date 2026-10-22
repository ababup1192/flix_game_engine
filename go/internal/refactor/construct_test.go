package refactor

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testdata/shape は remove-field・fix-construction のお手本（src/Shape.flix・test/TestShape.flix）。
// testdata/shape-spans-<段>.tsv はそれに flixlint --spans --stage <段> src test を掛けた物。
// 期待の字は「型と組み立ての欄の組を揃える」規則から手で書いた物。

// shape は testdata/shape を写した git の作業場（コミット済み）。edit があれば、コミットの前にファイルの字を置き換える
// （人が型を手で直した後の形。行の数は変えないので索引はそのまま使える）。
func shape(t *testing.T, edit map[string][2]string) string {
	t.Helper()
	root := t.TempDir()
	for _, f := range []string{"flix.toml", "src/Shape.flix", "test/TestShape.flix"} {
		data, err := os.ReadFile(filepath.Join("testdata", "shape", f))
		must(t, err)
		text := string(data)
		if e, ok := edit[f]; ok {
			if !strings.Contains(text, e[0]) {
				t.Fatalf("%s に %q が無い", f, e[0])
			}
			text = strings.Replace(text, e[0], e[1], 1)
		}
		must(t, os.MkdirAll(filepath.Dir(filepath.Join(root, f)), 0o755))
		must(t, os.WriteFile(filepath.Join(root, f), []byte(text), 0o644))
	}
	must(t, os.WriteFile(filepath.Join(root, ".gitignore"), []byte("build/\nflixlint\n"), 0o644))
	must(t, os.WriteFile(filepath.Join(root, "flixlint"), []byte("stand-in\n"), 0o644))
	git(t, root, "init", "-q")
	git(t, root, "add", ".")
	git(t, root, "-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-q", "-m", "fixture")
	return root
}

func shapeRunner(stage Stage, _, _ string, cmd []string, _ string) int {
	for i := 0; i+1 < len(cmd); i++ {
		if cmd[i] == "--spans" {
			data, err := os.ReadFile(filepath.Join("testdata", "shape-spans-"+string(stage)+".tsv"))
			if err != nil || os.WriteFile(cmd[i+1], data, 0o644) != nil {
				return 4
			}
		}
	}
	return 0
}

func runShape(t *testing.T, root string, v VerifyRunner, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code := Run(&out, &errOut, root, append(args, "--flixlint", filepath.Join(root, "flixlint")), Options{Run: shapeRunner, Verify: v, Log: io.Discard})
	return code, out.String() + errOut.String()
}

func TestRemoveRecordFieldKeepsTheLayout(t *testing.T) {
	for _, c := range []struct{ text, label, want string }{
		{"{ a = 1, x = 2, b = 3 }", "x", "{ a = 1, b = 3 }"},
		{"{ x = 1, a = 2 }", "x", "{ a = 2 }"},
		{"{ a = 1, x = f(b, c) }", "x", "{ a = 1 }"},
		{"{ a = 1, x = 2 | w }", "x", "{ a = 1 | w }"},
		{"{\n    a = 1,\n    // x の説明\n    x = 2,\n    b = 3\n}", "x", "{\n    a = 1,\n    b = 3\n}"},
		{"{\n    a = 1,\n    x = 2 // 後ろのコメント\n}", "x", "{\n    a = 1\n}"},
		{"{ a = 1,\n  x = 2, b = 3 }", "x", "{ a = 1,\n  b = 3 }"},
		{"{ a = Int32,\n  x = Map[String, Int32] }", "x", "{ a = Int32 }"},
	} {
		got, err := RemoveRecordField(c.text, c.label)
		if err != nil || got != c.want {
			t.Errorf("%q: got %q %v（%q のはず）", c.text, got, err, c.want)
		}
	}
	// 消すのは欄の行と、その欄だけの説明のコメント。record 全体の説明（最初の欄の前）と、空行の後の見出し（下に続く
	// 欄の組にかかる物）は残す。見出しの下の欄が 1 つだけ（後ろが空行か閉じる `}`）なら、その欄の説明として一緒に消す。
	for _, c := range []struct{ text, label, want string }{
		{"{\n    // World 全体の説明\n    x = 1,\n    a = 2\n}", "x", "{\n    // World 全体の説明\n    a = 2\n}"},
		{"{\n    a = 1,\n\n    // 夜の欄\n    x = 2,\n    b = 3\n}", "x", "{\n    a = 1,\n\n    // 夜の欄\n    b = 3\n}"},
		{"{\n    a = 1,\n\n    // x の説明\n    x = 2,\n\n    b = 3\n}", "x", "{\n    a = 1,\n\n    b = 3\n}"},
		{"{\n    a = 1,\n\n    // x の説明\n    x = 2\n}", "x", "{\n    a = 1\n}"},
	} {
		got, err := RemoveRecordField(c.text, c.label)
		if err != nil || got != c.want {
			t.Errorf("%q: got %q %v（%q のはず）", c.text, got, err, c.want)
		}
	}
	if _, err := RemoveRecordField("{ x = 1 }", "x"); err == nil {
		t.Error("欄が 1 つの record から消して空にした")
	}
}

// 最初の欄を消して次の欄の説明のコメントが `{` の直後に来る時は、その欄の行の後ろへ移す（Flix 0.78 は record の型で
// `{` の直後のコメントを読めず「Expected ',' before '='」で止まる。cycle で remove-field の後に出た形）。元から先頭に
// あるコメントは動かさない。
func TestRemoveRecordFieldLeavesNoCommentRightAfterTheBrace(t *testing.T) {
	for _, c := range []struct{ text, label, want string }{
		{"{\n    x = Int32,\n    // a の説明\n    a = Int32\n}", "x", "{\n    a = Int32 // a の説明\n}"},
		{"{\n    x = Int32,\n    // a の説明\n    // 続き\n    a = Int32,\n    b = Int32\n}", "x", "{\n    a = Int32, // a の説明 // 続き\n    b = Int32\n}"},
		{"{\n    x = Int32, // x の説明\n    // a の説明\n    a = Int32\n}", "x", "{\n    a = Int32 // a の説明\n}"},
		{"{\n    // World 全体の説明\n    x = 1,\n    a = 2\n}", "x", "{\n    // World 全体の説明\n    a = 2\n}"},
	} {
		got, err := RemoveRecordField(c.text, c.label)
		if err != nil || got != c.want {
			t.Errorf("%q: got %q %v（%q のはず）", c.text, got, err, c.want)
		}
	}
}

func TestAddRecordFieldFollowsTheLastField(t *testing.T) {
	for _, c := range []struct{ text, want string }{
		{"{ a = 1, b = 2 }", "{ a = 1, b = 2, x = 0 }"},
		{"{\n    a = 1,\n    b = 2\n}", "{\n    a = 1,\n    b = 2,\n    x = 0\n}"},
		{"{\n    a = 1,\n    b = 2 // 説明\n}", "{\n    a = 1,\n    b = 2,\n    x = 0 // 説明\n}"},
		{"{ a = 1,\n  b = { y = 2 } }", "{ a = 1,\n  b = { y = 2 }, x = 0 }"},
	} {
		got, err := AddRecordField(c.text, "x", "0")
		if err != nil || got != c.want {
			t.Errorf("%q: got %q %v（%q のはず）", c.text, got, err, c.want)
		}
	}
}

func TestScanLiteralsSkipsTypesStringsAndCollections(t *testing.T) {
	src := `let r: { a = Int32 } = { a = 1 }; "{ a = 2 }"; Map#{ "k" => { a = 3 } }; // { a = 4 }
	{ let b = 1; { a = b, c = { d = 2 } } }; { a = 5 | r }`
	var got []string
	for _, l := range ScanLiterals(src, 0, len(src)) {
		got = append(got, src[l.Brace:l.End])
	}
	want := []string{"{ a = 1 }", "{ a = 3 }", "{ a = b, c = { d = 2 } }", "{ d = 2 }"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("got %q（%q のはず）", got, want)
	}
}

func TestRemoveFieldTakesItOutOfTheTypeAndEveryConstruction(t *testing.T) {
	root := shape(t, nil)
	var cmds []string
	code, text := runShape(t, root, verifyWith(0, "", &cmds), "remove-field", "--label", "old", "--receiver", "World", "--apply")
	src, test := read(t, root, "src/Shape.flix"), read(t, root, "test/TestShape.flix")
	for _, want := range []string{
		"    pub type alias World = {\n        speed = Int32,\n        clock = Float64,\n",
		"        { speed = 1,\n          clock = 0.0,\n",
		// 別名 Model を通した組み立ても。
		"pub def fresh(): Model = { speed = 2, clock = 1.0, pointer = { x = 0.0, y = 0.0 } }",
		// 欄の組が違う record・文字列の中は替えない。
		"pub def pair(): Pair = { speed = 3, clock = 2.0 }",
		`"{ speed = 1, old = false, clock = 0.0, pointer = 0 }"`,
	} {
		if !strings.Contains(src, want) {
			t.Errorf("%q が無い", want)
		}
	}
	if !strings.Contains(test, "        speed = 5,\n        clock = 0.0,\n") {
		t.Errorf("テストの作り手から消えていない\n%s", test)
	}
	if code != 0 || len(cmds) != 1 || !strings.Contains(text, "組み立てから消す 3") {
		t.Errorf("exit %d・確かめ %v\n%s\n%s", code, cmds, text, src)
	}
}

func TestRemoveFieldStopsWhileTheFieldIsRead(t *testing.T) {
	root := shape(t, nil)
	before := read(t, root, "src/Shape.flix")
	code, text := runShape(t, root, nil, "remove-field", "--label", "clock", "--receiver", "World", "--apply")
	if code != 2 || read(t, root, "src/Shape.flix") != before || !strings.Contains(text, "src/Shape.flix:35:39") || !strings.Contains(text, "src/Shape.flix:35:49") ||
		!strings.Contains(text, "組み立て: 欄 clock を消す所 3・人へ回す 0") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

// 欄の組が World と違う record の r#old（flagOf。受け手は recv=? via=none）は World の old の読みに数えない。
func TestRemoveFieldIgnoresTheSameLabelOfAnotherRecord(t *testing.T) {
	root := shape(t, nil)
	code, text := runShape(t, root, verifyWith(0, "", new([]string)), "remove-field", "--label", "old", "--receiver", "World")
	if code != 0 || strings.Contains(text, "src/Shape.flix:47") || !strings.Contains(text, "直の読み書き 0") {
		t.Errorf("exit %d\n%s", code, text)
	}
	// field-sites も同じ判定（決まらない物の unsure にも並べない）。
	if code, text := runShape(t, root, nil, "field-sites", "--label", "old", "--receiver", "World"); code != 0 || strings.Contains(text, "src/Shape.flix:47") {
		t.Errorf("field-sites: exit %d\n%s", code, text)
	}
}

// 開いた row の r#speed（speedOfAny。recv=? via=open）は World かもしれないので数え、人が --skip で外せば数えない。
func TestRemoveFieldSkipLeavesOutAReadTheHumanJudged(t *testing.T) {
	root := shape(t, nil)
	if code, text := runShape(t, root, nil, "remove-field", "--label", "speed", "--receiver", "World"); code != 2 || !strings.Contains(text, "直の読み書き 2") || !strings.Contains(text, "src/Shape.flix:50:64") {
		t.Errorf("開いた row を数えていない: exit %d\n%s", code, text)
	}
	code, text := runShape(t, root, nil, "remove-field", "--label", "speed", "--receiver", "World", "--skip", "src/Shape.flix:50")
	if code != 2 || !strings.Contains(text, "直の読み書き 1") || strings.Contains(text, "src/Shape.flix:50:64") || !strings.Contains(text, "--skip で外した読み書き 1") {
		t.Errorf("--skip が読み書きに効かない: exit %d\n%s", code, text)
	}
}

func TestRemoveFieldOnACaseRecord(t *testing.T) {
	root := shape(t, nil)
	code, text := runShape(t, root, verifyWith(0, "", new([]string)), "remove-field", "--label", "top", "--case", "Panel.Open", "--apply")
	src := read(t, root, "src/Shape.flix")
	for _, want := range []string{
		"case Open({ at = Int32, cursor = Int32 })",
		"Panel.Open({ at = at, cursor = 0 })",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("%q が無い\n%s", want, text)
		}
	}
	if code != 0 {
		t.Errorf("exit %d\n%s", code, text)
	}
	// case の record の欄の読み（受け手は ?）が残っていれば止める。
	if code, text := runShape(t, shape(t, nil), nil, "remove-field", "--label", "cursor", "--case", "Panel.Open"); code != 2 || !strings.Contains(text, "src/Shape.flix:40:33") {
		t.Errorf("読まれている case の欄で止まらない: exit %d\n%s", code, text)
	}
}

// 人が型に欄を足した後（1 行）、組み立てに --value の式で足す。
func TestFixConstructionAddsTheFieldWithTheValue(t *testing.T) {
	root := shape(t, map[string][2]string{"src/Shape.flix": {"        clock = Float64,\n", "        clock = Float64, level = Int32,\n"}})
	code, text := runShape(t, root, verifyWith(0, "", new([]string)), "fix-construction", "--label", "level", "--receiver", "World", "--value", "0", "--apply")
	src, test := read(t, root, "src/Shape.flix"), read(t, root, "test/TestShape.flix")
	for _, want := range []string{
		"          pointer = { x = -1.0, y = -1.0 }, level = 0 }",
		"pointer = { x = 0.0, y = 0.0 }, level = 0 }",
		"pub def pair(): Pair = { speed = 3, clock = 2.0 }",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("%q が無い", want)
		}
	}
	if !strings.Contains(test, "        pointer = { x = 0.0, y = 0.0 },\n        level = 0\n    }") {
		t.Errorf("テストの作り手に足していない\n%s", test)
	}
	if code != 0 || !strings.Contains(text, "足す所 3") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

// 人が型から欄を消した後（remove-field を使わなかった時）、組み立てからも消す。
func TestFixConstructionRemovesWhatTheTypeNoLongerHas(t *testing.T) {
	root := shape(t, map[string][2]string{"src/Shape.flix": {"        old = Bool,\n", "        // old は消した\n"}})
	code, text := runShape(t, root, verifyWith(0, "", new([]string)), "fix-construction", "--label", "old", "--receiver", "World", "--apply")
	if code != 0 || strings.Contains(read(t, root, "test/TestShape.flix"), "old = false") || !strings.Contains(text, "消す所 3") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

func TestFixConstructionNeedsAValueWhenTheTypeHasTheField(t *testing.T) {
	code, text := runShape(t, shape(t, nil), nil, "fix-construction", "--label", "old", "--receiver", "World")
	if code != 2 || !strings.Contains(text, "--value") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

// 欄の組が同じ別の型があれば、どちらを組み立てているか決めずに fix へ回す。
func TestFixConstructionLeavesAmbiguousShapesToFix(t *testing.T) {
	root := shape(t, map[string][2]string{"src/Shape.flix": {"    pub type alias Pair = { speed = Int32, clock = Float64 }", "    pub type alias Pair = { speed = Int32, old = Bool, clock = Float64, pointer = Bool }"}})
	before := read(t, root, "test/TestShape.flix")
	code, text := runShape(t, root, verifyWith(0, "", new([]string)), "remove-field", "--label", "old", "--receiver", "World", "--apply")
	if read(t, root, "test/TestShape.flix") != before || !strings.Contains(text, "欄の組が同じ別の型") || !strings.Contains(text, "人へ回す 3") {
		t.Errorf("exit %d\n%s", code, text)
	}
}

// 扱いの表: 索引の受け手の事実（owner）を問いで hit・maybe・miss に分け、操作ごとに数える・並べる・書くを決める。
// shape の索引で、World の speed（証明できた）・開いた row の speed（maybe・候補に World）・別の record の old（other）。
func TestFieldActsDecideByTheOwnerClass(t *testing.T) {
	rows, err := ReadIndex(filepath.Join("testdata", "shape-spans-typed.tsv"), Typed)
	must(t, err)
	world := AliasTarget(rows, "World")
	got := map[string]FieldClass{}
	for _, r := range rows {
		if r.Kind == KindLabelSelect {
			got[r.Owner+"#"+r.Sym] = fieldSiteOf(r).Class(world)
		}
	}
	if got["Shape.speedOf#speed"] != ClassHit || got["Shape.speedOfAny#speed"] != ClassMaybe || got["Shape.flagOf#old"] != ClassMiss {
		t.Fatalf("分類 %v", got)
	}
	for op, want := range map[string][2]FieldAct{
		"remove-field":         {ActCount, ActCount},
		"move-fields --finish": {ActCount, ActCount},
		"field-sites":          {ActList, ActUnsure},
		"usages":               {ActList, ActUnsure},
		"field-to-accessor":    {ActRewrite, ActFix},
	} {
		if a := FieldActs[op]; a[ClassHit] != want[0] || a[ClassMaybe] != want[1] || a[ClassMiss] != ActSkip {
			t.Errorf("%s: %v", op, a)
		}
	}
}

// Model は World の別名。--receiver Model と --receiver World は同じ読み書きを並べる（受け手は鎖の終わりで比べる）。
func TestFieldSitesTreatsASynonymAsTheSameAlias(t *testing.T) {
	root := shape(t, nil)
	_, viaWorld := runShape(t, root, nil, "field-sites", "--label", "speed", "--receiver", "World", "--json")
	_, viaModel := runShape(t, root, nil, "field-sites", "--label", "speed", "--receiver", "Model", "--json")
	sites := func(text string) string {
		var r struct {
			Sites, Unsure []FieldSite
		}
		if err := json.Unmarshal([]byte(text[strings.Index(text, "{"):]), &r); err != nil {
			t.Fatalf("%v\n%s", err, text)
		}
		var out []string
		for _, s := range append(r.Sites, r.Unsure...) {
			out = append(out, s.Where())
		}
		return strings.Join(out, " ")
	}
	if a, b := sites(viaWorld), sites(viaModel); a != b || !strings.Contains(a, "src/Shape.flix:33") {
		t.Errorf("World: %s\nModel: %s", a, b)
	}
}

// case の payload を束ねた変数の読み（cursorOf の r#cursor。owner=case:Shape.Panel.Open）は --case Panel.Open の読みに数え、止まる。
func TestRemoveFieldOfACaseCountsTheReadOfTheBoundPayload(t *testing.T) {
	root := shape(t, nil)
	code, text := runShape(t, root, nil, "remove-field", "--label", "cursor", "--case", "Panel.Open")
	if code != 2 || !strings.Contains(text, "直の読み書き 1") || !strings.Contains(text, "src/Shape.flix:40:33") {
		t.Errorf("exit %d\n%s", code, text)
	}
}
