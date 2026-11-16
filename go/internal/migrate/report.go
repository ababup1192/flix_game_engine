package migrate

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html/template"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// 頁の置き場（--out の中）。
const (
	ReportHTML = "index.html"
	ReportJSON = "report.json"
)

var stepNames = map[int]string{0: "記録", 1: "出来事の並び", 2: "音", 3: "問いの値", 4: "画面の物", 5: "コマ", 6: "古いセーブ"}

// Text は端末に出す要約。門を止める違いを先に、迷った差（止めない）を後に、flow ごとに 20 件まで並べる。
func Text(r *Result, reportPath string) string {
	var b strings.Builder
	if r.Passed {
		b.WriteString("migrate diff: 通った")
	} else {
		b.WriteString("migrate diff: 落ちた")
	}
	hard, review, auto := countOpen(r)
	fmt.Fprintf(&b, "（止める違い %d 件・人が見る迷った差 %d 件（%d 区間）・自動で通した %d 件・承認済み %d 件・通らない命令の行 %d 行・比べたコマ %d 枚）\n",
		hard, review, len(r.Units), auto, len(r.Diffs)-hard-review-auto, countOpenUncovered(r), r.Frames)
	if r.KeySame > 0 || r.CacheHits > 0 {
		fmt.Fprintf(&b, "  （比べたコマのうち、鍵が前と同じで画素を読まなかった %d 枚・覚えた結果で通した %d 枚）\n", r.KeySame, r.CacheHits)
	}
	for _, p := range r.Problems {
		fmt.Fprintf(&b, "  ✗ %s\n", p)
	}
	writeDiffs(&b, r, false, "✗")
	for _, s := range r.Stopped {
		fmt.Fprintf(&b, "  ■ %s は出来事の並びが違うので、後ろ（音・問い・画面の物・コマ）は比べていない\n", s)
	}
	n := 0
	for _, u := range r.Uncovered {
		if u.Accepted {
			continue
		}
		n++
		if n <= 20 {
			fmt.Fprintf(&b, "  ✗ どの flow も通らない: %s:%d %s\n", u.Yarn, u.Line, u.Text)
		}
	}
	if n > 20 {
		fmt.Fprintf(&b, "  … 通らない行の残り %d 行は頁で\n", n-20)
	}
	if len(r.Units) > 0 {
		mark := "?"
		if r.Strict {
			mark = "✗"
		}
		b.WriteString("迷った差（門は止めない。最後に bin/fge migrate video で動画を並べて人が見て、残す物は migrate-accept.json で承認する。秒は新しい版の秒で、並べた動画の字幕と同じ）:\n")
		for _, u := range r.Units {
			fmt.Fprintf(&b, "  %s %s/%s %s %s %s%s: %s\n", mark, u.Flow, u.Size, unitSpan(u), u.What, u.Place, unitCount(u), u.Detail)
		}
	}
	for _, s := range groupSkips(r.Skips) {
		fmt.Fprintf(&b, "  - 比べていない: %s\n", s)
	}
	for _, a := range r.Applied {
		fmt.Fprintf(&b, "  ✓ %s\n", a)
	}
	for _, u := range r.Unused {
		fmt.Fprintf(&b, "  - 使われていない承認: %s\n", u)
	}
	for _, note := range r.Notes {
		fmt.Fprintf(&b, "  - %s\n", note)
	}
	if reportPath != "" {
		fmt.Fprintf(&b, "頁: %s\n", reportPath)
	}
	return b.String()
}

// unitSpan は単位の秒（並べた動画の字幕と同じ書き方）。
func unitSpan(u Unit) string {
	if u.To-u.From < 1e-6 {
		return srtTime(u.From)
	}
	return srtTime(u.From) + "〜" + srtTime(u.To)
}

// unitCount は単位にまとめた差の数と、ほかの flow（1 つの時は空）。
func unitCount(u Unit) string {
	s := ""
	if len(u.Diffs) > 1 {
		s = fmt.Sprintf("（%d 件", len(u.Diffs))
		if len(u.Flows) > 1 {
			s += "・" + strings.Join(u.Flows, " ")
		}
		s += "）"
	}
	return s
}

func writeDiffs(b *strings.Builder, r *Result, review bool, mark string) {
	perFlow := map[string]int{}
	for _, d := range r.Diffs {
		if d.Accepted != "" || d.Review != review {
			continue
		}
		key := d.Flow + "/" + d.Size
		perFlow[key]++
		if perFlow[key] == 21 {
			fmt.Fprintf(b, "  … %s の残りは頁で\n", key)
		}
		if perFlow[key] > 20 {
			continue
		}
		pending := ""
		if d.Pending {
			pending = "（承認待ち）"
		}
		fmt.Fprintf(b, "  %s %s/%s %d.%s %s %.2f秒: %s%s\n", mark, d.Flow, d.Size, d.Step, stepNames[d.Step], place(d), d.T, d.Detail, pending)
	}
}

func place(d *Diff) string {
	if d.Node == "" {
		return "-"
	}
	return fmt.Sprintf("%s#%d", d.Node, d.Seq)
}

// countOpen は承認の無い違いを、門を止める物・人が見る迷った差・自動で通した迷った差に分けて数える。
func countOpen(r *Result) (hard, review, auto int) {
	for _, d := range r.Diffs {
		switch {
		case d.Accepted != "":
		case d.Review && r.needsEye(d):
			review++
		case d.Review:
			auto++
		default:
			hard++
		}
	}
	return hard, review, auto
}

func countOpenUncovered(r *Result) int {
	n := 0
	for _, u := range r.Uncovered {
		if !u.Accepted {
			n++
		}
	}
	return n
}

// groupSkips は同じ理由の「比べていない」を 1 行にまとめる（flow と大きさを並べる）。
func groupSkips(skips []Skip) []string {
	by := map[string][]string{}
	for _, s := range skips {
		key := s.What + ": " + s.Why
		by[key] = append(by[key], s.Flow+"/"+s.Size)
	}
	out := make([]string, 0, len(by))
	for _, k := range sortedKeys(by) {
		out = append(out, fmt.Sprintf("%s（%s）", k, clip(strings.Join(by[k], "・"), 120)))
	}
	return out
}

// WriteReport は out に index.html と report.json を書き、index.html の道を返す。
func WriteReport(r *Result, out string) (string, error) {
	if err := os.MkdirAll(out, 0o755); err != nil {
		return "", err
	}
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(out, ReportJSON), append(data, '\n'), 0o644); err != nil {
		return "", err
	}
	page, err := renderHTML(r, out)
	if err != nil {
		return "", err
	}
	path := filepath.Join(out, ReportHTML)
	return path, os.WriteFile(path, page, 0o644)
}

type htmlDiff struct {
	*Diff
	Index               int
	StepName, Place     string
	Before, After, Heat string
	Images, EntryImages []string
}

type htmlGroup struct {
	Why   string
	Kind  string
	Items []htmlDiff
}

type htmlSection struct {
	Name   string
	Open   []htmlDiff
	Review []htmlDiff
	Auto   []htmlDiff
	Groups []htmlGroup
}

// htmlUnit は目次の 1 行。Video は並べた動画（<out の親>/<flow>.sbs.mp4）があればその秒へ飛ぶ道。
type htmlUnit struct {
	Unit
	Span, Count, Video, Anchor string
}

type htmlKnob struct {
	Name  string
	Value any
}

func addToGroup(groups []htmlGroup, h htmlDiff) []htmlGroup {
	for i := range groups {
		if groups[i].Why == h.Why && groups[i].Kind == h.AcceptKind {
			groups[i].Items = append(groups[i].Items, h)
			return groups
		}
	}
	return append(groups, htmlGroup{Why: h.Why, Kind: h.AcceptKind, Items: []htmlDiff{h}})
}

func renderHTML(r *Result, out string) ([]byte, error) {
	absOut, _ := filepath.Abs(out)
	rel := func(p string) string {
		if p == "" {
			return ""
		}
		abs, err := filepath.Abs(p)
		if err != nil {
			return ""
		}
		s, err := filepath.Rel(absOut, abs)
		if err != nil {
			return ""
		}
		return filepath.ToSlash(s)
	}
	rels := func(ps []string) []string {
		out := make([]string, 0, len(ps))
		for _, p := range ps {
			out = append(out, rel(p))
		}
		return out
	}
	sections := map[string]*htmlSection{}
	var names []string
	var systematic []htmlGroup
	for i, d := range r.Diffs {
		h := htmlDiff{Diff: d, Index: i, StepName: stepNames[d.Step], Place: place(d), Before: rel(d.Before), After: rel(d.After), Heat: rel(d.Heat),
			Images: rels(d.Images), EntryImages: rels(d.EntryImages)}
		if d.AcceptKind == KindSystematic {
			// WhyNot: 系統の違いを flow ごとの節に割らない — 1 つの理由で全部の flow に出る物なので、当たった絵を 1 か所に並べて見る。
			systematic = addToGroup(systematic, h)
			continue
		}
		key := d.Flow + " / " + d.Size
		s := sections[key]
		if s == nil {
			s = &htmlSection{Name: key}
			sections[key] = s
			names = append(names, key)
		}
		switch {
		case d.Accepted == "" && d.Review && !r.needsEye(d):
			s.Auto = append(s.Auto, h)
		case d.Accepted == "" && d.Review:
			s.Review = append(s.Review, h)
		case d.Accepted == "":
			s.Open = append(s.Open, h)
		default:
			s.Groups = addToGroup(s.Groups, h)
		}
	}
	sort.Strings(names)
	var list []*htmlSection
	for _, n := range names {
		list = append(list, sections[n])
	}
	hard, review, auto := countOpen(r)
	units := make([]htmlUnit, 0, len(r.Units))
	for _, u := range r.Units {
		h := htmlUnit{Unit: u, Span: unitSpan(u), Count: unitCount(u), Anchor: "d" + fmt.Sprint(u.Diffs[0])}
		// WhyNot: 動画の名前を記録から読まない — 並べた動画は人が bin/fge migrate video で好きな所に書く。既定の置き場（記録のフォルダの隣）にある時だけ繋ぐ。
		video := filepath.Join(filepath.Dir(absOut), u.Flow+".sbs.mp4")
		if fileExists(video) {
			h.Video = fmt.Sprintf("%s#t=%.3f", rel(video), u.From)
		}
		units = append(units, h)
	}
	var buf bytes.Buffer
	err := pageTemplate.Execute(&buf, map[string]any{
		"R": r, "Sections": list, "Systematic": systematic, "Skips": groupSkips(r.Skips),
		"Open": hard, "Review": review, "Auto": auto, "OpenUncovered": countOpenUncovered(r),
		"Units": units, "Knobs": knobsOf(r.Thresholds),
	})
	return bytes.TrimLeft(buf.Bytes(), "\n"), err
}

// knobsOf は頁に並べる使った線引き（json の名前の順）。
func knobsOf(th Thresholds) []htmlKnob {
	data, _ := json.Marshal(th)
	var m map[string]any
	_ = json.Unmarshal(data, &m)
	out := make([]htmlKnob, 0, len(m))
	for _, k := range sortedKeys(m) {
		out = append(out, htmlKnob{k, m[k]})
	}
	return out
}

var pageTemplate = template.Must(template.New("page").Parse(`{{define "pics"}}{{if or .Before .After}}<div class="pair"><div>{{if .Before}}<img loading="lazy" src="{{.Before}}" alt="前">{{end}}</div><div>{{if .After}}<img loading="lazy" src="{{.After}}" alt="後">{{end}}</div></div>{{end}}
{{if .Heat}}<div class="heat"><img loading="lazy" src="{{.Heat}}" alt="差"></div>{{end}}
{{if .Images}}<div class="muted">新しい版のコマ（前の版の記録が無い）</div><div class="grid">{{range .Images}}<img loading="lazy" src="{{.}}" alt="新しい版">{{end}}</div>{{end}}{{end}}
{{define "line"}}{{.Step}}. {{.StepName}} <code>{{.Flow}} / {{.Size}}</code> <code>{{.Place}}</code> {{printf "%.2f" .T}} 秒 — {{.Detail}}{{end}}
{{define "group"}}<div class="item ok"><div><b>承認済み{{if eq .Kind "systematic"}}（系統の違い）{{end}}</b>: {{.Why}}（{{len .Items}} 件）</div>
{{with index .Items 0}}{{if .EntryImages}}<div class="grid">{{range .EntryImages}}<img loading="lazy" src="{{.}}" alt="承認に添えた絵">{{end}}</div>{{end}}{{end}}
{{range .Items}}<div class="muted">{{template "line" .}}</div>{{template "pics" .}}{{end}}</div>{{end}}
<!DOCTYPE html>
<html lang="ja"><head><meta charset="utf-8"><title>migrate diff</title>
<style>
body{font:14px/1.5 system-ui,sans-serif;background:#16171b;color:#e8e6e1;margin:0;padding:16px 24px}
h1{font-size:20px;margin:0 0 8px} h2{font-size:16px;margin:24px 0 8px;border-bottom:1px solid #444}
.pass{color:#7fd99a} .fail{color:#ff7b72} .muted{color:#9a9790}
.item{margin:8px 0 16px;padding:8px;background:#202127;border-radius:6px}
.item.ok{border-left:4px solid #7fd99a} .item.ng{border-left:4px solid #ff7b72} .item.rv{border-left:4px solid #e9c873}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:8px;max-width:960px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:6px;max-width:960px}
.pair img,.heat img,.grid img{width:100%;image-rendering:pixelated;border:1px solid #333}
.heat{max-width:476px;margin-top:8px}
code{background:#2b2d35;padding:0 4px;border-radius:3px}
li{margin:2px 0}
</style></head><body>
<h1>migrate diff — {{if .R.Passed}}<span class="pass">通った</span>{{else}}<span class="fail">落ちた</span>{{end}}</h1>
<p>止める違い {{.Open}} 件・人が見る迷った差 {{.Review}} 件（{{len .Units}} 区間。止めない。動画を並べて人が見る）・自動で通した迷った差 {{.Auto}} 件{{if .R.NoAuto}}（--no-auto なので人が見る方に数えた）{{end}}・通らない命令の行 {{.OpenUncovered}} 行・比べたコマ {{.R.Frames}} 枚。左が前の版、右が新しい版、下が差の色の図（黄〜赤が差のある所）。</p>
{{if .Units}}<h2>人が見る区間の目次</h2><p class="muted">秒は新しい版の秒（bin/fge migrate video の字幕と同じ）。並べた動画が記録のフォルダの隣にあれば、秒を押すとその所から流れる。</p><ol>
{{range .Units}}<li><code>{{.Flow}} / {{.Size}}</code> {{if .Video}}<a href="{{.Video}}">{{.Span}}</a>{{else}}{{.Span}}{{end}} <a href="#{{.Anchor}}">{{.What}}</a> <code>{{.Place}}</code>{{.Count}} — {{.Detail}}</li>
{{end}}</ol>{{end}}
<details><summary>使った線引き</summary><ul>{{range .Knobs}}<li><code>{{.Name}}</code>: {{.Value}}</li>{{end}}</ul></details>
{{if .R.Problems}}<h2>止まった理由</h2><ul>{{range .R.Problems}}<li class="fail">{{.}}</li>{{end}}</ul>{{end}}
{{if .R.Stopped}}<h2>出来事の並びが違うので後ろを比べていない</h2><ul>{{range .R.Stopped}}<li>{{.}}</li>{{end}}</ul>{{end}}
{{if or .R.Applied .Systematic}}<h2>承認済みの読み替えと系統の違い</h2>
{{if .R.Applied}}<ul>{{range .R.Applied}}<li>{{.}}</li>{{end}}</ul>{{end}}
{{range .Systematic}}{{template "group" .}}{{end}}{{end}}
{{range .Sections}}<h2>{{.Name}}</h2>
{{range .Open}}<div class="item ng"><div><b>止める</b> {{template "line" .}}{{if .Pending}} <span class="muted">（承認待ち: approved が無い）</span>{{end}}</div>{{template "pics" .}}</div>{{end}}
{{range .Review}}<div class="item rv" id="d{{.Index}}"><div><b>迷った差</b> {{template "line" .}}{{if .Pending}} <span class="muted">（承認待ち: approved が無い）</span>{{end}}</div>{{template "pics" .}}</div>{{end}}
{{if .Auto}}<details><summary class="muted">自動で通した迷った差 {{len .Auto}} 件（たたむ）</summary>{{range .Auto}}<div class="item ok"><div><b>自動</b> {{template "line" .}}</div>{{template "pics" .}}</div>{{end}}</details>{{end}}
{{range .Groups}}{{template "group" .}}{{end}}
{{end}}
{{if .R.Uncovered}}<h2>どの flow も通らない命令の行</h2><ul>{{range .R.Uncovered}}<li class="{{if .Accepted}}muted{{else}}fail{{end}}"><code>{{.Yarn}}:{{.Line}}</code> {{.Text}}{{if .Accepted}}（承認済み）{{end}}</li>{{end}}</ul>{{end}}
{{if .R.Unused}}<h2>使われていない承認</h2><ul>{{range .R.Unused}}<li class="muted">{{.}}</li>{{end}}</ul>{{end}}
{{if .Skips}}<h2>比べていない物</h2><ul>{{range .Skips}}<li class="muted">{{.}}</li>{{end}}</ul>{{end}}
{{if .R.Notes}}<h2>注意</h2><ul>{{range .R.Notes}}<li class="muted">{{.}}</li>{{end}}</ul>{{end}}
</body></html>
`))
