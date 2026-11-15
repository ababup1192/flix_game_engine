package yarn

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"html"
	"sort"
	"strconv"
	"strings"
)

//go:embed graph.html
var graphTemplate string

// 箱の大きさと並べる間（px）。見出しの字の大きさは (boxW - 24) / (headingLength + 1) 以下（「…」まで箱に収める）。
const (
	boxW, boxH = 168.0, 64.0
	gapX, gapY = 84.0, 34.0
	margin     = 24.0
)

type detailIn struct {
	From    string            `json:"from"`
	Carried map[string]string `json:"carried"`
}

type detailOut struct {
	To     string `json:"to"`
	Choice string `json:"choice"`
}

type nodeDetail struct {
	Heading  string            `json:"head_text"`
	Rows     []Row             `json:"rows"`
	Head     map[string]string `json:"head"`
	State    map[string]string `json:"state"`
	File     string            `json:"file"`
	Incoming []detailIn        `json:"incoming"`
	Out      []detailOut       `json:"out"`
}

// GraphLayout は箱と矢印の置き場（px）。HTML の SVG とテープの頁の SVG が同じ置き場で描く。
type GraphLayout struct {
	W     float64      `json:"w"`
	H     float64      `json:"h"`
	BoxW  float64      `json:"bw"`
	BoxH  float64      `json:"bh"`
	Nodes []LayoutNode `json:"nodes"`
	Edges []LayoutEdge `json:"edges"`
}

// LayoutNode は箱 1 つ。Kind は lost（たどり着けない）・end（結末）・root（最初のノード）か空。
type LayoutNode struct {
	Title   string  `json:"id"`
	Heading string  `json:"head"`
	X       float64 `json:"x"`
	Y       float64 `json:"y"`
	Kind    string  `json:"kind,omitempty"`
	Sub     string  `json:"sub"`
	Badge   string  `json:"badge,omitempty"`
}

// LayoutEdge は矢印 1 つ（D は SVG の path・LX と LY は選択肢の字の置き場・Label は箱の間に収まる長さの選択肢の字）。
type LayoutEdge struct {
	From   string  `json:"from"`
	To     string  `json:"to"`
	Line   int     `json:"line"`
	D      string  `json:"d"`
	LX     float64 `json:"lx"`
	LY     float64 `json:"ly"`
	Choice string  `json:"choice,omitempty"`
	Label  string  `json:"label,omitempty"`
	Back   bool    `json:"back,omitempty"`
	Tip    string  `json:"tip"`
}

// 縦に並べる時の箱の間（px）。前へ戻る矢印は箱の右を回るので、右に余白を足す。
const (
	gapXV, gapYV = 40.0, 46.0
	backRoomV    = 80.0
)

// LayoutGraph は箱を最初のノードからの深さの列に並べ、矢印の線を引く（無いノードへの矢印は引かない）。
// vertical なら深さを上から下への段にする（縦に長い画面のため）。
func LayoutGraph(g *Graph, vertical bool) GraphLayout {
	byTitle := map[string]*GraphNode{}
	cols := map[int][]*GraphNode{}
	maxCol, maxRows := 0, 1
	for _, n := range g.Nodes {
		byTitle[n.Title] = n
		cols[n.Depth] = append(cols[n.Depth], n)
		if n.Depth > maxCol {
			maxCol = n.Depth
		}
		if len(cols[n.Depth]) > maxRows {
			maxRows = len(cols[n.Depth])
		}
	}
	type point struct{ x, y float64 }
	pos := map[string]point{}
	for c, ns := range cols {
		for r, n := range ns {
			if vertical {
				off := float64(maxRows-len(ns)) * (boxW + gapXV) / 2
				pos[n.Title] = point{margin + off + float64(r)*(boxW+gapXV), margin + float64(c)*(boxH+gapYV)}
			} else {
				off := float64(maxRows-len(ns)) * (boxH + gapY) / 2
				pos[n.Title] = point{margin + float64(c)*(boxW+gapX), margin + off + float64(r)*(boxH+gapY)}
			}
		}
	}
	out := GraphLayout{
		W: margin*2 + float64(maxCol+1)*(boxW+gapX) - gapX, H: margin*2 + float64(maxRows)*(boxH+gapY) - gapY + 60,
		BoxW: boxW, BoxH: boxH, Nodes: []LayoutNode{}, Edges: []LayoutEdge{},
	}
	if vertical {
		out.W = margin*2 + float64(maxRows)*(boxW+gapXV) - gapXV + backRoomV
		out.H = margin*2 + float64(maxCol+1)*(boxH+gapYV) - gapYV
	}
	for _, e := range g.Edges {
		if e.Missing {
			continue
		}
		a, b := pos[e.From], pos[e.To]
		var path string
		var lx, ly float64
		depthGap := abs(float64(byTitle[e.From].Depth - byTitle[e.To].Depth))
		switch {
		case vertical && e.Back:
			x1, y1 := a.x+boxW, a.y+boxH/2
			x2, y2 := b.x+boxW, b.y+boxH/2
			dx := 30 + 10*depthGap
			path = fmt.Sprintf("M%s,%s C%s,%s %s,%s %s,%s", num(x1), num(y1), num(x1+dx), num(y1), num(x2+dx), num(y2), num(x2+6), num(y2))
			lx, ly = max(x1, x2)+dx*0.75, (y1+y2)/2
		case vertical:
			x1, y1 := a.x+boxW/2, a.y+boxH
			x2, y2 := b.x+boxW/2, b.y
			my := (y1 + y2) / 2
			path = fmt.Sprintf("M%s,%s C%s,%s %s,%s %s,%s", num(x1), num(y1), num(x1), num(my), num(x2), num(my), num(x2), num(y2-6))
			lx, ly = (x1+x2)/2, my+4
		case e.Back:
			x1, y1 := a.x+boxW/2, a.y+boxH
			x2, y2 := b.x+boxW/2, b.y+boxH
			dy := 46 + 10*depthGap
			path = fmt.Sprintf("M%s,%s C%s,%s %s,%s %s,%s", num(x1), num(y1), num(x1), num(y1+dy), num(x2), num(y2+dy), num(x2), num(y2+6))
			lx, ly = (x1+x2)/2, max(y1, y2)+dy*0.75
		default:
			x1, y1 := a.x+boxW, a.y+boxH/2
			x2, y2 := b.x, b.y+boxH/2
			mx := (x1 + x2) / 2
			path = fmt.Sprintf("M%s,%s C%s,%s %s,%s %s,%s", num(x1), num(y1), num(mx), num(y1), num(mx), num(y2), num(x2-6), num(y2))
			lx, ly = mx, (y1+y2)/2-6
		}
		tip := fmt.Sprintf("%s → %s（%s:%d）", e.From, e.To, e.File, e.Line)
		if len(e.Carried) > 0 {
			tip += "\n持ち越す舞台: " + kvText(e.Carried)
		}
		label := ""
		if e.Choice != "" {
			label = clip(e.Choice, 14)
		}
		out.Edges = append(out.Edges, LayoutEdge{From: e.From, To: e.To, Line: e.Line, D: path, LX: lx, LY: ly,
			Choice: e.Choice, Label: label, Back: e.Back, Tip: tip})
	}
	for _, n := range g.Nodes {
		p := pos[n.Title]
		kind := ""
		switch {
		case !n.Reachable:
			kind = "lost"
		case n.Ending:
			kind = "end"
		case n.Root:
			kind = "root"
		}
		badge := ""
		switch {
		case n.Ending:
			badge = strings.TrimSpace("結末 " + n.EndingName)
		case n.Root:
			badge = "最初のノード"
		case n.Gates > 0:
			badge = fmt.Sprintf("ゲート %d", n.Gates)
		}
		out.Nodes = append(out.Nodes, LayoutNode{Title: n.Title, Heading: n.Heading, X: p.x, Y: p.y, Kind: kind,
			Sub: fmt.Sprintf("%d 行・%d 演出・約 %.0f 秒待ち", n.Lines, n.Commands, n.WaitSeconds), Badge: badge})
	}
	return out
}

// TapeGraph はテープの頁に埋めるグラフ（横と縦の置き場と、箱を押した時に出す行）。頁は画面に大きく収まる方を使う。
type TapeGraph struct {
	H      GraphLayout           `json:"h"`
	V      GraphLayout           `json:"v"`
	Detail map[string]nodeDetail `json:"detail"`
}

// BuildTapeGraph は g をテープの頁に埋める形にする。
func BuildTapeGraph(g *Graph) *TapeGraph {
	return &TapeGraph{H: LayoutGraph(g, false), V: LayoutGraph(g, true), Detail: nodeDetails(g)}
}

// RenderGraphHTML はグラフを 1 ファイルの HTML にする（CSS と JS は中に持つ）。
func RenderGraphHTML(g *Graph) ([]byte, error) {
	lay := LayoutGraph(g, false)
	var edges strings.Builder
	for _, e := range lay.Edges {
		cls := "edge"
		if e.Back {
			cls += " back"
		}
		if e.Choice != "" {
			cls += " choice"
		}
		fmt.Fprintf(&edges, `<g class="%s" data-from="%s" data-to="%s"><title>%s</title><path d="%s" marker-end="url(#arrow)"/>`,
			cls, esc(e.From), esc(e.To), esc(e.Tip), e.D)
		if e.Label != "" {
			fmt.Fprintf(&edges, `<text x="%s" y="%s" class="elabel">%s</text>`, num(e.LX), num(e.LY), esc(e.Label))
		}
		edges.WriteString("</g>\n")
	}

	var nodes strings.Builder
	for _, n := range lay.Nodes {
		fmt.Fprintf(&nodes, `<g class="node %s" data-node="%s" tabindex="0" role="button" aria-label="%s">`+
			`<rect x="%s" y="%s" width="%s" height="%s" rx="6"/>`+
			`<text x="%s" y="%s" class="ntitle">%s</text><text x="%s" y="%s" class="nid">%s</text><text x="%s" y="%s" class="nsub">%s</text><text x="%s" y="%s" class="nbadge">%s</text></g>`+"\n",
			n.Kind, esc(n.Title), esc(n.Title), num(n.X), num(n.Y), num(boxW), num(boxH),
			num(n.X+12), num(n.Y+22), esc(n.Heading), num(n.X+boxW-8), num(n.Y+56), esc(n.Title), num(n.X+12), num(n.Y+40), esc(n.Sub), num(n.X+12), num(n.Y+56), esc(n.Badge))
	}
	svgW, svgH := lay.W, lay.H

	detailJSON, err := json.Marshal(nodeDetails(g))
	if err != nil {
		return nil, fmt.Errorf("ノードの中身を JSON にできない: %v", err)
	}
	firstNode := ""
	if len(g.Roots) > 0 {
		firstNode = g.Roots[0]
	}
	rootJSON, _ := json.Marshal(firstNode)

	var counts strings.Builder
	for _, c := range g.Commands {
		fmt.Fprintf(&counts, `<li><span class="chip c-%s">%s</span><b>%d</b></li>`, c.Category, esc(c.Name), c.Count)
	}
	var problems strings.Builder
	for _, p := range g.Problems {
		fmt.Fprintf(&problems, `<li class="p-%s">%s:%d: %s</li>`, p.Level, esc(p.File), p.Line, esc(p.Msg))
	}
	if len(g.Problems) == 0 {
		problems.WriteString(`<li class="p-ok">見つかった問題はありません</li>`)
	}
	endNames := make([]string, 0, len(g.Endings))
	for _, e := range g.Endings {
		endNames = append(endNames, orDefault(e, "名前なし"))
	}

	page := strings.NewReplacer(
		"%TITLE%", esc(g.Title),
		"%SRC%", esc(strings.Join(g.Files, " ")),
		"%SVGW%", num(svgW), "%SVGH%", num(svgH),
		"%EDGES%", edges.String(), "%NODES%", nodes.String(),
		"%DETAIL%", strings.ReplaceAll(string(detailJSON), "</", `<\/`),
		"%ROOT%", string(rootJSON),
		"%COUNTS%", counts.String(), "%PROBLEMS%", problems.String(),
		"%NNODES%", strconv.Itoa(len(g.Nodes)), "%NLINES%", strconv.Itoa(g.Lines),
		"%NWAIT%", fmt.Sprintf("%.0f", g.WaitSeconds), "%NEND%", strconv.Itoa(len(g.Endings)),
		"%ENDS%", esc(strings.Join(endNames, "・")),
		"%ROOTS%", esc(strings.Join(g.Roots, "・")),
		"%STAGE%", esc(strings.Join(g.StageKeys, " ")),
	).Replace(graphTemplate)
	return []byte(page), nil
}

// nodeDetails はノードごとの、箱を押した時に出す中身。
func nodeDetails(g *Graph) map[string]nodeDetail {
	details := map[string]nodeDetail{}
	for _, n := range g.Nodes {
		d := nodeDetail{Heading: n.Heading, Rows: n.Rows, Head: n.Head, State: n.State, File: n.File, Incoming: []detailIn{}, Out: []detailOut{}}
		for _, e := range g.Edges {
			if e.To == n.Title {
				d.Incoming = append(d.Incoming, detailIn{e.From, orEmpty(e.Carried)})
			}
			if e.From == n.Title {
				d.Out = append(d.Out, detailOut{e.To, e.Choice})
			}
		}
		details[n.Title] = d
	}
	return details
}

func kvText(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+"="+m[k])
	}
	return strings.Join(parts, "・")
}

func orEmpty(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}

func esc(s string) string { return html.EscapeString(s) }

func num(f float64) string { return strconv.FormatFloat(f, 'f', -1, 64) }

func abs(f float64) float64 {
	if f < 0 {
		return -f
	}
	return f
}
