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

// 箱の大きさと並べる間（px）。
const (
	boxW, boxH = 168.0, 64.0
	gapX, gapY = 84.0, 34.0
	margin     = 24.0
)

type detailBand struct {
	C string  `json:"c"`
	N string  `json:"n"`
	A string  `json:"a"`
	W float64 `json:"w"`
	L int     `json:"l"`
}

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
	Strip    []detailBand      `json:"strip"`
	Rows     []Row             `json:"rows"`
	Head     map[string]string `json:"head"`
	State    map[string]string `json:"state"`
	File     string            `json:"file"`
	Incoming []detailIn        `json:"incoming"`
	Out      []detailOut       `json:"out"`
}

// RenderGraphHTML はグラフを 1 ファイルの HTML にする（CSS と JS は中に持つ）。
func RenderGraphHTML(g *Graph) ([]byte, error) {
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
		off := float64(maxRows-len(ns)) * (boxH + gapY) / 2
		for r, n := range ns {
			pos[n.Title] = point{margin + float64(c)*(boxW+gapX), margin + off + float64(r)*(boxH+gapY)}
		}
	}
	svgW := margin*2 + float64(maxCol+1)*(boxW+gapX) - gapX
	svgH := margin*2 + float64(maxRows)*(boxH+gapY) - gapY + 60

	var edges strings.Builder
	for _, e := range g.Edges {
		if e.Missing {
			continue
		}
		a, b := pos[e.From], pos[e.To]
		var path string
		var lx, ly float64
		if e.Back {
			x1, y1 := a.x+boxW/2, a.y+boxH
			x2, y2 := b.x+boxW/2, b.y+boxH
			dy := 46 + 10*abs(float64(byTitle[e.From].Depth-byTitle[e.To].Depth))
			path = fmt.Sprintf("M%s,%s C%s,%s %s,%s %s,%s", num(x1), num(y1), num(x1), num(y1+dy), num(x2), num(y2+dy), num(x2), num(y2+6))
			lx, ly = (x1+x2)/2, max(y1, y2)+dy*0.75
		} else {
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
		cls := "edge"
		if e.Back {
			cls += " back"
		}
		if e.Choice != "" {
			cls += " choice"
		}
		fmt.Fprintf(&edges, `<g class="%s" data-from="%s" data-to="%s"><title>%s</title><path d="%s" marker-end="url(#arrow)"/>`,
			cls, esc(e.From), esc(e.To), esc(tip), path)
		if e.Choice != "" {
			fmt.Fprintf(&edges, `<text x="%s" y="%s" class="elabel">%s</text>`, num(lx), num(ly), esc(clip(e.Choice, 14)))
		}
		edges.WriteString("</g>\n")
	}

	var nodes strings.Builder
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
		sub := fmt.Sprintf("%d 行・%d 演出・約 %.0f 秒待ち", n.Lines, n.Commands, n.WaitSeconds)
		badge := ""
		switch {
		case n.Ending:
			badge = strings.TrimSpace("結末 " + n.EndingName)
		case n.Root:
			badge = "最初のノード"
		case n.Gates > 0:
			badge = fmt.Sprintf("ゲート %d", n.Gates)
		}
		fmt.Fprintf(&nodes, `<g class="node %s" data-node="%s" tabindex="0" role="button" aria-label="%s">`+
			`<rect x="%s" y="%s" width="%s" height="%s" rx="6"/>`+
			`<text x="%s" y="%s" class="ntitle">%s</text><text x="%s" y="%s" class="nid">%s</text><text x="%s" y="%s" class="nsub">%s</text><text x="%s" y="%s" class="nbadge">%s</text></g>`+"\n",
			kind, esc(n.Title), esc(n.Title), num(p.x), num(p.y), num(boxW), num(boxH),
			num(p.x+12), num(p.y+22), esc(n.Heading), num(p.x+boxW-8), num(p.y+14), esc(n.Title), num(p.x+12), num(p.y+40), esc(sub), num(p.x+12), num(p.y+56), esc(badge))
	}

	details := map[string]nodeDetail{}
	for _, n := range g.Nodes {
		d := nodeDetail{Heading: n.Heading, Strip: []detailBand{}, Rows: n.Rows, Head: n.Head, State: n.State, File: n.File, Incoming: []detailIn{}, Out: []detailOut{}}
		for _, b := range n.Strip {
			d.Strip = append(d.Strip, detailBand{b.Category, b.Name, b.Args, b.Seconds, b.Line})
		}
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
	detailJSON, err := json.Marshal(details)
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
