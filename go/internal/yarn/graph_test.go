package yarn

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const graphScript = `title: Start
---
<<bg room>>
<<wait 1.5>>
me: どうする？
-> 行く
    <<jump Good>>
-> 戻る
    <<jump Start>>
===
title: Good
---
<<scene night>>
me: 行った
<<end happy>>
===
title: Lost
---
me: 誰も来ない
<<jump Nowhere>>
===
title: Dead
---
me: ここで終わる
===
`

func graphOf(t *testing.T, script string, roots []string, cfg GraphConfig) *Graph {
	t.Helper()
	prog, checked := buildText(t, script, nil)
	table, _ := categoryTable(cfg, "vocab.json")
	return BuildGraph(prog, checked, roots, DefaultStageKeys, table, CommentHeadings(script))
}

func edgeOf(g *Graph, from, to string) *GraphEdge {
	for _, e := range g.Edges {
		if e.From == from && e.To == to {
			return e
		}
	}
	return nil
}

func nodeOf(g *Graph, title string) *GraphNode {
	for _, n := range g.Nodes {
		if n.Title == title {
			return n
		}
	}
	return nil
}

func problemsText(g *Graph) string {
	var out []string
	for _, p := range g.Problems {
		out = append(out, p.Level+" "+p.Msg)
	}
	return strings.Join(out, "\n")
}

func TestGraphChoiceJumpCarriesTheOptionText(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if e := edgeOf(g, "Start", "Good"); e == nil || e.Choice != "行く" || e.Back {
		t.Fatalf("Start → Good は選択肢「行く」の先へ進む矢印のはず: %+v", e)
	}
}

func TestGraphJumpToTheSameOrEarlierColumnIsBack(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if e := edgeOf(g, "Start", "Start"); e == nil || !e.Back {
		t.Fatalf("Start → Start は戻る矢印のはず: %+v", e)
	}
}

func TestGraphNodeWithEndCommandIsAnEnding(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if n := nodeOf(g, "Good"); !n.Ending || n.EndingName != "happy" {
		t.Fatalf("Good は結末 happy のはず: %+v", n)
	}
}

func TestGraphFirstNodeWithoutVocabIsTheFirstInTheFile(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if len(g.Roots) != 1 || g.Roots[0] != "Start" || !nodeOf(g, "Start").Root {
		t.Fatalf("最初のノードは Start のはず: %v", g.Roots)
	}
}

func TestGraphFirstNodesComeFromVocabNodes(t *testing.T) {
	g := graphOf(t, graphScript, []string{"Lost", "NotThere"}, GraphConfig{})
	if len(g.Roots) != 1 || g.Roots[0] != "Lost" {
		t.Fatalf("最初のノードは語彙の nodes のうち有る物のはず: %v", g.Roots)
	}
}

func TestGraphReportsUnreachableNodes(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if !strings.Contains(problemsText(g), "warn ノード Lost に最初のノード（Start）からたどり着けない") {
		t.Fatalf("Lost はたどり着けないと出るはず:\n%s", problemsText(g))
	}
}

func TestGraphReportsDeadEnds(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if !strings.Contains(problemsText(g), "warn ノード Dead は行き止まり") {
		t.Fatalf("Dead は行き止まりと出るはず:\n%s", problemsText(g))
	}
}

func TestGraphMissingJumpTargetComesFromBuildCheckOnce(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if n := strings.Count(problemsText(g), "Nowhere"); n != 1 || !strings.Contains(problemsText(g), "error <<jump>> の行き先 Nowhere が無い") {
		t.Fatalf("無いノードへの jump は build の検査の文で 1 回だけ出るはず:\n%s", problemsText(g))
	}
}

func TestGraphMissingJumpTargetEdgeIsMarked(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if e := edgeOf(g, "Lost", "Nowhere"); e == nil || !e.Missing {
		t.Fatalf("Lost → Nowhere は行き先の無い矢印のはず: %+v", e)
	}
}

func TestGraphStripWidthIsTheWaitSeconds(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if b := nodeOf(g, "Start").Strip[1]; b.Category != CategoryWait || b.Seconds != 1.5 {
		t.Fatalf("Start の帯の 2 つ目は 1.5 秒の wait のはず: %+v", b)
	}
}

func TestGraphStageBeforeTheFirstLineIsTheHead(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if v := nodeOf(g, "Start").Head["bg"]; v != "room" {
		t.Fatalf("Start は頭で bg=room を当てるはず: %v", nodeOf(g, "Start").Head)
	}
}

func TestGraphEdgeCarriesStageTheTargetDoesNotSet(t *testing.T) {
	g := graphOf(t, graphScript, nil, GraphConfig{})
	if e := edgeOf(g, "Start", "Good"); e.Carried["bg"] != "room" {
		t.Fatalf("Start → Good は bg=room を持ち越すはず: %v", e.Carried)
	}
}

func TestGraphWindowIsStageAndAudioIsSound(t *testing.T) {
	g := graphOf(t, "title: A\n---\n<<window nvl>>\n<<audio se se_slap>>\n===\n", nil, GraphConfig{})
	strip := nodeOf(g, "A").Strip
	if strip[0].Category != CategoryStage || strip[1].Category != CategorySound {
		t.Fatalf("window は stage・audio は sound のはず: %s %s", strip[0].Category, strip[1].Category)
	}
}

func TestGraphAudioAmbienceStaysOnTheStageButSeDoesNot(t *testing.T) {
	g := graphOf(t, "title: A\n---\n<<audio ambience amb_night>>\n<<audio se se_slap>>\nme: 夜\n===\n", nil, GraphConfig{})
	n := nodeOf(g, "A")
	if n.Head["audio ambience"] != "amb_night" {
		t.Fatalf("audio ambience は舞台に amb_night で残るはず: %v", n.Head)
	}
	if _, ok := n.State["audio se"]; ok {
		t.Fatalf("audio se は舞台に残らないはず: %v", n.State)
	}
	if _, ok := n.State["audio"]; ok {
		t.Fatalf("audio だけの鍵は作らないはず: %v", n.State)
	}
}

func TestGraphUnknownCommandIsOther(t *testing.T) {
	g := graphOf(t, "title: A\n---\n<<witch on>>\n===\n", nil, GraphConfig{})
	if c := nodeOf(g, "A").Strip[0].Category; c != CategoryOther {
		t.Fatalf("表に無いコマンドは other のはず: %s", c)
	}
}

func TestGraphVocabCategoriesAddToTheDefaultTable(t *testing.T) {
	cfg, err := ParseGraphConfig([]byte(`{"speakers": [], "graph": {"categories": {"actor": ["witch"]}}}`))
	if err != nil {
		t.Fatal(err)
	}
	g := graphOf(t, "title: A\n---\n<<witch on>>\n===\n", nil, cfg)
	if c := nodeOf(g, "A").Strip[0].Category; c != CategoryActor {
		t.Fatalf("vocab.json の graph.categories で witch は actor のはず: %s", c)
	}
}

func TestGraphCommandRunWritesHTMLAndJSON(t *testing.T) {
	dir := t.TempDir()
	talk := filepath.Join(dir, "assets", "talk")
	if err := os.MkdirAll(talk, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "project.json"), []byte("{}"), 0o644)
	os.WriteFile(filepath.Join(talk, "a.yarn"), []byte(graphScript), 0o644)
	var out, errOut strings.Builder
	code := Run(&out, &errOut, dir, []string{"graph", "assets/talk", "--out", "g.html", "--json", "g.json"})
	if code != 0 {
		t.Fatalf("graph は 0 で終わるはず: %d %s %s", code, out.String(), errOut.String())
	}
	page, _ := os.ReadFile(filepath.Join(dir, "g.html"))
	if strings.Contains(string(page), "%NODES%") || !strings.Contains(string(page), `data-node="Good"`) {
		t.Fatalf("HTML に Good の箱があり、置き換え残しが無いはず")
	}
	var g Graph
	data, _ := os.ReadFile(filepath.Join(dir, "g.json"))
	if err := json.Unmarshal(data, &g); err != nil || len(g.Nodes) != 4 {
		t.Fatalf("JSON にノードが 4 つあるはず: %v %d", err, len(g.Nodes))
	}
}

func TestGraphHeadingIsTheFirstLineClippedTo11Chars(t *testing.T) {
	g := graphOf(t, "title: A\n---\n<<bg x>>\n[ruby=ひぐらし]蜩[/ruby]が鳴く夏の夕暮れの駅で待つ\n===\n", nil, GraphConfig{})
	if h := nodeOf(g, "A").Heading; h != "蜩が鳴く夏の夕暮れの駅…" {
		t.Fatalf("見出しはマークアップを抜いた最初の文の頭 11 字と … のはず: %q", h)
	}
}

func TestShortHeadingStopsAtTheFirstSentence(t *testing.T) {
	if h := ShortHeading("部屋の奥に置かれた仏壇。ほかの家具と同じ"); h != "部屋の奥に置かれた仏壇。" {
		t.Fatalf("1 文目が句点の前まで 11 字に収まれば、句点で止めて … を付けないはず: %q", h)
	}
}

func TestShortHeadingStopsAtAnExclamation(t *testing.T) {
	if h := ShortHeading("誰だ！　そこにいるのは"); h != "誰だ！" {
		t.Fatalf("！ も 1 文目の終わりとして止めるはず: %q", h)
	}
}

func TestShortHeadingCutsAtTheLastCommaInTheLimit(t *testing.T) {
	if h := ShortHeading("人通りのない通りに、その家はあった。"); h != "人通りのない通りに…" {
		t.Fatalf("11 字に収まらない文は、11 字の中の最後の読点の前で切るはず: %q", h)
	}
}

func TestShortHeadingIgnoresACommaNearTheHead(t *testing.T) {
	if h := ShortHeading("――っ、あああああああああ"); h != "――っ、あああああああ…" {
		t.Fatalf("読点が頭に近い時は 11 字で切るはず: %q", h)
	}
}

func TestGraphHeadingWithoutTextIsTheCommentBeforeTitle(t *testing.T) {
	g := graphOf(t, "// ── 汎用海中: 払うたびに暗くなる ──\ntitle: A\n---\n<<bg x>>\n===\n", nil, GraphConfig{})
	if h := nodeOf(g, "A").Heading; h != "〔汎用海中〕" {
		t.Fatalf("文の無いノードの見出しは // ── コメントの : より前のはず: %q", h)
	}
}

func TestGraphHeadingWithoutTextOrCommentSaysSo(t *testing.T) {
	g := graphOf(t, "title: A\n---\n<<bg x>>\n===\n", nil, GraphConfig{})
	if h := nodeOf(g, "A").Heading; h != "（文なし）" {
		t.Fatalf("文もコメントも無いノードの見出しは（文なし）のはず: %q", h)
	}
}

// 語彙の vars の表示名がグラフの JSON とテープの頁に埋める形に入り、HTML は行の $名前 を表示名で出す。
func TestGraphCarriesVariableDisplayNames(t *testing.T) {
	root := writeGame(t, map[string]string{"assets/talk/main.yarn": "title: Station\n---\n<<declare $closeness = 0>>\n<<if $closeness >= 2>>\nchinatsu: やあ\n<<endif>>\n===\n"})
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, root, []string{"graph", "assets/talk", "--out", "g.html", "--json", "g.json"}); code != 0 {
		t.Fatalf("code %d: %s%s", code, out.String(), errOut.String())
	}
	var g Graph
	data, _ := os.ReadFile(filepath.Join(root, "g.json"))
	page, _ := os.ReadFile(filepath.Join(root, "g.html"))
	tape, _, err := ForTape(filepath.Join(root, "assets", "talk"))
	if json.Unmarshal(data, &g) != nil || g.Vars["$closeness"] != "親しさ" || err != nil || tape == nil || tape.Vars["$closeness"] != "親しさ" ||
		!strings.Contains(string(page), `const VARS = {"$closeness":"親しさ"};`) {
		t.Errorf("vars %v / tape %v %v", g.Vars, tape, err)
	}
}
