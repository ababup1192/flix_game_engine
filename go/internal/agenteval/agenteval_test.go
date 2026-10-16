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
		{"「ない」だけでは打ち消さない", "足りない所は let _ = Log.warn で知らせる", true},
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
