package yarn

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testdata = "../../../testdata/yarn"

func buildText(t *testing.T, text string, vocab *Vocab) (*Program, []Problem) {
	t.Helper()
	return BuildProgram([]string{"t.yarn"}, []string{text}, vocab, "vocab.json")
}

func messages(ps []Problem) string {
	var out []string
	for _, p := range ps {
		out = append(out, p.String())
	}
	return strings.Join(out, "\n")
}

// ── 公式のテストケース ──

// 公式の TestCases の .yarn は、部分集合に収まる 4 本がそのまま通り、宣言の無い変数を使う 1 本は行番号つきで止まり、
// 残りは部分集合の外の構文を含んで行番号つきの「読まない」で止まる。
func TestOfficialFilesAreReadOrRefusedWithLineNumbers(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(testdata, "official", "*.yarn"))
	if len(files) != 35 {
		t.Fatalf("公式の .yarn は 35 本のはず: %d", len(files))
	}
	readable := map[string]bool{"Smileys.yarn": true, "VariableStorage.yarn": true, "VeryLargeFileOfVariables.yarn": true, "VisitCount.yarn": true}
	undeclared := map[string]bool{"Indentation.yarn": true}
	for _, f := range files {
		name := filepath.Base(f)
		data, _ := os.ReadFile(f)
		_, ps := BuildProgram([]string{name}, []string{string(data)}, nil, "")
		stopped := 0
		for _, p := range ps {
			if p.Line > 0 && (p.Unsupported || undeclared[name] && strings.Contains(p.Msg, "宣言していない変数")) {
				stopped++
			}
		}
		switch {
		case readable[name] && len(ps) > 0:
			t.Errorf("%s が読めない:\n%s", name, messages(ps))
		case !readable[name] && stopped == 0:
			t.Errorf("%s が止まらない:\n%s", name, messages(ps))
		}
	}
}

// 公式の ParseFailures は、どれも行番号つきの知らせで止まる（読まない構文か、公式と同じ誤り）。
func TestOfficialParseFailuresAllStopWithLineNumbers(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(testdata, "official", "ParseFailures", "*.yarn"))
	if len(files) != 33 {
		t.Fatalf("ParseFailures は 33 本のはず: %d", len(files))
	}
	for _, f := range files {
		data, _ := os.ReadFile(f)
		_, ps := BuildProgram([]string{filepath.Base(f)}, []string{string(data)}, nil, "")
		if len(ps) == 0 || ps[0].Line <= 0 {
			t.Errorf("%s が行番号つきで止まらない: %v", filepath.Base(f), ps)
		}
	}
}

// engine_world のテストが読む木（抜き出した部分集合と YarnRunner のシナリオ）は .yarn から作り直した物と同じ。
func TestSubsetJsonIsFresh(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(testdata, "subset", "*.yarn"))
	runner, _ := filepath.Glob(filepath.Join(testdata, "runner", "*.yarn"))
	files = append(files, runner...)
	if len(files) < 2 {
		t.Fatal("subset と runner に .yarn が無い")
	}
	for _, f := range files {
		data, _ := os.ReadFile(f)
		prog, ps := BuildProgram([]string{filepath.Base(f)}, []string{string(data)}, nil, "")
		if len(ps) > 0 {
			t.Errorf("%s が読めない:\n%s", f, messages(ps))
			continue
		}
		want, _ := Encode(prog)
		got, _ := os.ReadFile(strings.TrimSuffix(f, ".yarn") + ".yarn.json")
		if string(got) != string(want) {
			t.Errorf("%s.json がずれている（bin/fge yarn build %s --no-vocab --out %s.json）", f, filepath.Base(f), filepath.Base(f))
		}
	}
}

// ── 字下げと選択肢 ──

// -> の行より深い行はその選択肢の中身になり、浅い行で選択肢の後ろへ戻る。
func TestIndentedLinesAfterAnOptionBecomeItsBody(t *testing.T) {
	prog, ps := buildText(t, "title: A\n---\n-> x\n    in x\n-> y\nafter\n===\n", nil)
	if len(ps) > 0 {
		t.Fatal(messages(ps))
	}
	body := prog.Nodes[0].Body
	got := []string{body[0].Kind, body[0].Options[0].Body[0].Text, body[0].Options[1].Text, body[1].Text}
	want := []string{"options", "in x", "y", "after"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("got %v want %v", got, want)
	}
}

// -> の直後の空行は選択肢のまとまりを終える（続く -> は別のまとまり）。
func TestBlankLineAfterAnOptionEndsTheGroup(t *testing.T) {
	prog, _ := buildText(t, "title: A\n---\n-> x\n\n-> y\n===\n", nil)
	if n := len(prog.Nodes[0].Body); n != 2 {
		t.Errorf("まとまりは 2 つのはず: %d", n)
	}
}

// ── 行 ──

// エスケープしていない最初の : の左が話し手。\: は字のまま。
func TestSpeakerIsBeforeTheFirstUnescapedColon(t *testing.T) {
	prog, _ := buildText(t, "title: A\n---\ngirl: やあ: 元気？\n時刻は 9\\:12\n===\n", nil)
	b := prog.Nodes[0].Body
	got := []string{b[0].Speaker, b[0].Text, b[1].Speaker, b[1].Text}
	want := []string{"girl", "やあ: 元気？", "", "時刻は 9:12"}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("got %q want %q", got, want)
	}
}

// 読まない構文は行番号と「代わりに」を付けて断る。
func TestRefusedSyntaxNamesTheLineAndTheAlternative(t *testing.T) {
	_, ps := buildText(t, "title: A\n---\nhi\n<<once>>\n===\n", nil)
	if len(ps) != 1 || ps[0].Line != 4 || !ps[0].Unsupported || !strings.Contains(ps[0].Msg, "代わりに") {
		t.Errorf("got %v", ps)
	}
}

// ── 語彙 ──

func testVocab() *Vocab {
	return &Vocab{
		Speakers: []string{"girl", "avatar"},
		Nodes:    []string{"op_desk"},
		Tags:     map[string][]string{"face": {"happy", "sad"}, "suspect": {}},
	}
}

// 語彙に無い話し手・タグの値・コマンドと、コードが開くのに .yarn に無いノードを、行番号と近い名前の案で止める。
func TestVocabularyMismatchesStopWithSuggestions(t *testing.T) {
	_, ps := buildText(t, "title: op_dsk\n---\ngril: やあ #face:hapy\n-> 疑う #suspect:yes\n<<shake>>\n===\n", testVocab())
	got := messages(ps)
	for _, want := range []string{
		"t.yarn:3: 知らない話し手 gril（もしかして: girl）",
		"t.yarn:3: タグ #face の値 \"hapy\" を知らない（もしかして: happy）",
		"t.yarn:4: タグ #suspect は値を取らない",
		"t.yarn:5: 知らないコマンド <<shake>>",
		"vocab.json:1: コードが開くノード op_desk が .yarn に無い（もしかして: op_dsk）",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("%q が無い:\n%s", want, got)
		}
	}
}

// <<wait>> は 0 以上の秒を 1 つだけ取る。
func TestWaitTakesOneNonNegativeNumber(t *testing.T) {
	_, ps := buildText(t, "title: op_desk\n---\n<<wait 0.5>>\n<<wait>>\n<<wait -1>>\n===\n", testVocab())
	lines := []int{}
	for _, p := range ps {
		lines = append(lines, p.Line)
	}
	if len(lines) != 2 || lines[0] != 4 || lines[1] != 5 {
		t.Errorf("4 行目と 5 行目だけのはず: %v", ps)
	}
}

// ── 変数・条件・{式} ──

func onlyBody(t *testing.T, text string) []*Stmt {
	t.Helper()
	prog, ps := buildText(t, text, nil)
	if len(ps) > 0 {
		t.Fatal(messages(ps))
	}
	return prog.Nodes[0].Body
}

// <<declare>> は本文に残らず、木の頭の変数の一覧に型ごとの初めの値で載る。
func TestDeclareGoesToTheProgramVariables(t *testing.T) {
	prog, ps := buildText(t, "title: A\n---\n<<declare $n = -2>>\n<<declare $b to true>>\n<<declare $s = \"x\">>\nhi\n===\n", nil)
	if len(ps) > 0 {
		t.Fatal(messages(ps))
	}
	var got []string
	for _, v := range prog.Variables {
		got = append(got, fmt.Sprintf("%s:%s:%d", v.Name, v.Value.Type, v.Line))
	}
	want := "$n:Number:3 $b:Bool:4 $s:String:5"
	if strings.Join(got, " ") != want || len(prog.Nodes[0].Body) != 1 {
		t.Errorf("got %v body %d", got, len(prog.Nodes[0].Body))
	}
}

// <<set $x += 式>> は $x + 式 を入れる set になる。
func TestCompoundSetBecomesABinaryExpression(t *testing.T) {
	body := onlyBody(t, "title: A\n---\n<<declare $n = 0>>\n<<set $n += 2>>\n===\n")
	got, _ := json.Marshal(body[0])
	want := `{"kind":"set","line":4,"name":"$n","expr":{"kind":"+","args":[{"kind":"variable","name":"$n"},{"kind":"value","value":2}]}}`
	if string(got) != want {
		t.Errorf("got %s", got)
	}
}

// 式の優先順位は公式と同じ（* は + より強く、比較は算術より弱い）。
func TestExpressionPrecedenceFollowsTheOfficialGrammar(t *testing.T) {
	x, err := ParseExpr("1 + 2 * 3 == 7 and not false")
	if err != nil {
		t.Fatal(err)
	}
	got, _ := json.Marshal(x)
	want := `{"kind":"and","args":[{"kind":"==","args":[{"kind":"+","args":[{"kind":"value","value":1},{"kind":"*","args":[{"kind":"value","value":2},{"kind":"value","value":3}]}]},{"kind":"value","value":7}]},{"kind":"not","args":[{"kind":"value","value":false}]}]}`
	if string(got) != want {
		t.Errorf("got %s", got)
	}
}

// <<if>>〜<<elseif>>〜<<else>>〜<<endif>> は 1 つの if の文になり、中に選択肢や jump を置ける。
func TestIfBlockHoldsClausesWithOptionsAndJumps(t *testing.T) {
	body := onlyBody(t, "title: A\n---\n<<declare $n = 0>>\n<<if $n > 1>>\n    big\n<<elseif $n == 1>>\n-> a\n    <<jump A>>\n-> b\n<<else>>\nsmall\n<<endif>>\nafter\n===\n")
	if len(body) != 2 || body[0].Kind != "if" || body[1].Text != "after" {
		t.Fatalf("got %d 文", len(body))
	}
	c := body[0].Clauses
	got := []string{fmt.Sprint(len(c)), c[0].Body[0].Text, c[1].Body[0].Kind, c[1].Body[0].Options[0].Body[0].Kind, fmt.Sprint(c[2].Condition == nil), c[2].Body[0].Text}
	if strings.Join(got, "|") != "3|big|options|jump|true|small" {
		t.Errorf("got %v", got)
	}
}

// 選択肢の中で始めた <<if>> は、選択肢の字下げの中で閉じる。
func TestIfInsideAnOptionBody(t *testing.T) {
	body := onlyBody(t, "title: A\n---\n<<declare $n = 0>>\n-> a\n    <<if $n == 0>>\n        zero\n    <<endif>>\n    tail\n-> b\nafter\n===\n")
	opt := body[0].Options[0]
	if len(opt.Body) != 2 || opt.Body[0].Kind != "if" || opt.Body[1].Text != "tail" || body[1].Text != "after" {
		t.Errorf("got %+v", opt.Body)
	}
}

// 選択肢の行末の <<if>> は条件になり、後ろのタグも読む。
func TestOptionConditionComesBeforeTags(t *testing.T) {
	body := onlyBody(t, "title: A\n---\n<<declare $ok = true>>\n-> go <<if $ok>> #suspect\n-> stay\n===\n")
	o := body[0].Options
	if o[0].Text != "go" || o[0].Condition == nil || o[0].Condition.Name != "$ok" || len(o[0].Tags) != 1 || o[1].Condition != nil {
		t.Errorf("got %+v", o[0])
	}
}

// {式} の行は、話し手を分けた後の字と式の切れの並びを持ち、Text は書いたとおりの字を残す。
func TestInlineExpressionsSplitIntoParts(t *testing.T) {
	body := onlyBody(t, "title: A\n---\n<<declare $n = 3>>\ngirl: 切符は {$n} 枚 \\{ok\\}\n===\n")
	got, _ := json.Marshal(body[0])
	want := `{"kind":"line","line":4,"speaker":"girl","text":"切符は {$n} 枚 {ok}","parts":[{"text":"切符は "},{"expr":{"kind":"variable","name":"$n"}},{"text":" 枚 {ok}"}]}`
	if string(got) != want {
		t.Errorf("got %s", got)
	}
}

// 変数も条件も {式} も無い木は版 1 のまま書く（足す前に組んだ dialogue.json とずれない）。使えば版 2。
func TestVersionIsOneUnlessTheTreeUsesVariables(t *testing.T) {
	plain, _ := buildText(t, "title: A\n---\nhi\n===\n", nil)
	vars, _ := buildText(t, "title: A\n---\n<<declare $n = 0>>\nhi\n===\n", nil)
	if plain.Version != 1 || vars.Version != 2 {
		t.Errorf("got %d %d", plain.Version, vars.Version)
	}
}

// 宣言の無い変数・型の食い違い・無いノードの visited・宣言の重なりは、行番号つきで止める。
func TestTypeErrorsStopWithLineNumbers(t *testing.T) {
	_, ps := buildText(t, strings.Join([]string{
		"title: A", "---",
		"<<declare $n = 0>>",              // 3
		"<<declare $flag = false>>",       // 4
		"<<set $m to 1>>",                 // 5
		"<<set $n to true>>",              // 6
		"<<if $n>>",                       // 7
		"<<endif>>",                       // 8
		"n is {$n + \"x\"}",               // 9
		"-> go <<if visited(\"B\")>>",     // 10
		"<<if visited_count(\"A\") < 1>>", // 11
		"<<endif>>",                       // 12
		"<<declare $n = 1>>",              // 13
		"<<if $flg>>",                     // 14
		"<<endif>>",                       // 15
		"===", ""}, "\n"), nil)
	got := messages(ps)
	for _, want := range []string{
		"t.yarn:5: 宣言していない変数 $m",
		"t.yarn:6: <<set $n>>（Number の変数） は Number の式を書く（Bool になっている）",
		"t.yarn:7: <<if>> は Bool の式を書く（Number になっている）",
		"t.yarn:9: {} の式: + の両側は数どうしか文字列どうし（Number + String になっている）",
		"t.yarn:10: 選択肢の <<if>>: visited(\"B\") のノード B が無い",
		"t.yarn:13: 変数 $n の <<declare>> が 2 つある（先の物は t.yarn:3）",
		"t.yarn:14: <<if>>: 宣言していない変数 $flg（もしかして: $flag）",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("%q が無い:\n%s", want, got)
		}
	}
	if strings.Contains(got, "t.yarn:11") {
		t.Errorf("11 行目は通るはず:\n%s", got)
	}
}

// <<if>> の組み立ての誤り（閉じ忘れ・対の無い <<endif>>・<<else if>>）は行番号つきで止める。
func TestMalformedIfBlocksStopWithLineNumbers(t *testing.T) {
	_, ps := buildText(t, "title: A\n---\n<<endif>>\n<<if true>>\n<<else if true>>\n<<endif>>\n-> a\n    <<if true>>\n-> b\n===\n", nil)
	got := messages(ps)
	for _, want := range []string{
		"t.yarn:3: 対の <<if>> が無い <<endif>>",
		"t.yarn:5: <<else if>> は <<elseif 式>> と書く",
		"t.yarn:8: <<if>> が <<endif>> で閉じていない",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("%q が無い:\n%s", want, got)
		}
	}
}

// 公式の別の綴り・自作の関数・and と or の括弧なしの混ぜ書き・計算した初めの値は、行番号と代わりの書き方で止める。
func TestRefusedExpressionsNameTheAlternative(t *testing.T) {
	_, ps := buildText(t, strings.Join([]string{
		"title: A", "---",
		"<<declare $a = true>>",  // 3
		"<<if $a && true>>",      // 4
		"<<endif>>",              // 5
		"{dice(6)}",              // 6
		"<<if $a or $a and $a>>", // 7
		"<<endif>>",              // 8
		"<<declare $b = 1 + 1>>", // 9
		"girl: hi <<if $a>>",     // 10
		"===", ""}, "\n"), nil)
	got := messages(ps)
	for _, want := range []string{
		"t.yarn:4: <<if>> の式: && は読まない（and と書く）",
		"t.yarn:6: {dice(6)} の式: 関数 dice は読まない",
		"t.yarn:7: <<if>> の式: and と or を括弧なしで混ぜない",
		"t.yarn:9: 読まない: <<declare>> の値に変数や計算",
		"t.yarn:10: 読まない: 台詞の行の後ろの <<…>>",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("%q が無い:\n%s", want, got)
		}
	}
}
