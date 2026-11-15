package yarn

// fge yarn graph: フォルダの .yarn から、ノードと jump のグラフ・ノードごとの演出の並びと行・検査を作る（HTML は行を、--json は演出の並びも出す）。
// 中身は Graph（--json で書く形）に集め、HTML は graph_html.go がそれから描く。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// 演出の分類（HTML の色）。vocab.json の graph.categories のキーはこの中から選ぶ。
const (
	CategoryStage = "stage"
	CategoryActor = "actor"
	CategorySound = "sound"
	CategoryFx    = "fx"
	CategoryWait  = "wait"
	CategoryEnd   = "end"
	CategoryOther = "other"
)

// 帯と行の列だけで使う分類（コマンドでない文）。
const (
	categoryLine   = "line"
	categoryGate   = "gate"
	categoryChoice = "choice"
	categoryJump   = "jump"
)

var commandCategories = []string{CategoryStage, CategoryActor, CategorySound, CategoryFx, CategoryWait, CategoryEnd}

// DefaultCategories はどのゲームでも同じ意味で使われやすいコマンド名の分類。
// ゲームだけのコマンド（人物の名前など）は vocab.json の graph.categories で足す。
var DefaultCategories = map[string][]string{
	CategoryStage: {"scene", "bg", "lights", "black", "clear", "nvl", "adv", "window", "fade", "dim", "zoom", "text"},
	CategoryActor: {"char", "item", "show", "hide"},
	CategorySound: {"se", "bgm", "ambience", "voice", "silence", "audio"},
	CategoryFx:    {"shake", "fx", "flash"},
	CategoryWait:  {waitCommand},
	CategoryEnd:   {endCommand},
}

// DefaultStageKeys は、最後に書いた値がノードを越えて残るコマンド（舞台）の既定。
// 鍵は「名前」か「名前 1 つ目の引数」（audio ambience）。後の形は 1 つ目の引数ごとに分けて残す（audio se は残らない）。
var DefaultStageKeys = []string{"scene", "bg", "bgm", "ambience", "lights", "audio ambience", "audio bgm"}

// stageEntry は舞台に残すコマンドの鍵と値（舞台でなければ ok が偽）。「名前 1 つ目の引数」の鍵を先に見る。
func stageEntry(isStage map[string]bool, name string, args []string) (key, val string, ok bool) {
	if len(args) > 0 && isStage[name+" "+args[0]] {
		return name + " " + args[0], orDefault(strings.Join(args[1:], " "), "on"), true
	}
	if isStage[name] {
		return name, orDefault(strings.Join(args, " "), "on"), true
	}
	return "", "", false
}

// endCommand は結末のノードの目印（<<end 名前>>）。
const endCommand = "end"

// Graph は fge yarn graph の中身（--json はこれをそのまま書く）。
type Graph struct {
	Title       string         `json:"title"`
	Files       []string       `json:"files"`
	Roots       []string       `json:"roots"`
	StageKeys   []string       `json:"stageKeys"`
	Lines       int            `json:"lines"`
	WaitSeconds float64        `json:"waitSeconds"`
	Endings     []string       `json:"endings"`
	Nodes       []*GraphNode   `json:"nodes"`
	Edges       []*GraphEdge   `json:"edges"`
	Commands    []CommandCount `json:"commands"`
	Problems    []GraphProblem `json:"problems"`
	// Vars は変数の名前（$ 付き）→ 表示名（語彙の vars。行の $名前 を表示名で出し、$名前 を小さく添える）。
	Vars map[string]string `json:"vars,omitempty"`
}

// GraphNode はノード 1 つ。Depth は最初のノードからの最短の jump の数（たどり着けなければ一番右の列）。
// Ending は <<end>> のあるノード（EndingName はその引数）。Rows は HTML だけが使う全部の行。
// Heading は箱の見出し（最初の台詞か地の文の頭。文の無いノードは title: の前の // ── コメント）。
type GraphNode struct {
	Title       string            `json:"title"`
	Heading     string            `json:"heading"`
	File        string            `json:"file"`
	Line        int               `json:"line"`
	Depth       int               `json:"depth"`
	Root        bool              `json:"root,omitempty"`
	Reachable   bool              `json:"reachable"`
	Ending      bool              `json:"ending,omitempty"`
	EndingName  string            `json:"endingName,omitempty"`
	Stops       bool              `json:"stops,omitempty"`
	Lines       int               `json:"lines"`
	Commands    int               `json:"commands"`
	WaitSeconds float64           `json:"waitSeconds"`
	Gates       int               `json:"gates"`
	Head        map[string]string `json:"head"`
	State       map[string]string `json:"state"`
	Strip       []Band            `json:"strip"`
	Rows        []Row             `json:"-"`
}

// Band は演出の帯の 1 切れ（シナリオの順。Seconds は wait の秒）。
type Band struct {
	Category string  `json:"category"`
	Name     string  `json:"name"`
	Args     string  `json:"args,omitempty"`
	Seconds  float64 `json:"seconds,omitempty"`
	Line     int     `json:"line"`
}

// Row は行の列の 1 行（Depth は字下げの段階）。
type Row struct {
	Depth    int    `json:"d"`
	Category string `json:"c"`
	Text     string `json:"t"`
	Line     int    `json:"l"`
}

// GraphEdge は jump 1 つ。Back は前の列（か同じ列）へ戻る矢印、Choice は選択肢の中の jump の選択肢の字。
// Carried は元のノードの終わりの舞台のうち、先のノードが頭で当て直さない物（先へ持ち越される）。
type GraphEdge struct {
	From    string            `json:"from"`
	To      string            `json:"to"`
	File    string            `json:"file"`
	Line    int               `json:"line"`
	Choice  string            `json:"choice,omitempty"`
	Back    bool              `json:"back,omitempty"`
	Missing bool              `json:"missing,omitempty"`
	Carried map[string]string `json:"carried,omitempty"`
}

// CommandCount はコマンドの使われた回数（多い順）。
type CommandCount struct {
	Name     string `json:"name"`
	Category string `json:"category"`
	Count    int    `json:"count"`
}

// GraphProblem は検査の 1 件。Level は error（build が止める物）か warn（グラフで見つけた物）。
type GraphProblem struct {
	Level string `json:"level"`
	File  string `json:"file"`
	Line  int    `json:"line"`
	Msg   string `json:"msg"`
}

// GraphConfig は vocab.json の graph（無くてもよい）。
//
//	categories  分類 → コマンド名（既定の表に足す・同じ名前は上書き）
//	stage       舞台のコマンド名（書けば既定と入れ替える）
type GraphConfig struct {
	Categories map[string][]string `json:"categories"`
	Stage      []string            `json:"stage"`
}

// ParseGraphConfig は vocab.json の graph を読む（無ければ空）。
func ParseGraphConfig(vocabJSON []byte) (GraphConfig, error) {
	var wrap struct {
		Graph GraphConfig `json:"graph"`
	}
	if err := json.Unmarshal(vocabJSON, &wrap); err != nil {
		return GraphConfig{}, fmt.Errorf("語彙の JSON を読めない: %v", err)
	}
	return wrap.Graph, nil
}

// categoryTable はコマンド名 → 分類（既定の表に cfg を重ねる）。知らない分類のキーは知らせに出す。
func categoryTable(cfg GraphConfig, vocabPath string) (map[string]string, []GraphProblem) {
	table := map[string]string{}
	for cat, names := range DefaultCategories {
		for _, n := range names {
			table[n] = cat
		}
	}
	known := setOf(commandCategories)
	var problems []GraphProblem
	keys := make([]string, 0, len(cfg.Categories))
	for k := range cfg.Categories {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, cat := range keys {
		if !known[cat] {
			problems = append(problems, GraphProblem{Level: "warn", File: vocabPath, Line: 1,
				Msg: fmt.Sprintf("graph.categories の分類 %s を知らない（%s のどれか）", cat, strings.Join(commandCategories, " "))})
			continue
		}
		for _, n := range cfg.Categories[cat] {
			table[n] = cat
		}
	}
	return table, problems
}

// BuildGraph は木と検査の知らせからグラフを作る。roots が空なら最初のファイルの最初のノードから辿る。
// commentHeads はノード名 → title: の前の // ── コメントの見出し（CommentHeadings。無ければ nil）。
func BuildGraph(prog *Program, checked []Problem, roots []string, stageKeys []string, categories map[string]string, commentHeads map[string]string) *Graph {
	g := &Graph{Files: prog.Files, StageKeys: stageKeys, Endings: []string{}, Nodes: []*GraphNode{}, Edges: []*GraphEdge{},
		Commands: []CommandCount{}, Problems: []GraphProblem{}}
	catOf := func(name string) string {
		if c, ok := categories[name]; ok {
			return c
		}
		return CategoryOther
	}
	isStage := setOf(stageKeys)
	byTitle := map[string]*GraphNode{}
	counts := map[string]int{}
	for _, n := range prog.Nodes {
		if n.Title == "" || byTitle[n.Title] != nil {
			continue
		}
		gn, edges := summarizeNode(n, isStage, catOf, counts)
		gn.Heading = headingOf(n, commentHeads)
		byTitle[n.Title] = gn
		g.Nodes = append(g.Nodes, gn)
		g.Edges = append(g.Edges, edges...)
		g.Lines += gn.Lines
		g.WaitSeconds += gn.WaitSeconds
		if gn.Ending {
			g.Endings = append(g.Endings, gn.EndingName)
		}
	}
	for _, r := range roots {
		if byTitle[r] != nil {
			g.Roots = append(g.Roots, r)
		}
	}
	if len(g.Roots) == 0 && len(g.Nodes) > 0 {
		g.Roots = []string{g.Nodes[0].Title}
	}
	layoutDepths(g, byTitle)
	for _, e := range g.Edges {
		to := byTitle[e.To]
		if to == nil {
			e.Missing = true
			continue
		}
		from := byTitle[e.From]
		e.Back = to.Depth <= from.Depth
		for k, v := range from.State {
			if _, ok := to.Head[k]; !ok {
				if e.Carried == nil {
					e.Carried = map[string]string{}
				}
				e.Carried[k] = v
			}
		}
	}
	for name, c := range counts {
		g.Commands = append(g.Commands, CommandCount{Name: name, Category: catOf(name), Count: c})
	}
	sort.Slice(g.Commands, func(a, b int) bool {
		if g.Commands[a].Count != g.Commands[b].Count {
			return g.Commands[a].Count > g.Commands[b].Count
		}
		return g.Commands[a].Name < g.Commands[b].Name
	})
	// WhyNot: 無いノードへの jump をここで数え直さない —— CheckProgram が同じ物を行番号つきで出す（判定を 2 本にしない）。
	for _, p := range checked {
		g.Problems = append(g.Problems, GraphProblem{Level: "error", File: p.File, Line: p.Line, Msg: p.Msg})
	}
	for _, n := range g.Nodes {
		if !n.Reachable {
			g.Problems = append(g.Problems, GraphProblem{Level: "warn", File: n.File, Line: n.Line,
				Msg: fmt.Sprintf("ノード %s に最初のノード（%s）からたどり着けない", n.Title, strings.Join(g.Roots, "・"))})
		}
	}
	outgoing := map[string]bool{}
	for _, e := range g.Edges {
		outgoing[e.From] = true
	}
	for _, n := range g.Nodes {
		if !outgoing[n.Title] && !n.Stops && !n.Ending {
			g.Problems = append(g.Problems, GraphProblem{Level: "warn", File: n.File, Line: n.Line,
				Msg: fmt.Sprintf("ノード %s は行き止まり（<<jump>> も <<stop>> も <<%s>> も無い）", n.Title, endCommand)})
		}
	}
	return g
}

// headingLength は見出しに出す字の数（箱の幅に収まる数）。
const headingLength = 11

// headingOf はノードの見出し。英語のノード名より、人がシナリオで覚えている冒頭の文の方が箱を見分けやすい。
func headingOf(n *Node, commentHeads map[string]string) string {
	text := firstText(n.Body)
	// WhyNot: ／ でも切る —— 縦のノベルで ／ を改行の目印に使うシナリオがあり、切らないと 2 行目の頭まで見出しに入る。
	if i := strings.IndexAny(text, "／\n"); i >= 0 {
		text = text[:i]
	}
	text = strings.TrimSpace(text)
	if r := []rune(text); len(r) > headingLength {
		return string(r[:headingLength]) + "…"
	}
	if text != "" {
		return text
	}
	if h, ok := commentHeads[n.Title]; ok {
		return "〔" + h + "〕"
	}
	return "（文なし）"
}

// firstText は最初の台詞か地の文の字（マークアップは木の Text で既に抜けている）。選択肢の中まで見る。
func firstText(stmts []*Stmt) string {
	for _, s := range stmts {
		if s.Kind == "line" {
			return s.Text
		}
		for _, o := range s.Options {
			if t := firstText(o.Body); t != "" {
				return t
			}
		}
		for _, c := range s.Clauses {
			if t := firstText(c.Body); t != "" {
				return t
			}
		}
	}
	return ""
}

// NodeComments は .yarn の本文から、title: の直前の // ── コメント（線を除いた全部）を、ノード名ごとに拾う。
func NodeComments(text string) map[string]string {
	out := map[string]string{}
	pending := ""
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		switch {
		case strings.HasPrefix(line, "// ──"):
			pending = strings.TrimSpace(strings.Trim(line, "/ ─"))
		case strings.HasPrefix(line, "title:"):
			if pending != "" {
				out[strings.TrimSpace(strings.TrimPrefix(line, "title:"))] = pending
			}
			pending = ""
		}
	}
	return out
}

// CommentHeadings は NodeComments の見出し（commentHeading）。
func CommentHeadings(text string) map[string]string {
	out := NodeComments(text)
	for k, v := range out {
		out[k] = commentHeading(v)
	}
	return out
}

// commentHeading は // ── コメントの「:」より前（箱とシナリオ原稿の見出しに使う短い名前）。
func commentHeading(comment string) string {
	if i := strings.IndexAny(comment, ":："); i >= 0 {
		return strings.TrimSpace(comment[:i])
	}
	return comment
}

// layoutDepths は最初のノードたちから jump を辿った最短の数を Depth に入れる。
func layoutDepths(g *Graph, byTitle map[string]*GraphNode) {
	next := map[string][]string{}
	for _, e := range g.Edges {
		next[e.From] = append(next[e.From], e.To)
	}
	queue := []string{}
	for _, r := range g.Roots {
		byTitle[r].Root = true
		byTitle[r].Reachable = true
		queue = append(queue, r)
	}
	maxDepth := 0
	for len(queue) > 0 {
		a := queue[0]
		queue = queue[1:]
		for _, b := range next[a] {
			n := byTitle[b]
			if n == nil || n.Reachable {
				continue
			}
			n.Reachable = true
			n.Depth = byTitle[a].Depth + 1
			if n.Depth > maxDepth {
				maxDepth = n.Depth
			}
			queue = append(queue, b)
		}
	}
	for _, n := range g.Nodes {
		if !n.Reachable {
			n.Depth = maxDepth + 1
		}
	}
}

// summarizeNode はノードの文をシナリオの順に辿り、帯・行の列・舞台・出ていく矢印を作る。
func summarizeNode(n *Node, isStage map[string]bool, catOf func(string) string, counts map[string]int) (*GraphNode, []*GraphEdge) {
	gn := &GraphNode{Title: n.Title, File: n.File, Line: n.Line, Head: map[string]string{}, State: map[string]string{},
		Strip: []Band{}, Rows: []Row{}}
	var edges []*GraphEdge
	seenLine := false
	var visit func(stmts []*Stmt, depth int, choice string)
	visit = func(stmts []*Stmt, depth int, choice string) {
		for _, s := range stmts {
			switch s.Kind {
			case "line":
				gn.Lines++
				seenLine = true
				who := s.Speaker
				gn.Strip = append(gn.Strip, Band{Category: categoryLine, Name: orDefault(who, "地の文"), Args: clip(s.Text, 40), Line: s.Line})
				gn.Rows = append(gn.Rows, Row{depth, categoryLine, prefixed(who, s.Text), s.Line})
			case "command":
				counts[s.Name]++
				gn.Commands++
				cat := catOf(s.Name)
				args := strings.Join(s.Args, " ")
				secs := 0.0
				if s.Name == waitCommand && len(s.Args) == 1 {
					if v, err := strconv.ParseFloat(s.Args[0], 64); err == nil && v > 0 {
						secs = v
					}
				}
				gn.WaitSeconds += secs
				if key, val, ok := stageEntry(isStage, s.Name, s.Args); ok {
					gn.State[key] = val
					if !seenLine {
						gn.Head[key] = val
					}
				}
				if s.Name == endCommand {
					gn.Ending = true
					gn.EndingName = args
				}
				gn.Strip = append(gn.Strip, Band{Category: cat, Name: s.Name, Args: args, Seconds: secs, Line: s.Line})
				gn.Rows = append(gn.Rows, Row{depth, cat, "<<" + strings.TrimSpace(s.Name+" "+args) + ">>", s.Line})
			case "options":
				if len(s.Options) == 1 {
					o := s.Options[0]
					gn.Gates++
					gn.Strip = append(gn.Strip, Band{Category: categoryGate, Name: "ゲート", Args: o.Text, Line: s.Line})
					gn.Rows = append(gn.Rows, Row{depth, categoryGate, strings.TrimSpace("-> " + o.Text + " " + tagsText(o.Tags)), s.Line})
					visit(o.Body, depth+1, choice)
					continue
				}
				seenLine = true
				gn.Rows = append(gn.Rows, Row{depth, categoryChoice, fmt.Sprintf("選択肢 %d つ", len(s.Options)), s.Line})
				for _, o := range s.Options {
					text := "-> " + prefixed(o.Speaker, o.Text)
					if o.Condition != nil {
						text += " <<if " + exprText(o.Condition) + ">>"
					}
					gn.Rows = append(gn.Rows, Row{depth + 1, categoryChoice, text, o.Line})
					visit(o.Body, depth+2, o.Text)
				}
			case "jump":
				edges = append(edges, &GraphEdge{From: n.Title, To: s.Node, File: n.File, Line: s.Line, Choice: choice})
				gn.Rows = append(gn.Rows, Row{depth, categoryJump, "<<jump " + s.Node + ">>", s.Line})
			case "stop":
				gn.Stops = true
				gn.Rows = append(gn.Rows, Row{depth, categoryJump, "<<stop>>", s.Line})
			case "set":
				gn.Rows = append(gn.Rows, Row{depth, CategoryOther, "<<set " + s.Name + " to " + exprText(s.Expr) + ">>", s.Line})
			case "if":
				for i, c := range s.Clauses {
					head := "<<else>>"
					switch {
					case i == 0:
						head = "<<if " + exprText(c.Condition) + ">>"
					case c.Condition != nil:
						head = "<<elseif " + exprText(c.Condition) + ">>"
					}
					gn.Rows = append(gn.Rows, Row{depth, CategoryOther, head, c.Line})
					visit(c.Body, depth+1, choice)
				}
			default:
				gn.Rows = append(gn.Rows, Row{depth, CategoryOther, s.Kind, s.Line})
			}
		}
	}
	visit(n.Body, 0, "")
	return gn, edges
}

// exprText は式を .yarn の書き方に戻す（行の列に出すだけ。括弧は元の書き方でなく入れ子ごとに付ける）。
func exprText(x *Expr) string {
	if x == nil {
		return ""
	}
	switch x.Kind {
	case "value":
		if x.Value == nil {
			return ""
		}
		switch x.Value.Type {
		case TypeNumber:
			return strconv.FormatFloat(x.Value.Number, 'f', -1, 64)
		case TypeBool:
			return strconv.FormatBool(x.Value.Bool)
		}
		return strconv.Quote(x.Value.String)
	case "variable":
		return x.Name
	case "visited", "visited_count":
		return x.Kind + "(" + strconv.Quote(x.Name) + ")"
	case "not":
		return "not " + exprText(x.Args[0])
	case "neg":
		return "-" + exprText(x.Args[0])
	}
	if len(x.Args) == 2 {
		left, right := exprText(x.Args[0]), exprText(x.Args[1])
		if len(x.Args[0].Args) == 2 {
			left = "(" + left + ")"
		}
		if len(x.Args[1].Args) == 2 {
			right = "(" + right + ")"
		}
		return left + " " + x.Kind + " " + right
	}
	return x.Kind
}

func tagsText(tags []Tag) string {
	var out []string
	for _, t := range tags {
		if t.Value == "" {
			out = append(out, "#"+t.Key)
		} else {
			out = append(out, "#"+t.Key+":"+t.Value)
		}
	}
	return strings.Join(out, " ")
}

func prefixed(speaker, text string) string {
	if speaker == "" {
		return text
	}
	return speaker + ": " + text
}

func orDefault(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

const graphUsage = `使い方: bin/fge yarn graph <フォルダか x.yarn>... [--out <html>] [--json <json>|-] [--vocab <パス> | --no-vocab] [--stage a,b,…]
  1 つのフォルダの .yarn から、分岐のグラフ（ノード = 箱・<<jump>> = 矢印）と、ノードを押すと出る舞台・矢印・全部の行と、検査を書き出す。
  既定の書き先は <ゲームのルート>/build/yarn-graph.html（1 ファイルで開ける。外の物を読まない）。
  --json はグラフの中身（ノード・矢印・演出の並び・検査。行の本文は入れない）を書く（- か書き先を省くと標準出力）。--json だけなら HTML は書かない。
  最初のノードは語彙（vocab.json）の nodes（コードが開くノード）。語彙が無ければ最初のファイルの最初のノード。
  演出の色は既定の表に、vocab.json の "graph": {"categories": {"actor": ["girl"]}} を重ねる（分類: stage actor sound fx wait end。無い名前は other）。
  舞台（ノードを越えて残る物）は --stage か vocab.json の graph.stage、無ければ scene bg bgm ambience lights と audio ambience・audio bgm
  （「名前 1 つ目の引数」の鍵は、その引数の時だけ残す）。
  検査は build の検査の全部（error）に、たどり着けないノードと行き止まり（warn）を足す。知らせがあっても書く（終わりの番号は 0）。
`

type graphOptions struct {
	out, json, vocab string
	jsonOut, noVocab bool
	stage            []string
}

func parseGraphFlags(args []string) (graphOptions, []string, error) {
	var o graphOptions
	var paths []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		hasValue := i+1 < len(args) && !strings.HasPrefix(args[i+1], "--")
		switch a {
		case "--json":
			o.jsonOut = true
			if hasValue && args[i+1] != "-" && (strings.HasSuffix(args[i+1], ".json") || !isDirOrYarn(args[i+1])) {
				o.json = args[i+1]
				i++
			} else if hasValue && args[i+1] == "-" {
				i++
			}
		case "--out", "--vocab", "--stage":
			if !hasValue {
				return o, nil, fmt.Errorf("%s の後ろに値が要る", a)
			}
			switch a {
			case "--out":
				o.out = args[i+1]
			case "--vocab":
				o.vocab = args[i+1]
			default:
				o.stage = strings.FieldsFunc(args[i+1], func(r rune) bool { return r == ',' || r == ' ' })
			}
			i++
		case "--no-vocab":
			o.noVocab = true
		case "--help", "-h":
			return o, nil, errGraphHelp
		default:
			if strings.HasPrefix(a, "--") {
				return o, nil, fmt.Errorf("知らない指定: %s", a)
			}
			paths = append(paths, a)
		}
	}
	if len(paths) == 0 {
		return o, nil, fmt.Errorf("フォルダか .yarn を 1 つ以上渡す（bin/fge yarn graph --help）")
	}
	return o, paths, nil
}

var errGraphHelp = fmt.Errorf("help")

// isDirOrYarn は --json の後ろの語が書き先でなく読む物らしいか（--json を最後でなく前に書いた時のため）。
func isDirOrYarn(p string) bool {
	if strings.HasSuffix(p, ".yarn") {
		return true
	}
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

// runGraph は fge yarn graph の入口。
func runGraph(out, errOut *strings.Builder, cwd string, args []string) int {
	opts, paths, err := parseGraphFlags(args)
	if err == errGraphHelp {
		out.WriteString(graphUsage)
		return 0
	}
	if err != nil {
		errOut.WriteString(err.Error() + "\n" + graphUsage)
		return 2
	}
	abs := func(p string) string {
		if p == "" || filepath.IsAbs(p) {
			return p
		}
		return filepath.Join(cwd, p)
	}
	groups, err := groupsOf(cwd, paths)
	if err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 2
	}
	if len(groups) != 1 {
		errOut.WriteString(fmt.Sprintf("グラフは 1 つのフォルダずつ作る（.yarn のあるフォルダが %d 個ある）\n", len(groups)))
		return 2
	}
	l, err := loadGroup(groups[0], cwd, abs(opts.vocab), opts.noVocab)
	if err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 2
	}
	graph := l.graph(opts.stage)

	htmlPath := abs(opts.out)
	if htmlPath == "" && !opts.jsonOut {
		htmlPath = filepath.Join(l.root, "build", "yarn-graph.html")
	}
	if htmlPath != "" {
		page, err := RenderGraphHTML(graph)
		if err == nil {
			err = writeFileMkdir(htmlPath, page)
		}
		if err != nil {
			errOut.WriteString(err.Error() + "\n")
			return 1
		}
	}
	if opts.jsonOut {
		data, err := json.MarshalIndent(graph, "", "  ")
		if err != nil {
			errOut.WriteString(err.Error() + "\n")
			return 1
		}
		data = append(data, '\n')
		if opts.json == "" {
			out.Write(data)
			return 0
		}
		if err := writeFileMkdir(abs(opts.json), data); err != nil {
			errOut.WriteString(err.Error() + "\n")
			return 1
		}
	}
	errors, warns := 0, 0
	for _, p := range graph.Problems {
		if p.Level == "error" {
			errors++
		} else {
			warns++
		}
	}
	fmt.Fprintf(out, "[yarn graph] %d ノード・%d 矢印・結末 %d・検査 error %d / warn %d\n",
		len(graph.Nodes), len(graph.Edges), len(graph.Endings), errors, warns)
	for _, p := range graph.Problems {
		fmt.Fprintf(out, "  %s %s:%d: %s\n", p.Level, p.File, p.Line, p.Msg)
	}
	for _, p := range []string{htmlPath, abs(opts.json)} {
		if p != "" {
			fmt.Fprintf(out, "[yarn graph] 書いた %s\n", p)
		}
	}
	return 0
}

// loaded は 1 つのフォルダの .yarn を読んだ物。graph・script・テープの頁が同じ読み方をする。
type loaded struct {
	dir, root string
	texts     []string
	prog      *Program
	checked   []Problem
	vocab     *Vocab
	cfg       GraphConfig
	vocabRel  string
}

// loadGroup は束 g の .yarn と語彙を読んで木にする。vocabPath が空なら <フォルダ>/vocab.json（無くてもよい）。
func loadGroup(g group, cwd, vocabPath string, noVocab bool) (*loaded, error) {
	l := &loaded{dir: g.dir, root: gameRootOf(g.dir, cwd)}
	if !noVocab {
		explicit := vocabPath != ""
		if !explicit {
			vocabPath = filepath.Join(g.dir, vocabName)
		}
		data, readErr := os.ReadFile(vocabPath)
		switch {
		case readErr != nil && explicit:
			return nil, fmt.Errorf("語彙を読めない: %s", vocabPath)
		case readErr != nil:
			// WhyNot: 語彙が無くても止めない —— 書きかけのシナリオの形を見るのがこのコマンドの用途で、話し手やコマンドの検査は build が受け持つ。
		default:
			v, _, err := ParseVocab(data, vocabPath, l.root)
			if err == nil {
				l.cfg, err = ParseGraphConfig(data)
			}
			if err != nil {
				return nil, fmt.Errorf("%s: %v", rel(l.root, vocabPath), err)
			}
			l.vocab, l.vocabRel = v, rel(l.root, vocabPath)
		}
	}
	var names []string
	for _, f := range g.files {
		data, err := os.ReadFile(f)
		if err != nil {
			return nil, fmt.Errorf("%s: 読めない: %v", rel(l.root, f), err)
		}
		names = append(names, rel(l.root, f))
		l.texts = append(l.texts, string(data))
	}
	l.prog, l.checked = BuildProgram(names, l.texts, l.vocab, l.vocabRel)
	return l, nil
}

// graph は読んだ木のグラフ。stage が空なら語彙の graph.stage、それも無ければ既定の舞台。
func (l *loaded) graph(stage []string) *Graph {
	if len(stage) == 0 {
		stage = l.cfg.Stage
	}
	if len(stage) == 0 {
		stage = DefaultStageKeys
	}
	table, cfgProblems := categoryTable(l.cfg, l.vocabRel)
	var roots []string
	if l.vocab != nil {
		roots = l.vocab.Nodes
	}
	heads := map[string]string{}
	for _, text := range l.texts {
		for k, v := range CommentHeadings(text) {
			heads[k] = v
		}
	}
	g := BuildGraph(l.prog, l.checked, roots, stage, table, heads)
	g.Problems = append(cfgProblems, g.Problems...)
	if l.vocab != nil {
		g.Vars = l.vocab.Vars
	}
	g.Title = fmt.Sprintf("%s — %s", gameTitleOf(l.root), rel(l.root, l.dir))
	return g
}

// gameTitleOf は project.json の title（無ければフォルダの名前）。
func gameTitleOf(root string) string {
	var project struct {
		Title string `json:"title"`
	}
	if data, err := os.ReadFile(filepath.Join(root, "project.json")); err == nil && json.Unmarshal(data, &project) == nil && project.Title != "" {
		return project.Title
	}
	return filepath.Base(root)
}

func writeFileMkdir(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("書けない: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("書けない: %v", err)
	}
	return nil
}
