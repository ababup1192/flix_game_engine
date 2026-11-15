package yarn

// fge yarn script: .yarn から、ライターが読む台本（Markdown）を書き出し、直した台本を今の .yarn と照らして写し方を出す。
// 見出し（headingOf）・ノードのコメント（NodeComments）・読み方（loadGroup）は graph と同じ物を使う。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// ScriptRef は読み台本の 1 行が指す .yarn の行。Kind は node・line・cmds・gate・choice・option・jump・stop・flow のどれか。
type ScriptRef struct {
	File    string
	Line    int
	Node    string
	Kind    string
	Speaker string
}

// ScriptLine は読み台本の 1 行（Ref は .yarn の行を指さない行なら nil）。
type ScriptLine struct {
	Text string
	Ref  *ScriptRef
}

// ScriptSource は読み台本を作る材料。Comments はノード名 → title: の前の // ── コメント（NodeComments）、
// Names は話し手の id → 表示の名前、Notes は演出コマンドの注釈の言葉。
type ScriptSource struct {
	Title    string
	Prog     *Program
	Comments map[string]string
	Names    map[string]string
	Notes    Notes
}

// Notes は演出コマンド → 読み台本の〔〕の言葉。File（script-notes.json）を先に、Comment（.yarn の冒頭のコメント）を後に引く。
// 鍵は「名前」か「名前 引数」。名前だけの鍵の言葉に {args} があれば引数で置き換え、無ければ引数を（）で後ろに付ける。
type Notes struct {
	File    map[string]string
	Comment map[string]string
}

// Of はコマンドの〔〕の言葉。どちらの表にも無ければコマンドの字そのまま。
func (n Notes) Of(name string, args []string) string {
	joined := strings.Join(args, " ")
	full := strings.TrimSpace(name + " " + joined)
	for _, table := range []map[string]string{n.File, n.Comment} {
		if v, ok := table[full]; ok {
			return v
		}
		if v, ok := table[name]; ok {
			if strings.Contains(v, "{args}") {
				return strings.TrimSpace(strings.ReplaceAll(v, "{args}", joined))
			}
			if joined != "" {
				return v + "（" + joined + "）"
			}
			return v
		}
	}
	return full
}

// ParseScriptNotes は script-notes.json（鍵 → 言葉の 1 段のオブジェクト）を読む。
func ParseScriptNotes(data []byte) (map[string]string, error) {
	var m map[string]string
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("script-notes.json は「コマンド: 言葉」の 1 段のオブジェクトで書く: %v", err)
	}
	return m, nil
}

var (
	commentCommandRe = regexp.MustCompile(`^<<([^<>]+)>>\s*(?:/\s*)?`)
	commentParenRe   = regexp.MustCompile(`（[^（）]*）|\([^()]*\)`)
	commentAsideRe   = regexp.MustCompile(`<<([^<>]+)>>\s*で\s*([^、。）)]+)`)
	literalArgRe     = regexp.MustCompile(`^[a-z0-9_]+$`)
	altArgRe         = regexp.MustCompile(`^[a-z0-9_]+(\|[a-z0-9_]+)+$`)
	descSplitRe      = regexp.MustCompile(`\s*[／/]\s*`)
)

// commandKeys は「<<名前 書き方>>」の書き方から鍵を作る。on|off のような選び肢は 1 つずつ、英小文字の引数は「名前 引数」、
// 秒・[px] のような書き方の説明は名前だけ。
func commandKeys(inner string) []string {
	f := strings.Fields(inner)
	if len(f) == 0 {
		return nil
	}
	name, spec := f[0], f[1:]
	if len(spec) > 0 && altArgRe.MatchString(spec[0]) {
		var keys []string
		for _, alt := range strings.Split(spec[0], "|") {
			keys = append(keys, name+" "+alt)
		}
		return keys
	}
	for _, a := range spec {
		if !literalArgRe.MatchString(a) {
			return []string{name}
		}
	}
	return []string{strings.TrimSpace(name + " " + strings.Join(spec, " "))}
}

// CommentNotes は .yarn のコメントの「//   <<名前 …>>  説明」の行から、コマンド → 説明の頭を拾う。
// 説明の（）は外し、中の「<<名前>> で 言葉」は別の鍵にする。鍵が 2 つ以上で説明が ／ か / で同じ数に割れれば 1 つずつ当てる。
func CommentNotes(text string) map[string]string {
	out := map[string]string{}
	put := func(k, v string) {
		v = strings.TrimSpace(v)
		if _, ok := out[k]; !ok && v != "" {
			out[k] = v
		}
	}
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if !strings.HasPrefix(line, "//") {
			continue
		}
		body := strings.TrimSpace(strings.TrimPrefix(line, "//"))
		var keys []string
		for {
			m := commentCommandRe.FindStringSubmatchIndex(body)
			if m == nil {
				break
			}
			keys = append(keys, commandKeys(body[m[2]:m[3]])...)
			body = body[m[1]:]
		}
		body = strings.TrimSpace(body)
		if len(keys) == 0 || body == "" {
			continue
		}
		var asides [][2]string
		main := commentParenRe.ReplaceAllStringFunc(body, func(p string) string {
			for _, a := range commentAsideRe.FindAllStringSubmatch(p, -1) {
				if ks := commandKeys(a[1]); len(ks) > 0 {
					asides = append(asides, [2]string{ks[0], a[2]})
				}
			}
			return ""
		})
		if i := strings.Index(main, "。"); i >= 0 {
			main = main[:i]
		}
		parts := descSplitRe.Split(strings.TrimSpace(main), -1)
		for i, k := range keys {
			if len(keys) > 1 && len(parts) == len(keys) {
				put(k, parts[i])
			} else {
				put(k, parts[0])
			}
		}
		for _, a := range asides {
			put(a[0], a[1])
		}
	}
	return out
}

// 払いの向き（#act: の値）→ 読み台本の印。
var (
	actLabels = map[string]string{"up": "↑ 上へ払う", "down": "↓ 下へ払う", "left": "← 左へ払う", "right": "→ 右へ払う", "tap": "● タップ"}
	actMarks  = map[string]string{"up": "↑", "down": "↓", "left": "←", "right": "→", "tap": "●"}
)

const scriptIntro = "〔〕は演出の注釈、（）は間。字は自由に直してください。演出を足したい・変えたい所は〔〕で書けば、AI が台本へ写します。\n" +
	"話し手の名前は「」の前。地の文は名前を書きません。改行はそのまま画面の改行です。ルビは ｜字《よみ》。"

type scriptWriter struct {
	src     ScriptSource
	heads   map[string]string
	number  map[string]int
	byTitle map[string]*Node
	lines   []ScriptLine
}

// BuildScript は読み台本の行（各行が指す .yarn の行つき）を作る。ノードは木の並び（ファイルの名前順・ファイルの中の順）。
func BuildScript(src ScriptSource) []ScriptLine {
	w := &scriptWriter{src: src, heads: map[string]string{}, number: map[string]int{}, byTitle: map[string]*Node{}}
	for k, v := range src.Comments {
		if i := strings.IndexAny(v, ":："); i >= 0 {
			v = strings.TrimSpace(v[:i])
		}
		w.heads[k] = v
	}
	var nodes []*Node
	for _, n := range src.Prog.Nodes {
		if n.Title == "" || w.byTitle[n.Title] != nil {
			continue
		}
		w.byTitle[n.Title] = n
		nodes = append(nodes, n)
		w.number[n.Title] = len(nodes)
	}
	title := "# 読み台本"
	if src.Title != "" {
		title += " — " + src.Title
	}
	w.emit(title, nil)
	w.emit("", nil)
	for _, l := range strings.Split(scriptIntro, "\n") {
		w.emit(l, nil)
	}
	w.emit("", nil)
	for _, n := range nodes {
		w.emit(fmt.Sprintf("## %s　〔%s〕", w.label(n.Title), n.Title), &ScriptRef{File: n.File, Line: n.Line, Node: n.Title, Kind: "node"})
		if c := src.Comments[n.Title]; c != "" {
			w.emit("> "+c, nil)
		}
		w.emit("", nil)
		w.walk(n.Body, n, 0)
		w.emit("", nil)
	}
	return w.lines
}

// RenderScript は読み台本の行を Markdown の字にする。
func RenderScript(lines []ScriptLine) string {
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(l.Text)
		b.WriteByte('\n')
	}
	return b.String()
}

func (w *scriptWriter) emit(text string, ref *ScriptRef) {
	w.lines = append(w.lines, ScriptLine{Text: text, Ref: ref})
}

// label は jump の行き先と見出しに使う「番号「冒頭の文」」。
func (w *scriptWriter) label(title string) string {
	n := w.byTitle[title]
	if n == nil {
		return "（無い場面 " + title + "）"
	}
	return fmt.Sprintf("%d「%s」", w.number[title], headingOf(n, w.heads))
}

func (w *scriptWriter) walk(body []*Stmt, node *Node, depth int) {
	pad := strings.Repeat("　", depth)
	ref := func(line int, kind string) *ScriptRef {
		return &ScriptRef{File: node.File, Line: line, Node: node.Title, Kind: kind}
	}
	var buf []string
	first := 0
	flush := func() {
		if len(buf) > 0 {
			w.emit(pad+strings.Join(buf, ""), ref(first, "cmds"))
			buf = nil
		}
	}
	for _, s := range body {
		if s.Kind == "command" {
			if len(buf) == 0 {
				first = s.Line
			}
			if s.Name == waitCommand {
				buf = append(buf, "（間 "+strings.Join(s.Args, " ")+" 秒）")
			} else {
				buf = append(buf, "〔"+w.src.Notes.Of(s.Name, s.Args)+"〕")
			}
			continue
		}
		flush()
		switch s.Kind {
		case "line":
			r := ref(s.Line, "line")
			r.Speaker = s.Speaker
			w.speech(pad, s.Speaker, readingOf(s.Text, s.Parts), r)
			w.emit("", nil)
		case "options":
			if tags := tagMap(s.Options[0].Tags); len(s.Options) == 1 && tags["act"] != "" {
				o := s.Options[0]
				act := orDefault(actLabels[tags["act"]], tags["act"])
				where := ""
				if at := tags["at"]; at != "" {
					where = "（" + at + " を）"
				}
				shown := ""
				if _, mute := tags["mute"]; !mute {
					shown = "　案内「" + strings.Join(readingOf(o.Text, o.Parts), "／") + "」"
				}
				w.emit(pad+"【"+act+where+"】"+shown, ref(o.Line, "gate"))
				w.walk(o.Body, node, depth+1)
				continue
			}
			w.emit(pad+"◆ 選ぶ", ref(s.Line, "choice"))
			for _, o := range s.Options {
				mark := ""
				if m := actMarks[tagMap(o.Tags)["act"]]; m != "" {
					mark = "（" + m + "）"
				}
				w.emit(pad+"　・"+strings.Join(readingOf(o.Text, o.Parts), "／")+mark, ref(o.Line, "option"))
				w.walk(o.Body, node, depth+2)
			}
		case "jump":
			w.emit(pad+"→ "+w.label(s.Node)+" へ", ref(s.Line, "jump"))
		case "stop":
			w.emit(pad+"■ おわり", ref(s.Line, "stop"))
		case "set":
			w.emit(pad+"〔"+s.Name+" を "+exprText(s.Expr)+" にする〕", ref(s.Line, "flow"))
		case "if":
			for i, c := range s.Clauses {
				head := "〔それ以外〕"
				switch {
				case i == 0:
					head = "〔もし " + exprText(c.Condition) + "〕"
				case c.Condition != nil:
					head = "〔そうでなく、もし " + exprText(c.Condition) + "〕"
				}
				w.emit(pad+head, ref(c.Line, "flow"))
				w.walk(c.Body, node, depth+1)
			}
		default:
			w.emit(pad+"〔"+s.Kind+"〕", ref(s.Line, "flow"))
		}
	}
	flush()
}

// speech は台詞か地の文を、名前「…」の形（続きの行は名前の幅だけ字下げ）か、名前なしで書く。
func (w *scriptWriter) speech(pad, speaker string, parts []string, r *ScriptRef) {
	if speaker == "" {
		for _, p := range parts {
			w.emit(pad+p, r)
		}
		return
	}
	name := orDefault(w.src.Names[speaker], speaker)
	indent := pad + strings.Repeat("　", len([]rune(name))+1)
	for i, p := range parts {
		text := indent + p
		if i == 0 {
			text = pad + name + "「" + p
		}
		if i == len(parts)-1 {
			text += "」"
		}
		w.emit(text, r)
	}
}

func tagMap(tags []Tag) map[string]string {
	m := map[string]string{}
	for _, t := range tags {
		m[t.Key] = t.Value
	}
	return m
}

// readingOf は行の字を読み台本の行に割る（／ と強制の改行で割り、ルビは ｜字《よみ》）。
func readingOf(text string, parts []*Part) []string {
	if len(parts) > 0 {
		var b strings.Builder
		var ruby []string
		for _, p := range parts {
			switch {
			case p.Markup == "ruby":
				ruby = append(ruby, p.Value)
				b.WriteString("｜")
			case p.Close != "" && len(ruby) > 0:
				b.WriteString("《" + ruby[len(ruby)-1] + "》")
				ruby = ruby[:len(ruby)-1]
			case p.Expr != nil:
				b.WriteString("{" + exprText(p.Expr) + "}")
			default:
				b.WriteString(p.Text)
			}
		}
		text = b.String()
	}
	return strings.FieldsFunc(text, func(r rune) bool { return r == '／' || r == '\n' })
}

var readingRubyRe = regexp.MustCompile(`｜([^《]+)《([^》]+)》`)

// yarnText は読み台本の塊の行を、.yarn の 1 行の字に戻す（行は sep でつなぎ、ルビは [ruby=よみ]字[/ruby]）。
func yarnText(lines []string, sep string) string {
	for i, l := range lines {
		lines[i] = strings.TrimSpace(l)
	}
	return readingRubyRe.ReplaceAllString(strings.Join(lines, sep), "[ruby=$2]$1[/ruby]")
}

// lineSeparator は .yarn の台詞が画面の改行に使う書き方（／ か \n）。どちらも無ければ ／。
func lineSeparator(prog *Program) string {
	slash, newline := false, false
	for _, n := range prog.Nodes {
		walk(n.Body, func(s *Stmt) {
			slash = slash || strings.Contains(s.Text, "／")
			newline = newline || strings.Contains(s.Text, "\n")
		})
	}
	if newline && !slash {
		return `\n`
	}
	return "／"
}

// noteMarks は、1 行で 1 つの塊にする行の頭（注釈・間・ゲート・jump・選択肢・おわり・見出し・コメント）。
var noteMarks = []string{"〔", "（間", "【", "→", "◆", "・", "■", "#", ">"}

func isNoteLine(text string) bool {
	t := strings.TrimSpace(text)
	for _, m := range noteMarks {
		if strings.HasPrefix(t, m) {
			return true
		}
	}
	return false
}

type paragraph struct {
	text string
	ref  *ScriptRef
}

// paragraphs は読み台本を塊にする（空行で区切る。noteMarks で始まる行は 1 行で 1 塊。塊の行き先は最初の行の行き先）。
func paragraphs(lines []ScriptLine) []paragraph {
	var out []paragraph
	var cur []string
	var ref *ScriptRef
	end := func() {
		if len(cur) > 0 {
			out = append(out, paragraph{strings.Join(cur, "\n"), ref})
		}
		cur, ref = nil, nil
	}
	for _, l := range lines {
		switch {
		case strings.TrimSpace(l.Text) == "":
			end()
		case isNoteLine(l.Text):
			end()
			out = append(out, paragraph{l.Text, l.Ref})
		default:
			if len(cur) == 0 {
				ref = l.Ref
			}
			cur = append(cur, l.Text)
		}
	}
	end()
	return out
}

type diffOp struct {
	kind           string // equal・replace・insert・delete
	a1, a2, b1, b2 int
}

// diffOps は a と b の最長の共通の並びから、同じ所・書き替え・書き足し・消した所の並びを作る。
func diffOps(a, b []string) []diffOp {
	n, m := len(a), len(b)
	lcs := make([][]int, n+1)
	for i := range lcs {
		lcs[i] = make([]int, m+1)
	}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if a[i] == b[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else {
				lcs[i][j] = max(lcs[i+1][j], lcs[i][j+1])
			}
		}
	}
	var ops []diffOp
	i, j := 0, 0
	gap := func(i2, j2 int) {
		switch {
		case i2 > i && j2 > j:
			ops = append(ops, diffOp{"replace", i, i2, j, j2})
		case i2 > i:
			ops = append(ops, diffOp{"delete", i, i2, j, j2})
		case j2 > j:
			ops = append(ops, diffOp{"insert", i, i2, j, j2})
		}
	}
	for i < n || j < m {
		i2, j2 := i, j
		for i2 < n && j2 < m && a[i2] != b[j2] {
			if lcs[i2+1][j2] >= lcs[i2][j2+1] {
				i2++
			} else {
				j2++
			}
		}
		for i2 < n && j2 == m {
			i2++
		}
		for j2 < m && i2 == n {
			j2++
		}
		gap(i2, j2)
		i, j = i2, j2
		if i < n && j < m {
			ops = append(ops, diffOp{"equal", i, i + 1, j, j + 1})
			i++
			j++
		}
	}
	return ops
}

var speakerHeadRe = regexp.MustCompile(`^\s*([^「」\s]+)「`)

// DiffScript は今の .yarn から作った読み台本 base と、人か AI が直した読み台本 edited を塊ごとに比べ、
// .yarn のどの行をどう直すかを Markdown で返す。names は話し手の id → 表示の名前、sep は台詞の改行の書き方。
func DiffScript(base []ScriptLine, edited string, names map[string]string, sep string) string {
	idOf := map[string]string{}
	for id, name := range names {
		idOf[name] = id
	}
	var editedLines []ScriptLine
	for _, l := range strings.Split(strings.ReplaceAll(edited, "\r\n", "\n"), "\n") {
		editedLines = append(editedLines, ScriptLine{Text: l})
	}
	pa, pb := paragraphs(base), paragraphs(editedLines)
	ta, tb := make([]string, len(pa)), make([]string, len(pb))
	for i, p := range pa {
		ta[i] = p.text
	}
	for i, p := range pb {
		tb[i] = p.text
	}
	out := []string{"# 読み台本の直し → Yarn への写し方", ""}
	count := 0
	kinds := map[string]string{"insert": "書き足し（この行の後へ）", "delete": "消した", "replace": "書き替え"}
	for _, op := range diffOps(ta, tb) {
		if op.kind == "equal" {
			continue
		}
		count++
		var near *ScriptRef
		for _, p := range pa[op.a1:op.a2] {
			if p.ref != nil {
				near = p.ref
				break
			}
		}
		for k := op.a1 - 1; near == nil && k >= 0; k-- {
			near = pa[k].ref
		}
		where := "?"
		if near != nil {
			where = fmt.Sprintf("%s:%d（%s）", near.File, near.Line, near.Node)
		}
		out = append(out, fmt.Sprintf("## %d. %s — %s", count, kinds[op.kind], where))
		for _, p := range pa[op.a1:op.a2] {
			out = append(out, "前:")
			out = append(out, indented(p.text)...)
		}
		for _, p := range pb[op.b1:op.b2] {
			out = append(out, "後:")
			out = append(out, indented(p.text)...)
			out = append(out, "  → "+yarnAdvice(p.text, idOf, sep))
		}
		out = append(out, "")
	}
	if count == 0 {
		out = append(out, "直しはありません。")
	}
	return strings.Join(out, "\n") + "\n"
}

func indented(text string) []string {
	var out []string
	for _, l := range strings.Split(text, "\n") {
		out = append(out, "    "+l)
	}
	return out
}

// yarnAdvice は直した後の塊 1 つの写し方。台詞と地の文はそのまま貼れる .yarn の行、それ以外は何を直すか。
func yarnAdvice(text string, idOf map[string]string, sep string) string {
	t := strings.TrimSpace(text)
	switch {
	case strings.HasPrefix(t, "〔"):
		return "演出の要望。.yarn の冒頭の演出の一覧（か script-notes.json）から当たるコマンドを選んで書く。"
	case strings.HasPrefix(t, "（間"):
		return "間の要望。<<wait 秒>> を足すか直す。"
	case isNoteLine(t):
		return "流れの行（ゲート・選択肢・jump・おわり・見出し）。.yarn の -> と <<jump>> と <<stop>> を手で直す。"
	}
	lines := strings.Split(text, "\n")
	speaker := ""
	if m := speakerHeadRe.FindStringSubmatchIndex(lines[0]); m != nil {
		name := lines[0][m[2]:m[3]]
		speaker = orDefault(idOf[name], name)
		lines[0] = lines[0][m[1]:]
		last := len(lines) - 1
		lines[last] = strings.TrimSuffix(strings.TrimRight(lines[last], " 　"), "」")
	}
	line := yarnText(lines, sep)
	if speaker != "" {
		line = speaker + ": " + line
	}
	return "Yarn の行: `" + line + "`"
}

// storyNames はゲームの assets/novel.story.json の names（話し手の id → 表示の名前）。無ければ空。
func storyNames(root string) map[string]string {
	var story struct {
		Names map[string]string `json:"names"`
	}
	data, err := os.ReadFile(filepath.Join(root, "assets", "novel.story.json"))
	if err != nil || json.Unmarshal(data, &story) != nil || story.Names == nil {
		return map[string]string{}
	}
	return story.Names
}

// scriptNotesName は台本のフォルダに置く注釈の言葉の表（無くてよい）。
const scriptNotesName = "script-notes.json"

// scriptSource は読んだフォルダの読み台本の材料（話し手の名前・注釈の言葉の 2 つの出所・ノードのコメント）。
func (l *loaded) scriptSource() (ScriptSource, error) {
	src := ScriptSource{Title: gameTitleOf(l.root), Prog: l.prog, Comments: map[string]string{}, Names: storyNames(l.root),
		Notes: Notes{File: map[string]string{}, Comment: map[string]string{}}}
	if data, err := os.ReadFile(filepath.Join(l.dir, scriptNotesName)); err == nil {
		m, err := ParseScriptNotes(data)
		if err != nil {
			return src, fmt.Errorf("%s: %v", rel(l.root, filepath.Join(l.dir, scriptNotesName)), err)
		}
		src.Notes.File = m
	}
	for _, text := range l.texts {
		for k, v := range NodeComments(text) {
			src.Comments[k] = v
		}
		for k, v := range CommentNotes(text) {
			if _, ok := src.Notes.Comment[k]; !ok {
				src.Notes.Comment[k] = v
			}
		}
	}
	return src, nil
}

// ForTape は dir（.yarn のあるフォルダ）を読み、テープの頁に埋めるグラフと読み台本の Markdown を返す。
// dir に .yarn が無ければ (nil, "", nil)。
func ForTape(dir string) (*TapeGraph, string, error) {
	groups, err := groupsOf(dir, []string{dir})
	if err != nil || len(groups) == 0 {
		return nil, "", err
	}
	l, err := loadGroup(groups[0], dir, "", false)
	if err != nil {
		return nil, "", err
	}
	src, err := l.scriptSource()
	if err != nil {
		return nil, "", err
	}
	return BuildTapeGraph(l.graph(nil)), RenderScript(BuildScript(src)), nil
}

const scriptUsage = `使い方: bin/fge yarn script <フォルダか x.yarn> [--out <md>]
       bin/fge yarn script --diff <直した.md> <フォルダか x.yarn> [--out <md>]
  1 つのフォルダの .yarn から、ライターが読む台本（Markdown）を書く（既定 <ゲームのルート>/build/yarn-script.md）。
  ノードは「## 番号「冒頭の文」　〔ノード名〕」、話し手は表示の名前（assets/novel.story.json の names）で 名前「…」、
  演出は〔注釈〕・wait は（間 N 秒）・払いのゲートは【…】・選択肢は ◆・jump は →・<<stop>> は ■。／ は画面の改行、ルビは ｜字《よみ》。
  〔〕の言葉の出所: (1) 台本のフォルダの script-notes.json（{"se": "効果音 {args}", "witch on": "魔女が現れる"}）
    (2) .yarn の冒頭のコメントの「//   <<名前 …>>  説明」の行（説明の頭）  (3) どちらにも無ければコマンドの字。
  --diff は直した台本を今の .yarn から作った台本と塊（空行で区切る。〔 （間 【 → ◆ ・ ■ # > で始まる行は 1 行ずつ）で比べ、
  書き替え・書き足し・消したを .yarn のファイル:行（ノード）と前・後で出す（台詞と地の文はそのまま貼れる .yarn の行も）。既定は標準出力。
`

// runScript は fge yarn script の入口。
func runScript(out, errOut *strings.Builder, cwd string, args []string) int {
	var outPath, edited string
	var paths []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; a {
		case "--help", "-h":
			out.WriteString(scriptUsage)
			return 0
		case "--out", "--diff":
			if i+1 >= len(args) {
				errOut.WriteString(a + " の後ろにパスが要る\n" + scriptUsage)
				return 2
			}
			if a == "--out" {
				outPath = args[i+1]
			} else {
				edited = args[i+1]
			}
			i++
		default:
			if strings.HasPrefix(a, "--") {
				errOut.WriteString("知らない指定: " + a + "\n" + scriptUsage)
				return 2
			}
			paths = append(paths, a)
		}
	}
	if len(paths) == 0 {
		errOut.WriteString("フォルダか .yarn を 1 つ渡す（bin/fge yarn script --help）\n")
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
		errOut.WriteString(fmt.Sprintf("読み台本は 1 つのフォルダずつ作る（.yarn のあるフォルダが %d 個ある）\n", len(groups)))
		return 2
	}
	l, err := loadGroup(groups[0], cwd, "", false)
	if err == nil {
		var src ScriptSource
		if src, err = l.scriptSource(); err == nil {
			return writeScript(out, errOut, l, src, abs(outPath), abs(edited))
		}
	}
	errOut.WriteString(err.Error() + "\n")
	return 2
}

func writeScript(out, errOut *strings.Builder, l *loaded, src ScriptSource, outPath, edited string) int {
	lines := BuildScript(src)
	for _, p := range l.checked {
		fmt.Fprintf(out, "注意: %s\n", p.String())
	}
	var text string
	if edited != "" {
		data, err := os.ReadFile(edited)
		if err != nil {
			errOut.WriteString(fmt.Sprintf("直した台本を読めない: %v\n", err))
			return 2
		}
		text = DiffScript(lines, string(data), src.Names, lineSeparator(l.prog))
		if outPath == "" {
			out.WriteString(text)
			return 0
		}
	} else {
		text = RenderScript(lines)
		if outPath == "" {
			outPath = filepath.Join(l.root, "build", "yarn-script.md")
		}
	}
	if err := writeFileMkdir(outPath, []byte(text)); err != nil {
		errOut.WriteString(err.Error() + "\n")
		return 1
	}
	if edited == "" {
		fmt.Fprintf(out, "[yarn script] %d ノード・%d 行を書いた %s\n", countNodes(lines), len(lines), outPath)
	} else {
		fmt.Fprintf(out, "[yarn script] 照らした結果を書いた %s\n", outPath)
	}
	return 0
}

func countNodes(lines []ScriptLine) int {
	n := 0
	for _, l := range lines {
		if l.Ref != nil && l.Ref.Kind == "node" {
			n++
		}
	}
	return n
}
