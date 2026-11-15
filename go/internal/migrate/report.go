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
	hard, review := countOpen(r)
	fmt.Fprintf(&b, "（止める違い %d 件・迷った差 %d 件・承認済み %d 件・通らない命令の行 %d 行・比べたコマ %d 枚）\n",
		hard, review, len(r.Diffs)-hard-review, countOpenUncovered(r), r.Frames)
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
	if review > 0 {
		mark := "?"
		if r.Strict {
			mark = "✗"
		}
		b.WriteString("迷った差（門は止めない。最後に bin/fge migrate video で動画を並べて人が見て、残す物は migrate-accept.json で承認する）:\n")
		writeDiffs(&b, r, true, mark)
	}
	for _, s := range groupSkips(r.Skips) {
		fmt.Fprintf(&b, "  - 比べていない: %s\n", s)
	}
	for _, note := range r.Notes {
		fmt.Fprintf(&b, "  - %s\n", note)
	}
	if reportPath != "" {
		fmt.Fprintf(&b, "頁: %s\n", reportPath)
	}
	return b.String()
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

// countOpen は承認の無い違いを、門を止める物と迷った差に分けて数える。
func countOpen(r *Result) (hard, review int) {
	for _, d := range r.Diffs {
		switch {
		case d.Accepted != "":
		case d.Review:
			review++
		default:
			hard++
		}
	}
	return hard, review
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
	StepName, Place     string
	Before, After, Heat string
}

type htmlGroup struct {
	Why   string
	Items []htmlDiff
}

type htmlSection struct {
	Name   string
	Open   []htmlDiff
	Review []htmlDiff
	Groups []htmlGroup
}

func renderHTML(r *Result, out string) ([]byte, error) {
	rel := func(p string) string {
		if p == "" {
			return ""
		}
		abs, err := filepath.Abs(p)
		if err != nil {
			return ""
		}
		absOut, _ := filepath.Abs(out)
		s, err := filepath.Rel(absOut, abs)
		if err != nil {
			return ""
		}
		return filepath.ToSlash(s)
	}
	sections := map[string]*htmlSection{}
	var names []string
	for _, d := range r.Diffs {
		key := d.Flow + " / " + d.Size
		s := sections[key]
		if s == nil {
			s = &htmlSection{Name: key}
			sections[key] = s
			names = append(names, key)
		}
		h := htmlDiff{Diff: d, StepName: stepNames[d.Step], Place: place(d), Before: rel(d.Before), After: rel(d.After), Heat: rel(d.Heat)}
		if d.Accepted == "" && d.Review {
			s.Review = append(s.Review, h)
			continue
		}
		if d.Accepted == "" {
			s.Open = append(s.Open, h)
			continue
		}
		found := false
		for i := range s.Groups {
			if s.Groups[i].Why == d.Why {
				s.Groups[i].Items = append(s.Groups[i].Items, h)
				found = true
			}
		}
		if !found {
			s.Groups = append(s.Groups, htmlGroup{Why: d.Why, Items: []htmlDiff{h}})
		}
	}
	sort.Strings(names)
	var list []*htmlSection
	for _, n := range names {
		list = append(list, sections[n])
	}
	hard, review := countOpen(r)
	var buf bytes.Buffer
	err := pageTemplate.Execute(&buf, map[string]any{
		"R": r, "Sections": list, "Skips": groupSkips(r.Skips),
		"Open": hard, "Review": review, "OpenUncovered": countOpenUncovered(r),
	})
	return buf.Bytes(), err
}

var pageTemplate = template.Must(template.New("page").Parse(`<!DOCTYPE html>
<html lang="ja"><head><meta charset="utf-8"><title>migrate diff</title>
<style>
body{font:14px/1.5 system-ui,sans-serif;background:#16171b;color:#e8e6e1;margin:0;padding:16px 24px}
h1{font-size:20px;margin:0 0 8px} h2{font-size:16px;margin:24px 0 8px;border-bottom:1px solid #444}
.pass{color:#7fd99a} .fail{color:#ff7b72} .muted{color:#9a9790}
.item{margin:8px 0 16px;padding:8px;background:#202127;border-radius:6px}
.item.ok{border-left:4px solid #7fd99a} .item.ng{border-left:4px solid #ff7b72} .item.rv{border-left:4px solid #e9c873}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:8px;max-width:960px}
.pair img,.heat img{width:100%;image-rendering:pixelated;border:1px solid #333}
.heat{max-width:476px;margin-top:8px}
code{background:#2b2d35;padding:0 4px;border-radius:3px}
li{margin:2px 0}
</style></head><body>
<h1>migrate diff — {{if .R.Passed}}<span class="pass">通った</span>{{else}}<span class="fail">落ちた</span>{{end}}</h1>
<p>止める違い {{.Open}} 件・迷った差 {{.Review}} 件（止めない。動画を並べて人が見る）・通らない命令の行 {{.OpenUncovered}} 行・比べたコマ {{.R.Frames}} 枚。左が前の版、右が新しい版、下が差の色の図（黄〜赤が差のある所）。</p>
{{if .R.Problems}}<h2>止まった理由</h2><ul>{{range .R.Problems}}<li class="fail">{{.}}</li>{{end}}</ul>{{end}}
{{if .R.Stopped}}<h2>出来事の並びが違うので後ろを比べていない</h2><ul>{{range .R.Stopped}}<li>{{.}}</li>{{end}}</ul>{{end}}
{{range .Sections}}<h2>{{.Name}}</h2>
{{range .Open}}<div class="item ng"><div><b>{{.Step}}. {{.StepName}}</b> <code>{{.Place}}</code> {{printf "%.2f" .T}} 秒 — {{.Detail}}{{if .Pending}} <span class="muted">（承認待ち: approved が無い）</span>{{end}}</div>
{{if or .Before .After}}<div class="pair"><div>{{if .Before}}<img src="{{.Before}}" alt="前">{{end}}</div><div>{{if .After}}<img src="{{.After}}" alt="後">{{end}}</div></div>{{end}}
{{if .Heat}}<div class="heat"><img src="{{.Heat}}" alt="差"></div>{{end}}</div>{{end}}
{{range .Review}}<div class="item rv"><div><b>迷った差</b> {{.Step}}. {{.StepName}} <code>{{.Place}}</code> {{printf "%.2f" .T}} 秒 — {{.Detail}}{{if .Pending}} <span class="muted">（承認待ち: approved が無い）</span>{{end}}</div>
{{if or .Before .After}}<div class="pair"><div>{{if .Before}}<img src="{{.Before}}" alt="前">{{end}}</div><div>{{if .After}}<img src="{{.After}}" alt="後">{{end}}</div></div>{{end}}
{{if .Heat}}<div class="heat"><img src="{{.Heat}}" alt="差"></div>{{end}}</div>{{end}}
{{range .Groups}}<div class="item ok"><div><b>承認済み</b>: {{.Why}}（{{len .Items}} 件）</div>
{{range .Items}}<div class="muted">{{.Step}}. {{.StepName}} <code>{{.Place}}</code> {{printf "%.2f" .T}} 秒 — {{.Detail}}</div>
{{if or .Before .After}}<div class="pair"><div>{{if .Before}}<img src="{{.Before}}" alt="前">{{end}}</div><div>{{if .After}}<img src="{{.After}}" alt="後">{{end}}</div></div>{{end}}
{{if .Heat}}<div class="heat"><img src="{{.Heat}}" alt="差"></div>{{end}}{{end}}</div>{{end}}
{{end}}
{{if .R.Uncovered}}<h2>どの flow も通らない命令の行</h2><ul>{{range .R.Uncovered}}<li class="{{if .Accepted}}muted{{else}}fail{{end}}"><code>{{.Yarn}}:{{.Line}}</code> {{.Text}}{{if .Accepted}}（承認済み）{{end}}</li>{{end}}</ul>{{end}}
{{if .Skips}}<h2>比べていない物</h2><ul>{{range .Skips}}<li class="muted">{{.}}</li>{{end}}</ul>{{end}}
{{if .R.Notes}}<h2>注意</h2><ul>{{range .R.Notes}}<li class="muted">{{.}}</li>{{end}}</ul>{{end}}
</body></html>
`))
