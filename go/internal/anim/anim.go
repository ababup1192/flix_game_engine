package anim

// anim — コマ列と 4 方向のそろい方を機械で確かめるゲート。
//
//	fge-go anim [a.sprite.json ...] [--strict] [--self-test]
//
// 引数が無ければ templates/ 配下の *.sprite.json を全部見る。
//
// 見るのは「1 枚の絵の質」ではなく絵と絵の関係:
//
//	コマ列   — 入れ替わり (pop) / 面積 (area) / 接地 (ground) / 上下動 (bob) /
//	           輪の継ぎ目 (loop) / コマごとの色 (palette)
//	4 方向   — 接地行・頭の高さ・足元の中心・横幅の比・前後の重なり・左右の反転・色 (view)

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

// --- 順番を保つ JSON ------------------------------------------------------

// obj は書かれた順を覚えている JSON オブジェクト。
//
// WhyNot: map[string]any に落とさないのは、書かれた順のまま
// {'front': 5, 'side': 7} と出力に混ぜるため。順を捨てると字面が変わる。
type obj struct {
	keys []string
	m    map[string]any
}

func (o *obj) get(key string) (any, bool) {
	if o == nil {
		return nil, false
	}
	v, ok := o.m[key]
	return v, ok
}

func decodeOrdered(data []byte) (any, error) {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	v, err := readValue(d)
	if err != nil {
		return nil, err
	}
	if _, err := d.Token(); err == nil {
		return nil, fmt.Errorf("JSON の後ろに余分な字があります")
	}
	return v, nil
}

func readValue(d *json.Decoder) (any, error) {
	tok, err := d.Token()
	if err != nil {
		return nil, err
	}
	delim, isDelim := tok.(json.Delim)
	if !isDelim {
		return tok, nil
	}
	switch delim {
	case '{':
		o := &obj{m: map[string]any{}}
		for d.More() {
			kt, err := d.Token()
			if err != nil {
				return nil, err
			}
			key, ok := kt.(string)
			if !ok {
				return nil, fmt.Errorf("JSON のキーが文字列ではありません")
			}
			val, err := readValue(d)
			if err != nil {
				return nil, err
			}
			if _, dup := o.m[key]; !dup {
				o.keys = append(o.keys, key)
			}
			o.m[key] = val
		}
		_, err := d.Token()
		return o, err
	case '[':
		arr := []any{}
		for d.More() {
			v, err := readValue(d)
			if err != nil {
				return nil, err
			}
			arr = append(arr, v)
		}
		_, err := d.Token()
		return arr, err
	}
	return nil, fmt.Errorf("JSON が壊れています")
}

// rowsOf は「文字列の並び」として読める値だけを行の列にする。
func rowsOf(v any) []string {
	arr, ok := v.([]any)
	if !ok {
		return nil
	}
	rows := make([]string, 0, len(arr))
	for _, e := range arr {
		s, ok := e.(string)
		if !ok {
			return nil
		}
		rows = append(rows, s)
	}
	return rows
}

// --- 出力の字面 -----------------------------------------------------------

// pyRepr は文字列を引用符で囲んだ字面を返す。' を含み " を含まないときだけ " で囲む。
func pyRepr(s string) string {
	quote := byte('\'')
	if strings.Contains(s, "'") && !strings.Contains(s, "\"") {
		quote = '"'
	}
	var b strings.Builder
	b.WriteByte(quote)
	for _, r := range s {
		switch {
		case r == rune(quote) || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\n':
			b.WriteString("\\n")
		case r == '\r':
			b.WriteString("\\r")
		case r == '\t':
			b.WriteString("\\t")
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, "\\x%02x", r)
		case r < 0x80 || unicode.IsPrint(r):
			b.WriteRune(r)
		case r <= 0xffff:
			fmt.Fprintf(&b, "\\u%04x", r)
		default:
			fmt.Fprintf(&b, "\\U%08x", r)
		}
	}
	b.WriteByte(quote)
	return b.String()
}

// pyStrList は文字列の並びを ['a', 'b'] の字面にする。
func pyStrList(items []string) string {
	parts := make([]string, 0, len(items))
	for _, s := range items {
		parts = append(parts, pyRepr(s))
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// pyIntDict は名前と数の組を {'a': 1, 'b': 2} の字面にする (書かれた順のまま)。
func pyIntDict(keys []string, values map[string]int) string {
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s: %d", pyRepr(k), values[k]))
	}
	return "{" + strings.Join(parts, ", ") + "}"
}

// pyFloat は小数を最短の字面にする (整数に見える値には .0 を足す)。
func pyFloat(v float64) string {
	s := strconv.FormatFloat(v, 'g', -1, 64)
	if !strings.ContainsAny(s, ".eE") {
		s += ".0"
	}
	return s
}

// pyPercent は割合を小数点以下なしの N% にする。
func pyPercent(v float64) string { return fmt.Sprintf("%.0f%%", v*100) }

// pySignedPercent は割合を符号付きの +N% / -N% にする。
func pySignedPercent(v float64) string { return fmt.Sprintf("%+.0f%%", v*100) }

// --- 画素 -----------------------------------------------------------------

type point struct{ x, y int }

func (r *Rules) maskOf(rows []string) map[point]bool {
	mask := map[point]bool{}
	for y, row := range rows {
		x := 0
		for _, ch := range row {
			if !r.Transparent[ch] {
				mask[point{x, y}] = true
			}
			x++
		}
	}
	return mask
}

func (r *Rules) gridOf(rows []string) map[point]rune {
	grid := map[point]rune{}
	for y, row := range rows {
		x := 0
		for _, ch := range row {
			if !r.Transparent[ch] {
				grid[point{x, y}] = ch
			}
			x++
		}
	}
	return grid
}

// colorsOf は透明でない字を並び順を保って 1 度ずつ返す。
func (r *Rules) colorsOf(rows []string) []rune {
	var found []rune
	seen := map[rune]bool{}
	for _, row := range rows {
		for _, ch := range row {
			if r.Transparent[ch] || seen[ch] {
				continue
			}
			seen[ch] = true
			found = append(found, ch)
		}
	}
	return found
}

func bottomOf(mask map[point]bool) (int, bool) {
	best, ok := 0, false
	for p := range mask {
		if !ok || p.y > best {
			best, ok = p.y, true
		}
	}
	return best, ok
}

func topOf(mask map[point]bool) (int, bool) {
	best, ok := 0, false
	for p := range mask {
		if !ok || p.y < best {
			best, ok = p.y, true
		}
	}
	return best, ok
}

func widthOf(mask map[point]bool) int {
	lo, hi, ok := 0, 0, false
	for p := range mask {
		if !ok {
			lo, hi, ok = p.x, p.x, true
			continue
		}
		if p.x < lo {
			lo = p.x
		}
		if p.x > hi {
			hi = p.x
		}
	}
	if !ok {
		return 0
	}
	return hi - lo + 1
}

// footCenter は接地行に乗っている画素の x の平均。
func footCenter(mask map[point]bool) (float64, bool) {
	bottom, ok := bottomOf(mask)
	if !ok {
		return 0, false
	}
	sum, n := 0, 0
	for p := range mask {
		if p.y == bottom {
			sum += p.x
			n++
		}
	}
	if n == 0 {
		return 0, false
	}
	return float64(sum) / float64(n), true
}

// changeShare は入れ替わった画素の割合。
//
// 体を 1px 上下させる歩きの上下動だけで全画素がずれるので、±slack の平行移動で
// いちばん重なる置き方に合わせてから数える。「動いた量」ではなく
// 平行移動では説明できない変化を見る。
func (r *Rules) changeShare(aRows, bRows []string) float64 {
	a, b := r.gridOf(aRows), r.gridOf(bRows)
	if len(a) == 0 && len(b) == 0 {
		return 0.0
	}
	slack := r.ChangeShareSlack
	best := 1.0
	shifted := make(map[point]rune, len(b))
	for dy := -slack; dy <= slack; dy++ {
		for dx := -slack; dx <= slack; dx++ {
			for k := range shifted {
				delete(shifted, k)
			}
			for p, c := range b {
				shifted[point{p.x + dx, p.y + dy}] = c
			}
			span, changed := 0, 0
			for p, ca := range a {
				span++
				if cb, ok := shifted[p]; !ok || cb != ca {
					changed++
				}
			}
			for p := range shifted {
				if _, ok := a[p]; ok {
					continue
				}
				span++
				changed++
			}
			denom := span
			if denom < 1 {
				denom = 1
			}
			if share := float64(changed) / float64(denom); share < best {
				best = share
			}
		}
	}
	return best
}

// --- 除外記法 -------------------------------------------------------------

// excludedRules は `対象外(pop、area)` のような書き方から除外するルール名を拾う。
func excludedRules(v any) map[string]bool {
	skip := map[string]bool{}
	text, ok := v.(string)
	if !ok || !strings.Contains(text, "対象外") {
		return skip
	}
	_, head, _ := strings.Cut(text, "対象外")
	inside := ""
	if i := strings.Index(head, "("); i >= 0 {
		inside = head[i+1:]
		if j := strings.Index(inside, ")"); j >= 0 {
			inside = inside[:j]
		}
	}
	for _, part := range strings.Split(strings.ReplaceAll(inside, "、", ","), ",") {
		part = strings.TrimFunc(part, unicode.IsSpace)
		if part != "" {
			skip[part] = true
		}
	}
	return skip
}

func mergeSkip(dst, src map[string]bool) {
	for k := range src {
		dst[k] = true
	}
}

// splitDirection は 'walker_side' → ('walker', 'side')。方向語尾が無ければ ("", false)。
func (r *Rules) splitDirection(name string) (string, string, bool) {
	i := strings.LastIndex(name, "_")
	if i < 0 {
		return name, "", false
	}
	base, tail := name[:i], name[i+1:]
	if dir, ok := r.Directions[strings.ToLower(tail)]; ok {
		return base, dir, true
	}
	return name, "", false
}

// --- コマ列 ---------------------------------------------------------------

type frame struct {
	name string
	rows []string
}

// checkFrames はコマ列の不変量。frames は並び順で。
func (r *Rules) checkFrames(spriteName string, frames []frame, skip map[string]bool) []string {
	var out []string
	for _, n := range r.measureFrames(spriteName, frames, skip) {
		out = append(out, n.Text)
	}
	return out
}

// Note は検査の注意 1 件と、測った値（Got）と基準（Limit。AtMost なら got ≤ limit）。
type Note struct {
	Rule   string // pop・loop・area・ground・bob・palette
	Text   string
	Got    float64
	Limit  float64
	AtMost bool
}

// measureFrames は checkFrames の中身（測った値つき）。
func (r *Rules) measureFrames(spriteName string, frames []frame, skip map[string]bool) []Note {
	var notes []Note
	if len(frames) < 2 {
		return notes
	}
	masks := make([]map[point]bool, len(frames))
	for i, f := range frames {
		masks[i] = r.maskOf(f.rows)
	}
	baseArea := len(masks[0])

	for i := 0; i+1 < len(frames); i++ {
		if !skip["pop"] {
			share := r.changeShare(frames[i].rows, frames[i+1].rows)
			if share > r.MaxPopShare {
				notes = append(notes, Note{"pop", fmt.Sprintf(
					"%s: %s → %s でシルエットの %s が入れ替わる (上限 %s) — 別の絵に見えて画面がちらつく",
					spriteName, frames[i].name, frames[i+1].name,
					pyPercent(share), pyPercent(r.MaxPopShare)), share, r.MaxPopShare, true})
			}
		}
	}
	if !skip["loop"] && len(frames) > 2 {
		share := r.changeShare(frames[len(frames)-1].rows, frames[0].rows)
		if share > r.MaxPopShare {
			notes = append(notes, Note{"loop", fmt.Sprintf(
				"%s: 輪が閉じていない (%s → %s で %s 入れ替わる) — 繰り返した瞬間に飛ぶ",
				spriteName, frames[len(frames)-1].name, frames[0].name, pyPercent(share)), share, r.MaxPopShare, true})
		}
	}
	for i := 1; i < len(frames); i++ {
		if !skip["area"] && baseArea != 0 {
			gap := len(masks[i]) - baseArea
			if gap < 0 {
				gap = -gap
			}
			// WhyNot: 符号を戻して出さないのは、ずれの大きさだけを見せたいため。
			// 減った側も + と出るが、直すと字面が変わって golden が落ちる。
			drift := float64(gap) / float64(baseArea)
			if drift > r.MaxAreaDrift {
				notes = append(notes, Note{"area", fmt.Sprintf(
					"%s: コマ %s の面積が %s ずれる (上限 ±%s) — 曲げても体の太さは変わらない",
					spriteName, frames[i].name, pySignedPercent(drift), pyPercent(r.MaxAreaDrift)), drift, r.MaxAreaDrift, true})
			}
		}
	}

	type namedBottom struct {
		name   string
		bottom int
	}
	var bottoms []namedBottom
	var tops []int
	for i, m := range masks {
		if len(m) == 0 {
			continue
		}
		b, _ := bottomOf(m)
		bottoms = append(bottoms, namedBottom{frames[i].name, b})
		t, _ := topOf(m)
		tops = append(tops, t)
	}
	if len(bottoms) > 0 {
		if !skip["ground"] {
			floor := bottoms[0].bottom
			for _, nb := range bottoms {
				if nb.bottom > floor {
					floor = nb.bottom
				}
			}
			for _, nb := range bottoms {
				if floor-nb.bottom > r.FootTolerance {
					notes = append(notes, Note{"ground", fmt.Sprintf(
						"%s: コマ %s で足が %dpx 浮いている — 両足が同時に浮くのは跳躍だけ",
						spriteName, nb.name, floor-nb.bottom), float64(floor - nb.bottom), float64(r.FootTolerance), true})
				}
			}
		}
		if !skip["bob"] {
			lo, hi := tops[0], tops[0]
			for _, t := range tops {
				if t < lo {
					lo = t
				}
				if t > hi {
					hi = t
				}
			}
			if swing := hi - lo; swing > r.MaxBob {
				notes = append(notes, Note{"bob", fmt.Sprintf(
					"%s: 頭の上下動が %dpx (上限 %dpx) — 跳ねて見える",
					spriteName, swing, r.MaxBob), float64(swing), float64(r.MaxBob), true})
			}
		}
	}
	if !skip["palette"] {
		baseColors := map[rune]bool{}
		for _, c := range r.colorsOf(frames[0].rows) {
			baseColors[c] = true
		}
		for i := 1; i < len(frames); i++ {
			var extra []string
			for _, c := range r.colorsOf(frames[i].rows) {
				if !baseColors[c] {
					extra = append(extra, string(c))
				}
			}
			if len(extra) > 0 {
				sort.Strings(extra)
				notes = append(notes, Note{"palette", fmt.Sprintf(
					"%s: コマ %s だけに色 %s が湧いている — コマごとに色を足さない",
					spriteName, frames[i].name, pyStrList(extra)), float64(len(extra)), 0, true})
			}
		}
	}
	return notes
}

// --- 4 方向 ---------------------------------------------------------------

// views は方向 → コマ 1 枚。書かれた順を覚えている。
type views struct {
	keys []string
	rows map[string][]string
}

func (v *views) set(dir string, rows []string) {
	if _, dup := v.rows[dir]; !dup {
		v.keys = append(v.keys, dir)
	}
	v.rows[dir] = rows
}

// checkViews は同じキャラの方向どうしの不変量。
func (r *Rules) checkViews(base string, v *views, skip map[string]bool) []string {
	var notes []string
	if skip["view"] || len(v.keys) < 2 {
		return notes
	}
	var order []string
	masks := map[string]map[point]bool{}
	for _, d := range v.keys {
		m := r.maskOf(v.rows[d])
		if len(m) == 0 {
			continue
		}
		order = append(order, d)
		masks[d] = m
	}
	if len(order) < 2 {
		return notes
	}

	bottoms := map[string]int{}
	loB, hiB := 0, 0
	for i, d := range order {
		b, _ := bottomOf(masks[d])
		bottoms[d] = b
		if i == 0 || b < loB {
			loB = b
		}
		if i == 0 || b > hiB {
			hiB = b
		}
	}
	if hiB != loB {
		notes = append(notes, fmt.Sprintf(
			"%s: 方向で接地行が違う %s — 全方向で足の裏を同じ行にそろえる",
			base, pyIntDict(order, bottoms)))
	}

	tops := map[string]int{}
	loT, hiT := 0, 0
	for i, d := range order {
		t, _ := topOf(masks[d])
		tops[d] = t
		if i == 0 || t < loT {
			loT = t
		}
		if i == 0 || t > hiT {
			hiT = t
		}
	}
	if hiT-loT > 1 {
		notes = append(notes, fmt.Sprintf(
			"%s: 方向で頭の高さが違う %s (許容 1px) — 別人に見える",
			base, pyIntDict(order, tops)))
	}

	loC, hiC := 0.0, 0.0
	for i, d := range order {
		c, _ := footCenter(masks[d])
		if i == 0 || c < loC {
			loC = c
		}
		if i == 0 || c > hiC {
			hiC = c
		}
	}
	if hiC-loC > 1 {
		notes = append(notes, fmt.Sprintf(
			"%s: 方向で足元の中心がずれている — 向きを変えた瞬間に体が滑る", base))
	}

	if masks["front"] != nil && masks["side"] != nil {
		den := widthOf(masks["front"])
		if den < 1 {
			den = 1
		}
		ratio := float64(widthOf(masks["side"])) / float64(den)
		if !(r.MinSideRatio <= ratio && ratio <= r.MaxSideRatio) {
			why := "太すぎて別人"
			if ratio < r.MinSideRatio {
				why = "細すぎて貧相"
			}
			notes = append(notes, fmt.Sprintf(
				"%s: 横向きの幅が正面の %.2f 倍 (目安 %s〜%s) — %s",
				base, ratio, pyFloat(r.MinSideRatio), pyFloat(r.MaxSideRatio), why))
		}
	}
	if masks["front"] != nil && masks["back"] != nil {
		iou := iouOf(masks["front"], masks["back"])
		if iou < r.MinBackIoU {
			notes = append(notes, fmt.Sprintf(
				"%s: 前と後のシルエットの重なりが %.2f (下限 %s) — 背面は正面の外形を流用し、顔と髪だけ描き替える",
				base, iou, pyFloat(r.MinBackIoU)))
		}
	}
	// WhyNot: ここだけ masks でなく views を見るのは、画素が 1 つも無いコマでも
	// 左右の組として扱うため。masks に揃えると空のコマが黙って外れる。
	_, hasEast := v.rows["side"]
	_, hasWest := v.rows["side_w"]
	if hasEast && hasWest {
		east := r.maskOf(v.rows["side"])
		raw := r.maskOf(v.rows["side_w"])
		west := map[point]bool{}
		if len(raw) > 0 {
			w := 0
			for _, row := range v.rows["side_w"] {
				if n := len([]rune(row)); n > w {
					w = n
				}
			}
			for p := range raw {
				west[point{w - 1 - p.x, p.y}] = true
			}
		}
		if len(east) > 0 && len(west) > 0 {
			iou := iouOf(east, west)
			if iou < r.MinBackIoU {
				notes = append(notes, fmt.Sprintf(
					"%s: 左右が反転になっていない (重なり %.2f)。非対称の持ち物があるなら意図的 — 除外記法で書く",
					base, iou))
			}
		}
	}

	sorted := append([]string(nil), v.keys...)
	sort.Strings(sorted)
	var baseColors map[rune]bool
	for _, d := range sorted {
		colors := r.colorsOf(v.rows[d])
		if baseColors == nil {
			baseColors = map[rune]bool{}
			for _, c := range colors {
				baseColors[c] = true
			}
			continue
		}
		var extra []string
		for _, c := range colors {
			if !baseColors[c] {
				extra = append(extra, string(c))
			}
		}
		if len(extra) > 0 {
			sort.Strings(extra)
			notes = append(notes, fmt.Sprintf(
				"%s: 方向 %s だけに色 %s がある — 色票は全方向で同じにする",
				base, d, pyStrList(extra)))
		}
	}
	return notes
}

func iouOf(a, b map[point]bool) float64 {
	inter, union := 0, len(a)
	for p := range b {
		if a[p] {
			inter++
		} else {
			union++
		}
	}
	if union < 1 {
		union = 1
	}
	return float64(inter) / float64(union)
}

// --- コマ名から動きの列を作る ---------------------------------------------

// sequences はコマを「連番の並び」ごとに分ける。
//
// walk_0 walk_1 は 1 つの動き。idle hit のような番号の無いコマは別々の状態であって
// 動きの続きではない。一緒くたに比べると的外れな指摘が出る。
func sequences(frames *obj) map[string][]string {
	type item struct {
		digits string
		name   string
	}
	groups := map[string][]item{}
	var order []string
	for _, name := range frames.keys {
		if strings.HasPrefix(name, "//") {
			continue
		}
		runes := []rune(name)
		end := len(runes)
		for end > 0 && runes[end-1] >= '0' && runes[end-1] <= '9' {
			end--
		}
		digits := string(runes[end:])
		if digits == "" {
			continue
		}
		head := strings.TrimRight(string(runes[:end]), "_")
		if _, seen := groups[head]; !seen {
			order = append(order, head)
		}
		groups[head] = append(groups[head], item{digits, name})
	}
	out := map[string][]string{}
	for _, head := range order {
		items := groups[head]
		if len(items) < 2 {
			continue
		}
		sort.SliceStable(items, func(i, j int) bool {
			if c := compareDigits(items[i].digits, items[j].digits); c != 0 {
				return c < 0
			}
			return items[i].name < items[j].name
		})
		names := make([]string, 0, len(items))
		for _, it := range items {
			names = append(names, it.name)
		}
		out[head] = names
	}
	return out
}

// compareDigits は数字だけの文字列どうしの大小を、桁あふれ無しで比べる。
func compareDigits(a, b string) int {
	a, b = strings.TrimLeft(a, "0"), strings.TrimLeft(b, "0")
	if len(a) != len(b) {
		if len(a) < len(b) {
			return -1
		}
		return 1
	}
	return strings.Compare(a, b)
}

// --- 1 ファイル -----------------------------------------------------------

func (r *Rules) checkDoc(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	root, err := decodeOrdered(data)
	if err != nil {
		return nil, fmt.Errorf("%s: JSON として読めません: %v", path, err)
	}
	doc, ok := root.(*obj)
	if !ok {
		return nil, fmt.Errorf("%s: 一番外側が JSON オブジェクトではありません", path)
	}
	fileSkipVal, _ := doc.get("lint-anim")
	fileSkip := excludedRules(fileSkipVal)

	var notes []string
	groupOrder := []string{}
	groupViews := map[string]*views{}
	groupSkip := map[string]map[string]bool{}

	spritesVal, _ := doc.get("sprites")
	sprites, _ := spritesVal.(*obj)
	if sprites != nil {
		for _, name := range sprites.keys {
			spec, ok := sprites.m[name].(*obj)
			if strings.HasPrefix(name, "//") || !ok {
				continue
			}
			skip := map[string]bool{}
			mergeSkip(skip, fileSkip)
			specSkipVal, _ := spec.get("lint-anim")
			mergeSkip(skip, excludedRules(specSkipVal))

			framesVal, _ := spec.get("frames")
			frames, _ := framesVal.(*obj)
			if frames == nil {
				frames = &obj{m: map[string]any{}}
			}
			seqs := sequences(frames)
			seqNames := make([]string, 0, len(seqs))
			for k := range seqs {
				seqNames = append(seqNames, k)
			}
			sort.Strings(seqNames)
			for _, seq := range seqNames {
				label := name
				if seq != "" && seq != name {
					label = name + "." + seq
				}
				list := make([]frame, 0, len(seqs[seq]))
				for _, n := range seqs[seq] {
					list = append(list, frame{n, rowsOf(frames.m[n])})
				}
				notes = append(notes, r.checkFrames(label, list, skip)...)
			}

			base, direction, hasDir := r.splitDirection(name)
			first := ""
			hasFirst := false
			for _, n := range frames.keys {
				if !strings.HasPrefix(n, "//") {
					first, hasFirst = n, true
					break
				}
			}
			if hasDir && hasFirst {
				if _, seen := groupViews[base]; !seen {
					groupOrder = append(groupOrder, base)
					groupViews[base] = &views{rows: map[string][]string{}}
					groupSkip[base] = map[string]bool{}
				}
				groupViews[base].set(direction, rowsOf(frames.m[first]))
				mergeSkip(groupSkip[base], skip)
			}
		}
	}
	for _, base := range groupOrder {
		notes = append(notes, r.checkViews(base, groupViews[base], groupSkip[base])...)
	}
	return notes, nil
}

// --- 探索 -----------------------------------------------------------------

// discover は templates/ 配下、無ければ自分の assets/ を見る。
// エンジンのリポでもゲーム 1 本のリポでも同じ 1 つの検査で動かすため。
func (r *Rules) discover(root string) []string {
	var bases []string
	for _, group := range r.GameRoots {
		groupDir := filepath.Join(root, group)
		entries, err := os.ReadDir(groupDir)
		if err != nil {
			continue
		}
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		sort.Strings(names)
		for _, name := range names {
			rel := filepath.Join(root, group, name)
			info, err := os.Stat(rel)
			if err != nil || !info.IsDir() {
				continue
			}
			bases = append(bases, rel)
		}
	}
	if len(bases) == 0 {
		bases = []string{root}
	}
	var found []string
	var walk func(dir string)
	walk = func(dir string) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		var dirs, files []string
		for _, e := range entries {
			name := e.Name()
			info, err := os.Stat(filepath.Join(dir, name))
			if err != nil {
				continue
			}
			if info.IsDir() {
				if !r.ExcludedDirs[name] {
					dirs = append(dirs, name)
				}
				continue
			}
			if strings.HasSuffix(name, ".sprite.json") {
				files = append(files, name)
			}
		}
		sort.Strings(dirs)
		sort.Strings(files)
		for _, f := range files {
			found = append(found, filepath.Join(dir, f))
		}
		for _, d := range dirs {
			walk(filepath.Join(dir, d))
		}
	}
	for _, base := range bases {
		walk(base)
	}
	sort.Strings(found)
	return found
}

// relTo は root から見た path の相対パスの字面を返す。
func relTo(path, root string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		abs = path
	}
	absRoot, err := filepath.Abs(root)
	if err != nil {
		absRoot = root
	}
	rel, err := filepath.Rel(absRoot, abs)
	if err != nil {
		return path
	}
	return filepath.ToSlash(rel)
}

// --- 入口 -----------------------------------------------------------------

// Run は検査を走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（規約を読めないまま緑にしない）。
func Run(out *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	for _, a := range args {
		if a == "--self-test" {
			return rules.selfTest(out), nil
		}
	}
	strict := false
	var targets []string
	for _, a := range args {
		if strings.HasPrefix(a, "--") {
			if a == "--strict" {
				strict = true
			}
			continue
		}
		targets = append(targets, a)
	}
	if len(targets) == 0 {
		targets = rules.discover(root)
	}
	label := "注意"
	if strict {
		label = "NG"
	}
	total := 0
	for _, path := range targets {
		notes, err := rules.checkDoc(path)
		if err != nil {
			return 2, err
		}
		if len(notes) == 0 {
			continue
		}
		fmt.Fprintf(out, "\n%s\n", relTo(path, root))
		for _, note := range notes {
			fmt.Fprintf(out, "  %s: %s\n", label, note)
		}
		total += len(notes)
	}
	fmt.Fprintf(out, "\n%d ファイル / %s %d 件\n", len(targets), label, total)
	if strict && total > 0 {
		return 1, nil
	}
	return 0, nil
}

// --- 自己検査 -------------------------------------------------------------

func repeat(row string, n int) []string {
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, row)
	}
	return out
}

func concat(parts ...[]string) []string {
	var out []string
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func skipSet(names ...string) map[string]bool {
	s := map[string]bool{}
	for _, n := range names {
		s[n] = true
	}
	return s
}

// selfTest はわざと悪いコマ列を通して、この検査自身が鳴るかを見る (--self-test)。
func (r *Rules) selfTest(out *strings.Builder) int {
	var lines []string
	bad := 0
	record := func(name string, notes []string, needle string) {
		hit := len(notes) == 0
		if needle != "" {
			hit = false
			for _, n := range notes {
				if strings.Contains(n, needle) {
					hit = true
					break
				}
			}
		}
		if hit {
			lines = append(lines, "OK  "+name)
			return
		}
		bad++
		lines = append(lines, "NG  "+name+": "+pyStrList(notes))
	}

	solid := concat(repeat("........", 2), repeat("..oooo..", 4), repeat("..o..o..", 2))
	moved := concat(repeat("........", 2), repeat("..oooo..", 4), repeat(".o...o..", 2))
	other := repeat("oooooooo", 8)

	record("普通のコマ", r.checkFrames("s", []frame{{"a", solid}, {"b", moved}}, skipSet()), "")
	record("入れ替わりすぎ", r.checkFrames("s", []frame{{"a", solid}, {"b", other}}, skipSet()), "入れ替わる")
	record("除外が効く", r.checkFrames("s", []frame{{"a", solid}, {"b", other}},
		skipSet("pop", "area", "ground", "bob", "palette")), "")
	floating := concat(repeat("........", 2), repeat("..oooo..", 4), repeat("........", 2))
	record("足が浮く", r.checkFrames("s", []frame{{"a", solid}, {"b", floating}},
		skipSet("pop", "area", "bob")), "浮いている")
	recolored := make([]string, 0, len(solid))
	for _, row := range solid {
		recolored = append(recolored, strings.Replace(row, "o", "x", 1))
	}
	record("色が湧く", r.checkFrames("s", []frame{{"a", solid}, {"b", recolored}},
		skipSet("pop", "area", "ground", "bob")), "湧いている")

	front := concat(repeat("..oooo..", 6), repeat("..o..o..", 2))
	thin := concat(repeat("...oo...", 6), repeat("...o.o..", 2))
	record("正面と横", r.checkViews("c", viewsOf("front", front, "side", thin), skipSet()), "")
	record("横が太すぎ", r.checkViews("c", viewsOf("front", front, "side", front), skipSet()), "太すぎ")
	record("接地がずれる", r.checkViews("c", viewsOf("front", front, "side",
		concat(repeat("...oo...", 6), repeat("........", 2))), skipSet()), "接地行が違う")
	back := concat(repeat("..oooo..", 6), repeat("..o..o..", 2))
	record("前と後が重なる", r.checkViews("c", viewsOf("front", front, "back", back), skipSet()), "")

	for _, line := range lines {
		fmt.Fprintln(out, line)
	}
	fmt.Fprintf(out, "\n%d/%d 件 OK\n", len(lines)-bad, len(lines))
	if bad > 0 {
		return 1
	}
	return 0
}

func viewsOf(d1 string, r1 []string, d2 string, r2 []string) *views {
	v := &views{rows: map[string][]string{}}
	v.set(d1, r1)
	v.set(d2, r2)
	return v
}
