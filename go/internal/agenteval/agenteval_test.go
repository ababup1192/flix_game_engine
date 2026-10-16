package agenteval

import (
	"os"
	"regexp"
	"testing"
)

// 減点の語は「選んだ」行だけで数え、打ち消しの行・使わない物の一覧の中は数えない。
func TestAdoptedReadsNegationAndAvoidLists(t *testing.T) {
	re := regexp.MustCompile(`let\s+_\s*=`)
	cases := []struct {
		name   string
		answer string
		want   bool
	}{
		{"選んだ行", "{\n  \"tools\": [\"let _ = Log.warn(x)\"]\n}", true},
		{"打ち消しの行", "`let _ =` では呼ばない", false},
		{"使わない物の配列", "{\n  \"avoid\": [\n    \"let _ = Log.warn\"\n  ],\n  \"tools\": [\"Log.warnThen\"]\n}", false},
		{"1 行の使わない物の配列", "{\"avoid\": [\"let _ = Log.warn\"]}", false},
		{"使わない物の配列の中のオブジェクトが閉じた後", "\"avoid\": [\n  {\n    \"x\": \"a\"\n  },\n  \"let _ = Log.warn\"\n]", false},
		{"配列が閉じた後の選んだ行", "\"avoid\": [\n  \"a\"\n],\n\"tools\": [\n  \"let _ = Log.warn\"\n]", true},
		{"鍵の名前の一部に old が入るだけ", "\"holder\": [\n  \"let _ = Log.warn\"\n]", true},
		{"lint が止める物の説明", "{\"name\": \"bin/fge forbid\", \"catches\": \"let _ = Log.warn\"}", false},
		{"「ない」だけでは打ち消さない", "足りない所は let _ = Log.warn で知らせる", true},
		// 0.35.21 の 3 回流しで、正しい答えが減点された 2 つの形。
		{"使えない", "知らせは Log.fellBackThen で出す（純粋なので let _ = Log.warn は使えない）", false},
		{"読んだファイルの一覧で探した語", "\"files_read\": [\n  \"engine を grep（let _ = の出どころ）\"\n]", false},
		{"読んだファイルの一覧（日本語の鍵）", "\"読んだファイル\": [\n  \"let _ = を探した\"\n]", false},
		// 0.35.22 の 3 回流しで、正しい答えが減点された形。
		{"頼み方の文どおりの鍵（判断のために読んだファイル）", "\"判断のために読んだファイル\": [\n  \"src/A.flix（let _ = を使っている今の実装）\"\n]", false},
		{"lint が見る物の説明", "\"checks\": \"let _ = で知らせを捨てていないか\"", false},
		{"手で掛けない", "\"why\": \"let _ = を手で掛けない\"", false},
		{"消す", "残っている let _ = Log.warn を消す", false},
		{"呼ぶと鳴る", "\"why\": \"let _ = を呼ぶと鳴る\"", false},
	}
	for _, c := range cases {
		if got := adopted(re, c.answer); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

// 別のお題ファイルで id が重なると、記録が上書きされるので読み込みで止める。
func TestDuplicateIDAcrossSuitesIsAnError(t *testing.T) {
	dir := t.TempDir()
	body := `{"version":1,"tasks":[{"id":"a","prompt":"p","expect":[{"re":"x"}]}]}`
	a, b := dir+"/a.json", dir+"/b.json"
	for _, p := range []string{a, b} {
		if err := writeFile(p, body); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := loadSuites([]string{a, b}); err == nil {
		t.Fatal("want error")
	}
}

func writeFile(p, body string) error { return os.WriteFile(p, []byte(body), 0o644) }

// 記録 1 本から、答え・モデル・トークン（キャッシュ分も込み）・読んだファイルを取り、期待の語と減点の語を数える。
func TestScoreReadsStreamJSON(t *testing.T) {
	raw := `{"type":"system","subtype":"init","model":"claude-x"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/g/AGENTS.md"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep -n topLayer src/View.flix"}}]}}
{"type":"result","result":"ZStack.topLayer で出す\nzIndex = 900 にする","num_turns":3,"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":5}}
`
	j := job{"engine", Task{ID: "t",
		Expect: []Pattern{{Re: `topLayer`}, {Re: `UiTooltip`}},
		Avoid:  []Pattern{{Re: `zIndex\s*=\s*\d{3}`}}}}
	r := score(j, []byte(raw))
	if r.Model != "claude-x" || r.InputTokens != 60 || r.Turns != 3 || len(r.FilesRead) != 2 {
		t.Errorf("数え違い: %+v", r)
	}
	// (当たり 1 − 減点 1) / 期待 2 = 0 点
	if r.Hit != 1 || r.Penalty != 1 || r.Points() != 0 {
		t.Errorf("hit %d penalty %d points %d", r.Hit, r.Penalty, r.Points())
	}
}
