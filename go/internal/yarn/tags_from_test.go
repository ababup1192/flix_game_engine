package yarn

import (
	"strings"
	"testing"
)

const promptsVocab = `{
  "version": 2,
  "nodes": ["Station"],
  "tags": {
    "act": ["up", "down", "tap"],
    "at": {"from": [{"doc": "../novel.prompts.json", "keys": "targets"}]},
    "mute": []
  }
}
`

const promptsDoc = `{"version": 1, "targets": {"gem": {}, "bone": {}}}`

func promptProblems(t *testing.T, files map[string]string, body string) ([]Problem, []string) {
	t.Helper()
	root := writeGame(t, files)
	v, notes := loadV2(t, root)
	_, ps := BuildProgram([]string{"t.yarn"}, []string{"title: Station\n---\n" + body + "\n===\n"}, v, "vocab.json")
	return ps, notes
}

func promptFiles() map[string]string {
	return map[string]string{"assets/talk/vocab.json": promptsVocab, "assets/novel.prompts.json": promptsDoc}
}

// tags に from を書いたキーは、Doc の鍵にある値を受ける。
func TestTagValueFromTheDocIsAccepted(t *testing.T) {
	ps, _ := promptProblems(t, promptFiles(), "-> 宝石 #act:tap #at:gem\n    ok")
	if len(ps) != 0 {
		t.Errorf("got %s", messages(ps))
	}
}

// Doc に無い値は、近い名前の案を付けて止める。
func TestTagValueMissingFromTheDocStops(t *testing.T) {
	ps, _ := promptProblems(t, promptFiles(), "-> 宝石 #act:tap #at:gem\n    ok\n-> 骨 #act:tap #at:bnoe\n    ok")
	if got := messages(ps); !strings.Contains(got, `タグ #at の値 "bnoe" が Doc に無い（もしかして: bone）`) {
		t.Errorf("got %s", got)
	}
}

// from のタグは値が要る。
func TestTagFromTheDocNeedsAValue(t *testing.T) {
	ps, _ := promptProblems(t, promptFiles(), "-> 宝石 #act:tap #at\n    ok")
	if got := messages(ps); !strings.Contains(got, "タグ #at に値が要る") {
		t.Errorf("got %s", got)
	}
}

// Doc を読めない時はそのタグの値を照らさず、知らせを 1 行出す。
func TestTagFromAnUnreadableDocIsSkipped(t *testing.T) {
	files := map[string]string{"assets/talk/vocab.json": promptsVocab}
	ps, notes := promptProblems(t, files, "-> 宝石 #act:tap #at:anything\n    ok")
	if len(ps) != 0 || len(notes) != 1 || !strings.Contains(notes[0], "tags の at") {
		t.Errorf("problems %s notes %v", messages(ps), notes)
	}
}

// 決まった一覧のタグ（配列）は今までどおり照らす。
func TestFixedTagValuesAreStillChecked(t *testing.T) {
	ps, _ := promptProblems(t, promptFiles(), "-> 上へ #act:upp\n    ok")
	if got := messages(ps); !strings.Contains(got, `タグ #act の値 "upp" を知らない`) {
		t.Errorf("got %s", got)
	}
}
