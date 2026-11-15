package yarn

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

type argSamples struct {
	Commands map[string]json.RawMessage `json:"commands"`
	Cases    []struct {
		Cmd  string   `json:"cmd"`
		Args []string `json:"args"`
		OK   bool     `json:"ok"`
		Why  string   `json:"why"`
	} `json:"cases"`
}

func loadArgSamples(t *testing.T) (argSamples, map[string]*CommandSpec) {
	t.Helper()
	data, err := os.ReadFile("testdata/command-args.json")
	if err != nil {
		t.Fatal(err)
	}
	var s argSamples
	if err := json.Unmarshal(data, &s); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(s.Commands)
	_, specs, err := commandsOf(raw)
	if err != nil {
		t.Fatal(err)
	}
	return s, specs
}

// 見本（engine_world の YarnCommands.parse と同じ物）の全部の行で、受けるか断るかが見本と同じ。
func TestArgSamplesMatchTheRuntimeParse(t *testing.T) {
	s, specs := loadArgSamples(t)
	if len(s.Cases) < 40 {
		t.Fatalf("見本が %d 行しか読めない", len(s.Cases))
	}
	for _, c := range s.Cases {
		msg := CheckArgs(c.Cmd, specs[c.Cmd], c.Args)
		if (msg == "") != c.OK {
			t.Errorf("<<%s %s>>: ok=%v のはずが %q（%s）", c.Cmd, strings.Join(c.Args, " "), c.OK, msg, c.Why)
		}
	}
}

// 知らない鍵には近い鍵を添える。
func TestUnknownArgKeySuggestsTheNearKey(t *testing.T) {
	_, specs := loadArgSamples(t)
	if msg := CheckArgs("overlay", specs["overlay"], []string{"0.5", "colr=white"}); !strings.Contains(msg, "もしかして: color") {
		t.Errorf("got %q", msg)
	}
}

const refVocab = `{
  "version": 2,
  "speakers": {"from": [{"doc": "../novel.story.json", "keys": "names"}]},
  "nodes": ["Station"],
  "tags": {},
  "commands": {
    "bg": {"summary": "背景", "params": [{"name": "photo", "type": "name", "pos": 1, "req": true, "ref": {"from": [{"doc": "../novel.backdrops.json", "keys": "photos"}]}}]},
    "audio": {"summary": "音", "params": [{"name": "volume", "type": "num", "min": 0, "max": 1, "orNames": {"from": [{"doc": "../novel.backdrops.json", "keys": "volumes"}]}}]},
    "clear": {}
  }
}
`

const refBackdrops = `{"version": 1, "photos": {"station": {}, "river": {}}, "volumes": {"loud": 1}}`

// ref の Doc の鍵に無い名前は、近い名前を添えて build で止める（実行時の Err を待たない）。
func TestRefNameMissingFromTheDocStops(t *testing.T) {
	root := writeGame(t, map[string]string{"assets/talk/vocab.json": refVocab, "assets/novel.backdrops.json": refBackdrops})
	v, notes := loadV2(t, root)
	_, ps := BuildProgram([]string{"t.yarn"}, []string{"title: Station\n---\n<<bg statoin>>\n<<bg river>>\n<<audio volume=quiet>>\n<<audio volume=loud>>\n<<clear anything goes>>\n===\n"}, v, "vocab.json")
	got := messages(ps)
	if len(notes) != 0 || len(ps) != 2 || !strings.Contains(got, "t.yarn:3: <<bg>> の photo の statoin が Doc に無い（もしかして: station）") ||
		!strings.Contains(got, "t.yarn:5: <<audio>> の volume の quiet が Doc に無い") {
		t.Errorf("notes %v / got %s", notes, got)
	}
}

// ref の Doc が読めない時は 1 行言って、名前は照らさない（引数の型の検査は続ける）。
func TestUnreadableRefDocSkipsOnlyTheNames(t *testing.T) {
	root := writeGame(t, map[string]string{"assets/talk/vocab.json": refVocab})
	v, notes := loadV2(t, root)
	_, ps := BuildProgram([]string{"t.yarn"}, []string{"title: Station\n---\n<<bg statoin>>\n<<bg>>\n===\n"}, v, "vocab.json")
	if len(notes) != 1 || !strings.Contains(notes[0], "（commands の audio の volume・commands の bg の photo）") {
		t.Errorf("notes %v", notes)
	}
	if got := messages(ps); len(ps) != 1 || !strings.Contains(got, "<<bg>> に photo が要る") {
		t.Errorf("got %s", got)
	}
}

// yarn check に ref の Doc を渡すと、その Doc を ref に書いた語彙のフォルダを検査する。
func TestDocsOfIncludesRefDocs(t *testing.T) {
	root := writeGame(t, map[string]string{"assets/talk/vocab.json": refVocab, "assets/novel.backdrops.json": refBackdrops,
		"assets/talk/main.yarn": "title: Station\n---\n<<bg statoin>>\n===\n"})
	var out, errOut strings.Builder
	code := Run(&out, &errOut, root, []string{"check", "assets/novel.backdrops.json"})
	if code != 1 || !strings.Contains(out.String(), "statoin が Doc に無い") {
		t.Errorf("code %d: %s%s", code, out.String(), errOut.String())
	}
}

// "…" は空白を含んでも 1 つの引数（" は残す）。<<set>> と <<declare>> の文字列には触れない。閉じていなければ止める。
func TestQuotedCommandArgsStayTogether(t *testing.T) {
	body := onlyBody(t, "title: A\n---\n<<declare $x = \"a  b\">>\n<<set $x to \"c  d\">>\n<<say \"two  words\" note=\"x y\" plain>>\n===\n")
	if len(body) != 2 || body[0].Expr == nil || body[0].Expr.Value.String != "c  d" {
		t.Fatalf("got %+v", body)
	}
	if got := strings.Join(body[1].Args, "|"); got != `"two  words"|note="x y"|plain` {
		t.Errorf("args %q", got)
	}
	_, ps := buildText(t, "title: A\n---\n<<say \"open>>\n===\n", nil)
	if got := messages(ps); len(ps) != 1 || !strings.Contains(got, `t.yarn:3: "…" が閉じていない`) {
		t.Errorf("got %s", got)
	}
}

// 語彙の表そのものの誤り（知らない型・3 つ目の位置）は語彙が壊れているのと同じく止める。
func TestBrokenArgTableStops(t *testing.T) {
	for _, body := range []string{
		`{"bg": {"params": [{"name": "a", "type": "colour"}]}}`,
		`{"bg": {"params": [{"name": "a", "type": "name", "pos": 1}, {"name": "b", "type": "name", "pos": 3}]}}`,
		`{"bg": {"params": [{"name": "a", "type": "num"}]}}`,
		`{"bg": {"params": [{"name": "a", "type": "choice"}]}}`,
		`{"bg": {"params": [{"name": "a", "type": "ease"}]}}`,
		`{"bg": {"params": [{"name": "a", "type": "choice", "values": ["x"], "default": "y"}]}}`,
		`{"bg": {"params": [{"name": "a", "type": "num", "min": 0, "max": 1, "default": "2"}]}}`,
	} {
		if _, _, err := ParseVocab([]byte(`{"version": 2, "commands": `+body+`}`), "vocab.json", "."); err == nil {
			t.Errorf("止まらない: %s", body)
		}
	}
}

// from の行き先はあるが空（"vars": {}・"shots": []）の時は知らせない（綴り違いだけを知らせる）。
func TestEmptyButPresentFromIsSilent(t *testing.T) {
	root := writeGame(t, map[string]string{
		"assets/novel.story.json": `{"version": 1, "opening": "Station", "names": {"me": "私"}, "vars": {}}`,
		"assets/novel.shots.json": `{"version": 1, "shots": []}`,
	})
	v, notes := loadV2(t, root)
	if len(notes) != 0 || v.skip["vars"] || v.skip["nodeRefs"] {
		t.Errorf("notes %v skip %v", notes, v.skip)
	}
}

// path で同じ名前が何度も拾われても、近い名前の案は 1 度ずつ。
func TestRefHintListsEachNameOnce(t *testing.T) {
	vocab := strings.Replace(refVocab, `{"doc": "../novel.backdrops.json", "keys": "photos"}`, `{"doc": "../novel.backdrops.json", "path": "goods[].shop"}`, 1)
	root := writeGame(t, map[string]string{"assets/talk/vocab.json": vocab,
		"assets/novel.backdrops.json": `{"goods": [{"shop": "mine"}, {"shop": "mine"}, {"shop": "mine"}], "volumes": {}}`})
	v, _ := loadV2(t, root)
	_, ps := BuildProgram([]string{"t.yarn"}, []string{"title: Station\n---\n<<bg mini>>\n===\n"}, v, "vocab.json")
	if got := messages(ps); !strings.Contains(got, "（もしかして: mine）") {
		t.Errorf("got %s", got)
	}
}

// 引数を取らないコマンドに引数を書くと、取らない事を言う。
func TestCommandWithoutParamsSaysSo(t *testing.T) {
	if msg := CheckArgs("inn", &CommandSpec{Params: []ParamSpec{}}, []string{"tonight"}); msg != "<<inn>> は引数を取らない" {
		t.Errorf("got %q", msg)
	}
}
