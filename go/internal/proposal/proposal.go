// Package proposal は、案を並べて依頼主に選んでもらうページを manifest（proposal.json）から作る。
//
//	fge proposal build <proposal.json...>   隣に index.html を書く
//	fge proposal knobs [proposal.json...]   決定済みなのに Doc に残る案のつまみ（無ければ origin/reports/* を見る）
//
// manifest の形（全部の欄は任意。文言は `code` と **太字** だけ解く。HTML はそのまま出さない）:
//
//	{
//	  "version": 1,
//	  "title": "空振り・盾・加速の演出（案）",
//	  "meta": "2026-10-10 ・ ブランチ ababup1192/id-battlefx",
//	  "lead": "どの動画も同じ戦いの同じ拍を 60fps で描き出した物。",
//	  "sections": [
//	    {"title": "いまの演出", "table": [["拍", "絵"], ["空振り", "!上と同じ"]]},   // 先頭 ! = 弱い所
//	    {"id": "A", "title": "解除・浄化の空振り", "lead": "場面: …",
//	     "knob": {"doc": "assets/x.cue.json", "path": "battleFx.missStyle"},
//	     "compare": {"src": "miss_compare.mp4", "caption": "左上 = いま / 右上 = A1 …"},
//	     "options": [
//	       {"id": "A0", "label": "いま", "value": "plain", "baseline": true, "text": "…", "media": ["miss_before.mp4"]},
//	       {"id": "A1", "label": "空を切る", "value": "cut", "rec": true, "text": "…", "media": ["miss_a1.mp4"]}
//	     ]}
//	  ],
//	  "recommend": ["**A は A1**: …"],
//	  "ask": ["① どれが良いか", "② 続けるか"],
//	  "decision": {"picks": {"A": "A1"}, "date": "2026-10-11"}
//	}
//
// media の 1 つは文字列（拡張子で img / video / audio）か {"src", "caption", "pixel": true（実寸・ドットのまま）}。
// options のある節は選べる節。ページ下の帯に「決定: A1 B2」が出て、コピーで返事にそのまま貼れる。
// decision を書くと、その節は採用の札が付き、knob を持つ節には「消すつまみ」が並ぶ（knobs が後で数える）。
//
// WhyNot: 部品（会話の窓など、実機の見本を CSS で作り直す物）はここに入れない。実機と二重管理になる。
// 素材は実機の描き出しと動画だけ。
package proposal

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// Usage は引数が足りない時に出す。
const Usage = `使い方: fge proposal build <proposal.json...>   隣に index.html を書く
        fge proposal knobs [proposal.json...]   決定済みなのに Doc に残る案のつまみを数える`

// Run は fge proposal の入口。
func Run(args []string, out, errOut io.Writer) int {
	if len(args) >= 2 && args[0] == "build" {
		worst := 0
		for _, p := range args[1:] {
			worst = max(worst, Build(p, out, errOut))
		}
		return worst
	}
	if len(args) >= 1 && args[0] == "knobs" {
		return Knobs(args[1:], out, errOut)
	}
	fmt.Fprintln(out, Usage)
	return 2
}

// ── JSON（キーの順番を保つ） ─────────────────────────────

// object は JSON のオブジェクトをキーの順番ごと持つ。
//
// WhyNot: map[string]any で読まないのは、案の value（オブジェクトもある）をページに
// そのまま書き戻すとき、キーの順番が書いた人の順でなくなるため。
type object struct {
	keys []string
	vals map[string]any
}

func decode(data []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	v, err := decodeValue(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, fmt.Errorf("JSON の後ろに余計な物がある")
	}
	return v, nil
}

func decodeValue(dec *json.Decoder) (any, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			o := &object{vals: map[string]any{}}
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				k := kt.(string)
				v, err := decodeValue(dec)
				if err != nil {
					return nil, err
				}
				if _, dup := o.vals[k]; !dup {
					o.keys = append(o.keys, k)
				}
				o.vals[k] = v
			}
			_, err := dec.Token()
			return o, err
		case '[':
			list := []any{}
			for dec.More() {
				v, err := decodeValue(dec)
				if err != nil {
					return nil, err
				}
				list = append(list, v)
			}
			_, err := dec.Token()
			return list, err
		}
	}
	return tok, nil
}

func get(v any, key string) any {
	if o, ok := v.(*object); ok {
		return o.vals[key]
	}
	return nil
}

func has(v any, key string) bool {
	if o, ok := v.(*object); ok {
		_, found := o.vals[key]
		return found
	}
	return false
}

func list(v any) []any {
	l, _ := v.([]any)
	return l
}

// truthy は Python の真偽の読み方（空の文字列・0・空の列は偽）。
func truthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case bool:
		return t
	case string:
		return t != ""
	case json.Number:
		f, err := t.Float64()
		return err != nil || f != 0
	case []any:
		return len(t) > 0
	case *object:
		return len(t.keys) > 0
	}
	return true
}

// str は Python の str() と同じ形の文字列。
func str(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case nil:
		return "None"
	case bool:
		if t {
			return "True"
		}
		return "False"
	case json.Number:
		return string(t)
	}
	return dumps(v)
}

// dumps は Python の json.dumps(v, ensure_ascii=False) と同じ形（", " と ": " で区切る）。
func dumps(v any) string {
	var b strings.Builder
	writeDumps(&b, v)
	return b.String()
}

func writeDumps(b *strings.Builder, v any) {
	switch t := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if t {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case json.Number:
		b.WriteString(string(t))
	case string:
		b.WriteByte('"')
		for _, r := range t {
			switch r {
			case '"':
				b.WriteString(`\"`)
			case '\\':
				b.WriteString(`\\`)
			case '\n':
				b.WriteString(`\n`)
			case '\r':
				b.WriteString(`\r`)
			case '\t':
				b.WriteString(`\t`)
			case '\b':
				b.WriteString(`\b`)
			case '\f':
				b.WriteString(`\f`)
			default:
				if r < 0x20 {
					fmt.Fprintf(b, `\u%04x`, r)
				} else {
					b.WriteRune(r)
				}
			}
		}
		b.WriteByte('"')
	case []any:
		b.WriteByte('[')
		for i, x := range t {
			if i > 0 {
				b.WriteString(", ")
			}
			writeDumps(b, x)
		}
		b.WriteByte(']')
	case *object:
		b.WriteByte('{')
		for i, k := range t.keys {
			if i > 0 {
				b.WriteString(", ")
			}
			writeDumps(b, k)
			b.WriteString(": ")
			writeDumps(b, t.vals[k])
		}
		b.WriteByte('}')
	}
}

// ── 文言 ─────────────────────────────────────────────────

var codeRe = regexp.MustCompile("`([^`]+)`")
var boldRe = regexp.MustCompile(`\*\*([^*]+)\*\*`)

func escape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

func attr(v any) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&#x27;").Replace(str(v))
}

// text は文言を HTML へ。エスケープの後に `code` と **太字** だけ解く。
func text(v any) string {
	s := str(v)
	var b strings.Builder
	plain := func(part string) {
		b.WriteString(boldRe.ReplaceAllString(escape(part), "<b>$1</b>"))
	}
	last := 0
	for _, m := range codeRe.FindAllStringSubmatchIndex(s, -1) {
		plain(s[last:m[0]])
		b.WriteString("<code>" + escape(s[m[2]:m[3]]) + "</code>")
		last = m[1]
	}
	plain(s[last:])
	return b.String()
}

// ── ページ ───────────────────────────────────────────────

var (
	imgExt = map[string]bool{".png": true, ".jpg": true, ".jpeg": true, ".gif": true, ".webp": true, ".svg": true}
	vidExt = map[string]bool{".mp4": true, ".webm": true, ".mov": true}
	audExt = map[string]bool{".wav": true, ".mp3": true, ".ogg": true, ".m4a": true}
)

type builder struct {
	root    string
	missing []string
}

// extOf は Python の os.path.splitext と同じく、名前の頭の . は拡張子に数えない。
func extOf(p string) string {
	base := strings.TrimLeft(filepath.Base(p), ".")
	return strings.ToLower(filepath.Ext(base))
}

func (b *builder) media(m any, loop bool) string {
	if s, ok := m.(string); ok {
		o := &object{keys: []string{"src"}, vals: map[string]any{"src": s}}
		m = o
	}
	src := str(get(m, "src"))
	ext := extOf(src)
	if _, err := os.Stat(filepath.Join(b.root, src)); err != nil {
		b.missing = append(b.missing, src)
	}
	a := attr(src)
	var tag string
	switch {
	case vidExt[ext]:
		l := ""
		if loop {
			l = " loop"
		}
		tag = `<video src="` + a + `" controls` + l + ` playsinline preload="metadata"></video>`
	case audExt[ext]:
		tag = `<audio src="` + a + `" controls preload="none"></audio>`
	case imgExt[ext]:
		alt := attr(src)
		if has(m, "caption") {
			alt = attr(get(m, "caption"))
		}
		tag = `<img src="` + a + `" alt="` + alt + `" loading="lazy">`
		if truthy(get(m, "pixel")) {
			tag = `<div class="pixel">` + tag + `</div>`
		}
	default:
		tag = `<a href="` + a + `">` + text(src) + `</a>`
	}
	caption := ""
	if truthy(get(m, "caption")) {
		caption = "<figcaption>" + text(get(m, "caption")) + "</figcaption>"
	}
	return "<figure>" + tag + caption + "</figure>"
}

func (b *builder) table(rows []any) string {
	var head []string
	for _, c := range list(rows[0]) {
		head = append(head, "<th>"+text(c)+"</th>")
	}
	out := []string{`<div class="table-wrap"><table>`, "<tr>" + strings.Join(head, "") + "</tr>"}
	for _, r := range rows[1:] {
		var cells []string
		for _, c := range list(r) {
			s := str(c)
			if strings.HasPrefix(s, "!") {
				cells = append(cells, `<td class="weak">`+text(s[1:])+"</td>")
			} else {
				cells = append(cells, "<td>"+text(s)+"</td>")
			}
		}
		out = append(out, "<tr>"+strings.Join(cells, "")+"</tr>")
	}
	return strings.Join(append(out, "</table></div>"), "\n")
}

func (b *builder) option(sec, o any, won any) string {
	decided := won != nil
	sid, oid := get(sec, "id"), get(o, "id")
	isWon := decided && str(won) == str(oid)
	tags := ""
	if truthy(get(o, "baseline")) {
		tags += `<span class="tag base">いま</span>`
	}
	if truthy(get(o, "rec")) {
		tags += `<span class="tag">おすすめ</span>`
	}
	if isWon {
		tags += `<span class="tag won">採用</span>`
	}
	val := ""
	if has(o, "value") {
		val = ` <span class="knob">= <code>` + text(dumps(get(o, "value"))) + `</code></span>`
	}
	radio := ""
	if !decided {
		radio = `<input type="radio" name="` + attr(sid) + `" value="` + attr(oid) + `"`
		if truthy(get(o, "rec")) {
			radio += " checked"
		}
		radio += ">"
	}
	label := ""
	if has(o, "label") {
		label = text(get(o, "label"))
	}
	body := "<h3>" + radio + "<span>" + text(oid) + " " + label + "</span>" + tags + val + "</h3>"
	if truthy(get(o, "text")) {
		body += "<p>" + text(get(o, "text")) + "</p>"
	}
	for _, m := range list(get(o, "media")) {
		body += b.media(m, false)
	}
	if decided {
		class := "card lost"
		if isWon {
			class = "card"
		}
		return `<div class="` + class + `">` + body + `</div>`
	}
	return `<label class="card">` + body + `</label>`
}

// valueOrID は Python の o.get("value", o["id"]) を json.dumps した物。
func valueOrID(o any) string {
	if has(o, "value") {
		return dumps(get(o, "value"))
	}
	return dumps(get(o, "id"))
}

// cleanup は決定済みの節で、負けた案を消すまでの手順（つまみ・値）。
func (b *builder) cleanup(sec, won any) string {
	k := get(sec, "knob")
	if !truthy(k) {
		return ""
	}
	var lose []string
	keep := str(won)
	for _, o := range list(get(sec, "options")) {
		if str(get(o, "id")) == str(won) {
			keep = valueOrID(o)
			break
		}
	}
	for _, o := range list(get(sec, "options")) {
		if str(get(o, "id")) != str(won) && !truthy(get(o, "baseline")) {
			lose = append(lose, valueOrID(o))
		}
	}
	lost := strings.Join(lose, " / ")
	if lost == "" {
		lost = "なし"
	}
	return `<div class="clean"><b>片付け</b>: <code>` + text(get(k, "doc")) + `</code> の <code>` + text(get(k, "path")) +
		`</code> を消し、<code>` + text(keep) + `</code> の形だけ残す（負けた値: ` + text(lost) + `）。` +
		`残っているかは <code>bin/fge proposal knobs</code> で数える。</div>`
}

func pickOf(picks any, sec any) any {
	if !has(sec, "id") {
		return nil
	}
	return get(picks, str(get(sec, "id")))
}

func (b *builder) section(sec, picks any) string {
	out := []string{"<h2>" + text(orEmpty(sec, "title")) + "</h2>"}
	if truthy(get(sec, "lead")) {
		out = append(out, `<p class="lead">`+text(get(sec, "lead"))+"</p>")
	}
	for _, p := range list(get(sec, "paragraphs")) {
		out = append(out, "<p>"+text(p)+"</p>")
	}
	if truthy(get(sec, "table")) {
		out = append(out, b.table(list(get(sec, "table"))))
	}
	if truthy(get(sec, "options")) {
		won := pickOf(picks, sec)
		k := get(sec, "knob")
		if truthy(k) && won == nil {
			out = append(out, `<p class="knob">切り替え: <code>`+text(get(k, "doc"))+`</code> の <code>`+text(get(k, "path"))+"</code></p>")
		}
		if truthy(get(sec, "compare")) {
			out = append(out, `<div class="card compare">`+b.media(get(sec, "compare"), true)+"</div>")
		}
		// ドット絵の実寸は縮めると読めないので、案を縦に 1 列で積む
		pixel := false
		for _, o := range list(get(sec, "options")) {
			for _, x := range list(get(o, "media")) {
				if truthy(get(x, "pixel")) {
					pixel = true
				}
			}
		}
		class := "grid"
		if pixel {
			class = "stack"
		}
		choice := ""
		if won == nil {
			choice = ` choice" data-id="` + attr(get(sec, "id"))
		}
		var opts []string
		for _, o := range list(get(sec, "options")) {
			opts = append(opts, b.option(sec, o, won))
		}
		out = append(out, `<div class="`+class+choice+`">`+strings.Join(opts, "\n")+"</div>")
		if won != nil {
			out = append(out, b.cleanup(sec, won))
		}
	}
	return strings.Join(out, "\n")
}

func orEmpty(v any, key string) any {
	if has(v, key) {
		return get(v, key)
	}
	return ""
}

func picksOf(m any) any {
	d := get(m, "decision")
	if !truthy(d) {
		return nil
	}
	return get(d, "picks")
}

func (b *builder) page(m any) string {
	picks := picksOf(m)
	openQ := false
	for _, s := range list(get(m, "sections")) {
		if truthy(get(s, "options")) && !hasPick(picks, s) {
			openQ = true
		}
	}
	body := []string{"<h1>" + text(orEmpty(m, "title")) + "</h1>"}
	if truthy(get(m, "meta")) {
		body = append(body, `<p class="meta">`+text(get(m, "meta"))+"</p>")
	}
	if truthy(get(m, "lead")) {
		body = append(body, `<p class="lead">`+text(get(m, "lead"))+"</p>")
	}
	for _, s := range list(get(m, "sections")) {
		body = append(body, b.section(s, picks))
	}
	for _, part := range []struct{ key, title string }{{"recommend", "おすすめ"}, {"ask", "聞きたいこと"}} {
		if !truthy(get(m, part.key)) {
			continue
		}
		var ps []string
		for _, p := range list(get(m, part.key)) {
			ps = append(ps, "<p>"+text(p)+"</p>")
		}
		body = append(body, "<h2>"+part.title+`</h2><div class="rec">`+strings.Join(ps, "")+"</div>")
	}
	bar := ""
	if openQ {
		bar = `<div class="bar"><output></output><button type="button">コピー</button>` +
			"<small>カードを押して選び、この 1 行を返事に貼る</small></div>" +
			"<script>" + js + "</script>"
	}
	title := "案"
	if has(m, "title") {
		title = str(get(m, "title"))
	}
	return "<!doctype html>\n<html lang=\"ja\"><head><meta charset=\"utf-8\">" +
		"<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
		"<title>" + text(title) + "</title><style>" + css + "</style></head><body><main>\n" +
		strings.Join(body, "\n") + "\n</main>" + bar + "</body></html>\n"
}

func hasPick(picks, sec any) bool {
	if !has(sec, "id") {
		return false
	}
	return has(picks, str(get(sec, "id")))
}

// ── 検査 ─────────────────────────────────────────────────

// validate は壊れた manifest を「節:欄」の 1 行ずつで返す（空なら通る）。
func validate(m any) []string {
	if _, ok := m.(*object); !ok {
		return []string{"manifest がオブジェクトでない"}
	}
	var errs []string
	ids := map[string]bool{}
	for i, sec := range list(get(m, "sections")) {
		where := fmt.Sprintf("sections[%d]", i)
		opts := list(get(sec, "options"))
		if !truthy(get(sec, "options")) {
			continue
		}
		id := get(sec, "id")
		switch {
		case !truthy(id):
			errs = append(errs, where+": options のある節に id が無い")
		case ids[str(id)]:
			errs = append(errs, fmt.Sprintf("%s: id %s が重なっている", where, str(id)))
		}
		ids[str(id)] = true
		if has(sec, "knob") && get(sec, "knob") != nil {
			k := get(sec, "knob")
			if _, ok := k.(*object); !ok || !truthy(get(k, "doc")) || !truthy(get(k, "path")) {
				errs = append(errs, where+".knob: doc と path が要る")
			}
		}
		for j, o := range opts {
			if !truthy(get(o, "id")) {
				errs = append(errs, fmt.Sprintf("%s.options[%d]: id が無い", where, j))
			}
			for n, x := range list(get(o, "media")) {
				if _, ok := x.(*object); ok && !truthy(get(x, "src")) {
					errs = append(errs, fmt.Sprintf("%s.options[%d].media[%d]: src が無い", where, j, n))
				}
			}
		}
		if c, ok := get(sec, "compare").(*object); ok && !truthy(get(c, "src")) {
			errs = append(errs, where+".compare: src が無い")
		}
	}
	picks, _ := picksOf(m).(*object)
	if picks == nil {
		return errs
	}
	secs := map[string]any{}
	for _, s := range list(get(m, "sections")) {
		if truthy(get(s, "options")) {
			secs[str(get(s, "id"))] = s
		}
	}
	for _, sid := range picks.keys {
		oid := picks.vals[sid]
		sec, ok := secs[sid]
		if !ok {
			errs = append(errs, fmt.Sprintf("decision.picks.%s: その id の節が無い", sid))
			continue
		}
		found := false
		for _, o := range list(get(sec, "options")) {
			if str(get(o, "id")) == str(oid) {
				found = true
			}
		}
		if !found {
			errs = append(errs, fmt.Sprintf("decision.picks.%s: %s は options に無い", sid, str(oid)))
		}
	}
	return errs
}

func load(name string, data []byte) (any, []string) {
	m, err := decode(data)
	if err != nil {
		return nil, []string{fmt.Sprintf("%s: JSON が読めない（%v）", name, err)}
	}
	var errs []string
	for _, e := range validate(m) {
		errs = append(errs, name+": "+e)
	}
	return m, errs
}

// Build は manifest の隣に index.html を書く。0 = 書けた / 1 = 素材が欠けている / 2 = manifest が壊れている。
func Build(path string, out, errOut io.Writer) int {
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(errOut, "%s: 読めない（%v）\n", path, err)
		return 2
	}
	m, errs := load(path, data)
	if len(errs) > 0 {
		fmt.Fprintln(errOut, strings.Join(errs, "\n"))
		return 2
	}
	abs, _ := filepath.Abs(path)
	b := &builder{root: filepath.Dir(abs)}
	page := b.page(m)
	target := filepath.Join(b.root, "index.html")
	if err := os.WriteFile(target, []byte(page), 0o644); err != nil {
		fmt.Fprintf(errOut, "%s を書けない（%v）\n", target, err)
		return 2
	}
	for _, s := range b.missing {
		fmt.Fprintf(errOut, "proposal: 素材が無い: %s\n", s)
	}
	fmt.Fprintf(out, "%s (%d 行)\n", target, strings.Count(page, "\n"))
	if len(b.missing) > 0 {
		return 1
	}
	return 0
}

// ── つまみの片付け ───────────────────────────────────────

func git(args ...string) string {
	out, _ := exec.Command("git", args...).Output()
	return string(out)
}

type manifest struct {
	name string
	data []byte
}

// manifestsFromReports は origin/reports/* の各ブランチにある proposal.json を集める。fetch はしない。
func manifestsFromReports(errOut io.Writer) []manifest {
	fmt.Fprintln(errOut, "proposal: origin/reports/* を読む（新しい決定が要るなら先に git fetch）")
	var found []manifest
	for _, r := range strings.Fields(git("for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/reports/")) {
		for _, f := range strings.Fields(git("ls-tree", "-r", "--name-only", r)) {
			if strings.HasSuffix(f, "proposal.json") {
				found = append(found, manifest{r + ":" + f, []byte(git("show", r+":"+f))})
			}
		}
	}
	return found
}

func hasPath(doc any, path string) bool {
	cur := doc
	for _, k := range strings.Split(path, ".") {
		if !has(cur, k) {
			return false
		}
		cur = get(cur, k)
	}
	return true
}

// srcHits は負けた値の文字列リテラル（Doc を enum に読み替える所）がまだ src/ にあるファイル。
func srcHits(top string, value any) []string {
	if _, ok := value.(string); !ok {
		return nil
	}
	lit := []byte(dumps(value))
	var hits []string
	filepath.Walk(filepath.Join(top, "src"), func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() || !strings.HasSuffix(p, ".flix") {
			return nil
		}
		if data, err := os.ReadFile(p); err == nil && bytes.Contains(data, lit) {
			rel, _ := filepath.Rel(top, p)
			hits = append(hits, rel)
		}
		return nil
	})
	return hits
}

// Knobs は決定済みの節ごとに、Doc のつまみ（knob.keep で外せる）と負けた値の src/ の読み替えが
// 残っていないか数える。残りがあれば 1。
func Knobs(paths []string, out, errOut io.Writer) int {
	top := strings.TrimSpace(git("rev-parse", "--show-toplevel"))
	if top == "" {
		top, _ = os.Getwd()
	}
	var items []manifest
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			fmt.Fprintf(errOut, "%s: 読めない（%v）\n", p, err)
			return 2
		}
		items = append(items, manifest{p, data})
	}
	if len(paths) == 0 {
		items = manifestsFromReports(errOut)
	}
	left := 0
	seen := map[string]bool{}
	for _, it := range items {
		m, errs := load(it.name, it.data)
		if len(errs) > 0 {
			fmt.Fprintln(errOut, strings.Join(errs, "\n"))
			left++
			continue
		}
		picks := picksOf(m)
		for _, sec := range list(get(m, "sections")) {
			k := get(sec, "knob")
			won := pickOf(picks, sec)
			if !truthy(k) || won == nil {
				continue
			}
			key := str(get(k, "doc")) + "\x00" + str(get(k, "path"))
			if seen[key] {
				continue
			}
			seen[key] = true
			raw, err := os.ReadFile(filepath.Join(top, str(get(k, "doc"))))
			var doc any
			if err == nil {
				doc, err = decode(raw)
			}
			if err != nil {
				left++
				fmt.Fprintf(out, "%s: %s が読めない（%v）\n", it.name, str(get(k, "doc")), err)
				continue
			}
			if !truthy(get(k, "keep")) && hasPath(doc, str(get(k, "path"))) {
				left++
				fmt.Fprintf(out, "%s: %s は %s に決定済み — %s の %s が残っている\n",
					it.name, str(get(sec, "id")), str(won), str(get(k, "doc")), str(get(k, "path")))
			}
			for _, o := range list(get(sec, "options")) {
				if str(get(o, "id")) == str(won) || !has(o, "value") {
					continue
				}
				if hits := srcHits(top, get(o, "value")); len(hits) > 0 {
					left++
					fmt.Fprintf(out, "%s: %s の負けた案 %s（%s）が src に残る: %s\n", it.name, str(get(sec, "id")),
						str(get(o, "id")), dumps(get(o, "value")), strings.Join(hits, " "))
				}
			}
		}
	}
	fmt.Fprintf(out, "残っている片付け: %d\n", left)
	if left > 0 {
		return 1
	}
	return 0
}
