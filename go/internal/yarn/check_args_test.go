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
	for _, args := range [][]string{{"tonight"}, {"at=tonight"}} {
		if msg := CheckArgs("inn", &CommandSpec{Params: []ParamSpec{}}, args); msg != "<<inn>> は引数を取らない" {
			t.Errorf("%v: got %q", args, msg)
		}
	}
}

// 小さい数・大きい数・並びの既定の値（engine_world が指数を使わずに書く形）は表の誤りにしない。
func TestPlainNumberDefaultsAreAccepted(t *testing.T) {
	body := `{"tick": {"params": [{"name": "time", "type": "time", "default": "0.0001"},
		{"name": "tiny", "type": "num", "min": 0, "max": 0.001, "default": "0.0005"},
		{"name": "huge", "type": "num", "min": 0, "max": 100000000, "default": "20000000.0"},
		{"name": "steps", "type": "num", "min": 0, "max": 9, "list": true, "default": "1.0,2.5"}]}}`
	if _, _, err := ParseVocab([]byte(`{"version": 2, "commands": `+body+`}`), "vocab.json", "."); err != nil {
		t.Errorf("err %v", err)
	}
	if _, _, err := ParseVocab([]byte(`{"version": 2, "commands": {"a": {"params": [{"name": "t", "type": "time", "default": "1.0E-4"}]}}}`), "vocab.json", "."); err == nil {
		t.Errorf("指数の形の既定を通した")
	}
}

const castVocab = `{
  "version": 2,
  "nodes": ["Station"],
  "commands": {
    "show": {"params": [
      {"name": "who", "type": "name", "pos": 1, "req": true, "orWords": ["all"], "ref": {"from": [{"doc": "../novel.cast.json", "keys": "cast"}]}},
      {"name": "face", "type": "name", "pos": 2, "scope": "who", "ref": {"from": [{"doc": "../novel.cast.json", "path": "cast.*.faces[]"}]}}]},
    "fx": {"params": [
      {"name": "on", "type": "marker", "req": true, "ref": {"from": [{"doc": "../novel.cast.json", "keys": "cast.*.markers"}, {"doc": "../novel.cast.json", "keys": "props.*.markers"}]}}]}
  }
}
`

const castDoc = `{"version": 1,
  "cast": {"toma": {"faces": ["smile", "angry"], "markers": {"mouth": {}}}, "rin": {"faces": ["sad"]}},
  "props": {"whale": {"markers": {"mouth": {}, "tail": {}}}, "lamp": {}}}`

func castVocabOf(t *testing.T, vocab string) (*Vocab, []string) {
	t.Helper()
	root := writeGame(t, map[string]string{"assets/talk/vocab.json": vocab, "assets/novel.cast.json": castDoc})
	return loadV2(t, root)
}

func castProblems(t *testing.T, body string) []Problem {
	t.Helper()
	v, notes := castVocabOf(t, castVocab)
	if len(notes) != 0 {
		t.Fatalf("notes %v", notes)
	}
	_, ps := BuildProgram([]string{"t.yarn"}, []string{"title: Station\n---\n" + body + "\n===\n"}, v, "vocab.json")
	return ps
}

// keys の * は object の値を全部たどり、たどった鍵を頭に付ける（markers を持たない役がいても綴り違いにしない）。
func TestStarInKeysPrefixesTheWalkedKey(t *testing.T) {
	v, _ := castVocabOf(t, castVocab)
	if got := strings.Join(v.Specs["fx"].Params[0].refList, ","); got != "toma.mouth,whale.mouth,whale.tail" {
		t.Errorf("got %s", got)
	}
}

// path の * も同じく、文字列の頭にたどった鍵を付ける。
func TestStarInPathPrefixesTheWalkedKey(t *testing.T) {
	v, _ := castVocabOf(t, castVocab)
	if got := strings.Join(v.Specs["show"].Params[1].refList, ","); got != "rin.sad,toma.smile,toma.angry" {
		t.Errorf("got %s", got)
	}
}

// * の後の段をどの値も持たない時は綴り違いとして知らせる。
func TestStarPathThatPicksNothingIsNoted(t *testing.T) {
	_, notes := castVocabOf(t, strings.Replace(castVocab, `"cast.*.faces[]"`, `"casts.*.faces[]"`, 1))
	if len(notes) != 1 || !strings.Contains(notes[0], "casts.*.faces[]") {
		t.Errorf("notes %v", notes)
	}
}

// * より前の段に届いていれば、* の後の欄が どの項目にも無くても知らせず、空の集まりとして照らす（書かない事がある欄）。
func TestStarPathWithReachedPrefixIsEmptyNotSkipped(t *testing.T) {
	_, notes := castVocabOf(t, strings.Replace(castVocab, `"cast.*.faces[]"`, `"cast.*.face[]"`, 1))
	if len(notes) != 0 {
		t.Errorf("notes %v", notes)
	}
}

// marker の名前は ref の Doc で照らす。
func TestMarkerMissingFromTheDocStops(t *testing.T) {
	got := messages(castProblems(t, "<<fx on=whale.mouth>>\n<<fx on=whale.tial>>"))
	if !strings.Contains(got, "t.yarn:4: <<fx>> の on の whale.tial が Doc に無い（もしかして: whale.tail）") || strings.Contains(got, "t.yarn:3") {
		t.Errorf("got %s", got)
	}
}

// scope の引数は、その引数の値の集まりで照らし、案もその集まりから出す。
func TestScopedNameIsCheckedWithinTheOtherArgsValue(t *testing.T) {
	got := messages(castProblems(t, "<<show toma smile>>\n<<show rin smil>>"))
	if !strings.Contains(got, "t.yarn:4: <<show>> の face の smil が Doc の rin に無い") || strings.Contains(got, "t.yarn:3") {
		t.Errorf("got %s", got)
	}
}

// scope の先が orWords の語の時は照らさない。
func TestScopedNameIsNotCheckedUnderAnOrWord(t *testing.T) {
	if ps := castProblems(t, "<<show all smile>>"); len(ps) != 0 {
		t.Errorf("got %s", messages(ps))
	}
}

// scope の先がほかの引数の名前でない表は止める。
func TestScopeToAnUnknownParamStops(t *testing.T) {
	body := `{"show": {"params": [{"name": "face", "type": "name", "scope": "who"}]}}`
	if _, _, err := ParseVocab([]byte(`{"version": 2, "commands": `+body+`}`), "vocab.json", "."); err == nil {
		t.Errorf("止まらない")
	}
}
