package yarn

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const v2Vocab = `{
  "version": 2,
  "speakers": {"from": [{"doc": "../novel.story.json", "keys": "names"}]},
  "vars": {"from": [{"doc": "../novel.story.json", "keys": "vars"}]},
  "nodes": {"from": [{"doc": "../novel.story.json", "path": "opening"}]},
  "nodeRefs": {"from": [{"doc": "../novel.shots.json", "path": "shots[].node"}]},
  "tags": {},
  "commands": {"bg": {}}
}
`

const v2Story = `{
  "version": 1,
  "opening": "Station",
  "names": {"chinatsu": "千夏"},
  "vars": {"closeness": "親しさ"}
}
`

const v2Shots = `{
  "version": 1,
  "shots": [
    {"name": "nvl", "node": "Station"},
    {"name": "title", "open": "title"},
    {"name": "far", "node": "Far"}
  ]
}
`

// writeGame はゲームの形のフォルダ（project.json・assets/novel.*.json・assets/talk/）を作り、ルートを返す。
func writeGame(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	base := map[string]string{
		"project.json":            "{}",
		"assets/talk/vocab.json":  v2Vocab,
		"assets/novel.story.json": v2Story,
		"assets/novel.shots.json": v2Shots,
	}
	for k, v := range files {
		base[k] = v
	}
	for name, text := range base {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if text == "" {
			continue
		}
		if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func loadV2(t *testing.T, root string) (*Vocab, []string) {
	t.Helper()
	path := filepath.Join(root, "assets", "talk", "vocab.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	v, notes, err := ParseVocab(data, path, root)
	if err != nil {
		t.Fatal(err)
	}
	return v, notes
}

// v2 の from は Doc の鍵（keys）と場所（path・xs[] は配列の全部）から名前を集め、commands は object の鍵を名前にする。
func TestVocabV2CollectsNamesFromDocs(t *testing.T) {
	v, notes := loadV2(t, writeGame(t, nil))
	got := strings.Join([]string{strings.Join(v.Speakers, ","), strings.Join(v.Nodes, ","), strings.Join(v.NodeRefs, ","),
		v.Vars["$closeness"], strings.Join(v.Commands, ",")}, " | ")
	if got != "chinatsu | Station | Station,Far | 親しさ | bg" || len(notes) != 0 {
		t.Errorf("got %q notes %v", got, notes)
	}
}

// v1（version の無い配列の語彙）はそのまま読み、変数の表示名は見ない。
func TestVocabV1StillReads(t *testing.T) {
	v, _, err := ParseVocab([]byte(`{"speakers": ["me"], "nodes": ["A"], "tags": {}, "commands": ["bg"]}`), "vocab.json", ".")
	if err != nil || strings.Join(v.Speakers, ",") != "me" || strings.Join(v.Nodes, ",") != "A" || v.Vars != nil {
		t.Errorf("got %+v %v", v, err)
	}
}

// Doc が指すノード（nodeRefs）が .yarn に無ければ、その Doc の行で止める。
func TestMissingNodeRefStopsAtTheDocLine(t *testing.T) {
	v, _ := loadV2(t, writeGame(t, nil))
	_, ps := BuildProgram([]string{"t.yarn"}, []string{"title: Station\n---\nchinatsu: やあ\n===\n"}, v, "assets/talk/vocab.json")
	if got := messages(ps); !strings.HasPrefix(got, "assets/novel.shots.json:6: Doc が指すノード Far が .yarn に無い") || len(ps) != 1 {
		t.Errorf("got %s", got)
	}
}

// nodeRefs は届かないノードの起点に混ぜない（描き出しの場面のノードを起点にすると、届かない知らせが黙る）。
func TestNodeRefsAreNotRootsForUnreached(t *testing.T) {
	v, _ := loadV2(t, writeGame(t, nil))
	prog, _ := BuildProgram([]string{"t.yarn"}, []string{"title: Station\n---\nhi\n===\ntitle: Far\n---\nhi\n===\n"}, v, "assets/talk/vocab.json")
	if got := messages(Unreached(prog, v)); !strings.Contains(got, "ノード Far はコードからも") {
		t.Errorf("got %s", got)
	}
}

// 表示名の無い変数は知らせるが止めない。
func TestUnnamedVariablesAreNotedNotStopped(t *testing.T) {
	v, _ := loadV2(t, writeGame(t, nil))
	prog, ps := BuildProgram([]string{"t.yarn"}, []string{"title: Station\n---\n<<declare $closeness = 0>>\n<<declare $house = \"a\">>\n<<jump Far>>\n===\ntitle: Far\n---\nhi\n===\n"}, v, "vocab.json")
	got := messages(UnnamedVars(prog, v))
	if len(ps) != 0 || got != `t.yarn:4: 変数 $house に表示名が無い（Doc の vars に "house": "…" を足す）` {
		t.Errorf("problems %s / notes %s", messages(ps), got)
	}
}

// from の Doc が読めない時は 1 行言って、その欄（話し手）の検査だけを飛ばす。
func TestUnreadableDocSkipsOnlyThatCheck(t *testing.T) {
	root := writeGame(t, map[string]string{"assets/talk/vocab.json": strings.Replace(v2Vocab, `"../novel.story.json", "keys": "names"`, `"../gone.json", "keys": "names"`, 1)})
	v, notes := loadV2(t, root)
	_, ps := BuildProgram([]string{"t.yarn"}, []string{"title: Station\n---\nstranger: やあ\n<<nope>>\n===\n"}, v, "vocab.json")
	if len(notes) != 1 || !strings.Contains(notes[0], "speakers の検査を飛ばす") {
		t.Errorf("notes %v", notes)
	}
	if got := messages(ps); strings.Contains(got, "話し手") || !strings.Contains(got, "<<nope>>") {
		t.Errorf("got %s", got)
	}
}

// yarn check に Doc を渡すと、その Doc を from に書いた語彙のフォルダを検査する（Doc だけの直しでも台本の名前を見る）。
func TestCheckWithADocChecksTheVocabFolderThatReadsIt(t *testing.T) {
	root := writeGame(t, map[string]string{"assets/talk/main.yarn": "title: Station\n---\nchinatsu: やあ\n===\n"})
	var out, errOut strings.Builder
	code := Run(&out, &errOut, root, []string{"check", "assets/novel.shots.json"})
	if code != 1 || !strings.Contains(out.String(), "Doc が指すノード Far が .yarn に無い") {
		t.Errorf("code %d: %s%s", code, out.String(), errOut.String())
	}
}

// 語彙が from で読まない Doc（v1 のゲーム）を渡しても何もせずに通る。
func TestCheckWithADocNoVocabReadsPasses(t *testing.T) {
	root := writeGame(t, map[string]string{
		"assets/talk/vocab.json": `{"speakers": ["me"], "nodes": ["A"], "tags": {}, "commands": []}`,
		"assets/talk/main.yarn":  "title: Broken\n---\nwho: やあ\n===\n",
	})
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, root, []string{"check", "assets/novel.story.json"}); code != 0 {
		t.Errorf("code %d: %s%s", code, out.String(), errOut.String())
	}
}
