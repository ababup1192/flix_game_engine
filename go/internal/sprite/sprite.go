package sprite

// sprite — ドット絵 (*.sprite.json) の画素の並びを検査するゲート。
//
//	fge-go sprite [a.sprite.json ...] [--strict]
//	fge-go sprite --self-test
//
// 引数が無ければ templates/ を全部見る。

import (
	"fmt"
	"math"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// exemptTrim は除外理由の前に付く飾り。
const exemptTrim = " —-–:"

// noReason は理由を書かずに対象外と書かれたときの文面。
const noReason = "（理由が書かれていません）"

// exclusion は除外の 1 件。sprite が空ならファイル単位。
type exclusion struct {
	sprite string
	reason string
}

// ---------------------------------------------------------------- 小物

// isPySpace は空白かどうかを見る。
// WhyNot: unicode.IsSpace にしないのは U+001C〜U+001F を Go が空白に数えず、
// それらが挟まった行を空行と見なせなくなるため。
func isPySpace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', 0x1c, 0x1d, 0x1e, 0x1f, 0x85:
		return true
	}
	return unicode.Is(unicode.Z, r)
}

func pyStrip(s string) string     { return strings.TrimFunc(s, isPySpace) }
func pyLStripSet(s string) string { return strings.TrimLeft(s, exemptTrim) }

// keyText は legend の値を色キーの字面にする。
// WhyNot: 文字列以外も受けるのは、legend に数値や真偽値を書いた Doc でも
// それを色キーとして数え、色数の勘定から漏らさないため。
func keyText(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case bool:
		if x {
			return "True"
		}
		return "False"
	case nil:
		return "None"
	case float64:
		if x == math.Trunc(x) && math.Abs(x) < 1e15 {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'g', -1, 64)
	default:
		return fmt.Sprint(x)
	}
}

// numText は anchor の座標を字面にする。整数値は小数点を付けない。
func numText(v any, missing int) string {
	f, ok := numOf(v, missing)
	if !ok {
		return keyText(v)
	}
	if f == math.Trunc(f) && math.Abs(f) < 1e15 {
		return strconv.FormatInt(int64(f), 10)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

func numOf(v any, missing int) (float64, bool) {
	if v == nil {
		return float64(missing), true
	}
	f, ok := v.(float64)
	return f, ok
}

// ---------------------------------------------------------------- 色 (ΔE)

func hexMapOf(v any) map[string]string {
	found := map[string]string{}
	m, ok := pxlib.AsObject(v)
	if !ok {
		return found
	}
	for name, value := range m {
		if got := pxlib.HexOfValue(value); got != "" {
			found[name] = got
		}
	}
	// WhyNot: colors を後に回すのは、同じ名前があれば入れ子の colors を勝たせるため。
	if nested, ok := pxlib.AsObject(m["colors"]); ok {
		for name, value := range nested {
			if got := pxlib.HexOfValue(value); got != "" {
				found[name] = got
			}
		}
	}
	return found
}

// colorHexesOf は legend の値 → "#rrggbb"。解けない値は含めない。
func colorHexesOf(gameDir string, jsonPaths []string, doc map[string]any) map[string]string {
	names := map[string]string{}
	merge := func(v any) {
		for k, hex := range hexMapOf(v) {
			names[k] = hex
		}
	}
	for _, rel := range jsonPaths {
		if strings.HasSuffix(rel, ".theme.json") {
			merge(pxlib.ReadJSON(filepath.Join(gameDir, rel)))
		}
	}
	if ref, ok := doc["paletteFile"].(string); ok {
		merge(pxlib.ReadJSON(filepath.Join(gameDir, ref)))
	}
	merge(doc["palette"])

	resolved := map[string]string{}
	legend, ok := pxlib.AsObject(doc["legend"])
	if !ok {
		return resolved
	}
	for _, value := range legend {
		text, ok := value.(string)
		if !ok {
			continue
		}
		if direct := pxlib.HexOfValue(text); direct != "" {
			resolved[text] = direct
			continue
		}
		name := strings.TrimPrefix(text, "@")
		if hex, ok := names[name]; ok {
			resolved[text] = hex
		}
	}
	return resolved
}

// ---------------------------------------------------------------- 格子の下ごしらえ

// gridOf は rows を色キーの格子にする。legend に無い文字（透明の字を除く）を unknown に返す。
func (r *Rules) gridOf(rows []string, legend map[string]any) (g *pxlib.Grid, unknown []rune) {
	keys := make(map[string]pxlib.Key, len(legend))
	for ch, v := range legend {
		keys[ch] = pxlib.Key(keyText(v))
	}
	g, all := pxlib.GridFromRows(rows, keys)
	for _, ch := range all {
		if !r.TransparentChars[ch] {
			unknown = append(unknown, ch)
		}
	}
	return g, unknown
}

// ---------------------------------------------------------------- 各規則

// Finding は 1 コマの検査で見つかった 1 件。Msg は「スプライト/コマ: 」を除いた本文。
// At は代表の画素（HasAt が false なら場所を持たない注意）。Cells は関わる画素の全部。
type Finding struct {
	Rule    string
	Problem bool
	HasAt   bool
	At      pxlib.Pt
	Cells   []pxlib.Pt
	Msg     string
}

// CheckFrame は 1 コマの形の規則（orphan・connect・jaggy・banding・corner・silhouette）を見る。
// 全面に近いコマ（テクスチャ）は形の規則を見ない。並びは sprite の検査の出力と同じ。
func (r *Rules) CheckFrame(g *pxlib.Grid) []Finding {
	opaque := g.Opaque()
	count := opaque.Count()
	if count == 0 || float64(count)/float64(g.W*g.H) >= r.TextureFill {
		return nil
	}
	var out []Finding
	for _, p := range r.orphanCells(opaque, count) {
		out = append(out, Finding{Rule: "orphan", Problem: true, HasAt: true, At: p, Cells: []pxlib.Pt{p},
			Msg: fmt.Sprintf("(%d,%d) に浮いた 1 画素 (周り 8 方向すべて透明)", p.X, p.Y)})
	}
	if count >= r.MinConnectCells {
		blobs := opaque.Blobs(4)
		if len(blobs) > 1 {
			limit := min(len(blobs), r.ConnectShown)
			parts := make([]string, 0, limit)
			for _, b := range blobs[:limit] {
				parts = append(parts, fmt.Sprintf("(%d,%d) から始まる塊 %dpx", b.Start.X, b.Start.Y, b.Size))
			}
			more := ""
			if len(blobs) > r.ConnectShown {
				more = "・…"
			}
			out = append(out, Finding{Rule: "connect", HasAt: true, At: blobs[1].Start, Msg: fmt.Sprintf(
				"絵が %d 個の塊に分かれている (%s%s) — 意図して離した絵 (火の粉・浮く飾り) なら対象外に書く",
				len(blobs), strings.Join(parts, "・"), more)})
		}
	}
	if spots := jaggySpots(opaque); len(spots) >= r.JaggyMinCount {
		out = append(out, Finding{Rule: "jaggy", HasAt: true, At: spots[0], Cells: spots,
			Msg: fmt.Sprintf("輪郭の階段が %d 箇所で乱れている (長,1,長 のラン)", len(spots))})
	}
	for _, b := range r.bandingKeys(g, opaque) {
		out = append(out, Finding{Rule: "banding", HasAt: true, At: b.cells[0], Cells: b.cells, Msg: fmt.Sprintf(
			"色 \"%s\" が輪郭の内側 1px の縁取りとしてしか使われていない (banding の疑い)", b.key)})
	}
	if spots := cornerDoubleSpots(g); len(spots) > 0 {
		out = append(out, Finding{Rule: "corner", HasAt: true, At: spots[0], Cells: spots,
			Msg: fmt.Sprintf("1px 線の角が %d 箇所で 2 重 (最初は (%d,%d) 付近)", len(spots), spots[0].X, spots[0].Y)})
	}
	for _, note := range r.silhouetteNotes(opaque, count) {
		out = append(out, Finding{Rule: "silhouette", Msg: note})
	}
	return out
}

// orphanCells は周り 8 方向すべて透明の画素。
func (r *Rules) orphanCells(opaque pxlib.Mask, count int) []pxlib.Pt {
	if count < r.MinOrphanCells {
		return nil
	}
	var found []pxlib.Pt
	for _, p := range opaque.Points() {
		alone := true
		for dx := -1; dx <= 1 && alone; dx++ {
			for dy := -1; dy <= 1; dy++ {
				if (dx != 0 || dy != 0) && opaque.At(p.X+dx, p.Y+dy) {
					alone = false
					break
				}
			}
		}
		if alone {
			found = append(found, p)
		}
	}
	pxlib.SortPtsByXY(found)
	return found
}

// jaggySpots は輪郭の階段で 長,1,長 (段差 ±1・同方向) と乱れている箇所（1 の段の最初の画素）。
func jaggySpots(opaque pxlib.Mask) []pxlib.Pt {
	var spots []pxlib.Pt
	for side, seq := range opaque.Profiles() {
		o := 0
		for _, runs := range pxlib.ProfileRuns(seq) {
			// 切れ目の前の透明の列を飛ばして、この切れ目の最初の列の番号に合わせる
			for o < len(seq) && !seq[o].OK {
				o++
			}
			start := o
			for i := 1; i < len(runs)-1; i++ {
				stepIn := runs[i].Value - runs[i-1].Value
				stepOut := runs[i+1].Value - runs[i].Value
				if runs[i].N == 1 && runs[i-1].N >= 2 && runs[i+1].N >= 2 &&
					stepIn == stepOut && (stepIn == 1 || stepIn == -1) {
					at := start
					for _, rr := range runs[:i] {
						at += rr.N
					}
					if side < 2 {
						spots = append(spots, pxlib.Pt{X: at, Y: runs[i].Value})
					} else {
						spots = append(spots, pxlib.Pt{X: runs[i].Value, Y: at})
					}
				}
			}
			for _, rr := range runs {
				o += rr.N
			}
		}
	}
	return spots
}

type bandingKey struct {
	key   string
	cells []pxlib.Pt
}

// bandingKeys は輪郭の内側 1px の縁取りとしてしか使われていない色。
func (r *Rules) bandingKeys(g *pxlib.Grid, opaque pxlib.Mask) []bandingKey {
	byKey := map[pxlib.Key][]pxlib.Pt{}
	for _, p := range opaque.Points() {
		k := g.Px[p.Y][p.X]
		byKey[k] = append(byKey[k], p)
	}
	if len(byKey) < 3 {
		return nil
	}
	dist := opaque.DistFromEdge()
	keys := make([]string, 0, len(byKey))
	for k := range byKey {
		keys = append(keys, string(k))
	}
	sort.Strings(keys)
	var suspects []bandingKey
	for _, key := range keys {
		spots := byKey[pxlib.Key(key)]
		if len(spots) < r.BandingMinRun {
			continue
		}
		inner := true
		for _, p := range spots {
			if dist[p.Y][p.X] != 2 {
				inner = false
				break
			}
		}
		if !inner {
			continue
		}
		x0, y0, x1, y1 := pxlib.BBox(spots)
		if x1-x0 >= 2 && y1-y0 >= 2 {
			suspects = append(suspects, bandingKey{key, spots})
		}
	}
	return suspects
}

// cornerDoubleSpots は 1px の斜め線の段が 1 画素重なって太って見える箇所。
func cornerDoubleSpots(g *pxlib.Grid) []pxlib.Pt {
	same := func(x, y int, key pxlib.Key) bool {
		return g.In(x, y) && g.Px[y][x] != pxlib.Clear && g.Px[y][x] == key
	}
	spots := map[pxlib.Pt]bool{}
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			key := g.Px[y][x]
			if key == pxlib.Clear {
				continue
			}
			for _, dy := range [2]int{1, -1} {
				if same(x+1, y, key) &&
					same(x+1, y+dy, key) &&
					same(x+2, y+dy, key) &&
					!same(x, y+dy, key) &&
					!same(x+2, y, key) &&
					!same(x, y-dy, key) &&
					!same(x+1, y-dy, key) &&
					!same(x+1, y+2*dy, key) &&
					!same(x+2, y+2*dy, key) {
					spots[pxlib.Pt{X: x + 1, Y: y}] = true
				}
			}
			for _, dx := range [2]int{1, -1} {
				if same(x, y+1, key) &&
					same(x+dx, y+1, key) &&
					same(x+dx, y+2, key) &&
					!same(x+dx, y, key) &&
					!same(x, y+2, key) &&
					!same(x-dx, y, key) &&
					!same(x-dx, y+1, key) &&
					!same(x+2*dx, y+1, key) &&
					!same(x+2*dx, y+2, key) {
					spots[pxlib.Pt{X: x, Y: y + 1}] = true
				}
			}
		}
	}
	out := make([]pxlib.Pt, 0, len(spots))
	for p := range spots {
		out = append(out, p)
	}
	pxlib.SortPtsByXY(out)
	return out
}

func (r *Rules) silhouetteNotes(opaque pxlib.Mask, count int) []string {
	width, height := opaque.W(), opaque.H()
	x0, y0, x1, y1 := pxlib.BBox(opaque.Points())
	boxW, boxH := x1-x0+1, y1-y0+1
	var notes []string
	occupancy := float64(count) / float64(boxW*boxH)
	if occupancy < r.SilhouetteMinOcc {
		notes = append(notes, fmt.Sprintf("シルエットがスカスカ (枠 %dx%d の %.0f%%)", boxW, boxH, occupancy*100))
	}
	// 格子の端から端まで届く物はタイルの縁や細長い物であって、細くて当たり前。
	spans := boxW == width || boxH == height
	if !spans && min(boxW, boxH) <= 2 && max(boxW, boxH) >= 8 {
		notes = append(notes, fmt.Sprintf("シルエットが細長すぎる (%dx%d)", boxW, boxH))
	}
	return notes
}

// ---------------------------------------------------------------- 除外記法

type exempt struct {
	rules  map[string]bool
	reason string
}

// exemptOf は "対象外(規則, ...) — 理由" を読む。読めなければ ok=false。
func (r *Rules) exemptOf(v any) (exempt, bool) {
	value, ok := v.(string)
	if !ok || !strings.Contains(value, "対象外") {
		return exempt{}, false
	}
	rules := map[string]bool{}
	listed := ""
	if m := r.exempt.FindStringSubmatch(value); m != nil {
		listed = m[1]
	}
	if listed != "" {
		for _, part := range strings.Split(strings.ReplaceAll(listed, "、", ","), ",") {
			if name := pyStrip(part); name != "" {
				rules[name] = true
			}
		}
	} else {
		for _, name := range r.RuleNames {
			rules[name] = true
		}
	}
	_, tail, _ := strings.Cut(value, "対象外")
	if loc := r.exemptParen.FindStringIndex(tail); loc != nil {
		tail = tail[:loc[0]] + tail[loc[1]:]
	}
	reason := pyStrip(pyLStripSet(tail))
	if reason == "" {
		reason = noReason
	}
	return exempt{rules, reason}, true
}

// ---------------------------------------------------------------- 1 Doc の検査

// checkDoc は (NG の列, 注意の列, 除外の列, スプライト数) を返す。行頭にパスは付けない。
func (r *Rules) checkDoc(doc map[string]any, legendHexes map[string]string, hasHexes bool) (
	problems, warnings []string, excluded []exclusion, spriteCount int) {

	legend, _ := pxlib.AsObject(doc["legend"])
	if legend == nil {
		legend = map[string]any{}
	}
	sprites, _ := pxlib.AsObject(doc["sprites"])
	if sprites == nil {
		sprites = map[string]any{}
	}

	docExempt, hasDocExempt := r.exemptOf(doc["lint-sprite"])
	if hasDocExempt {
		excluded = append(excluded, exclusion{"", docExempt.reason})
	}

	if hasHexes && len(legendHexes) >= 2 {
		names := make([]string, 0, len(legendHexes))
		for name := range legendHexes {
			names = append(names, name)
		}
		sort.Strings(names)
		for i, nameA := range names {
			for _, nameB := range names[i+1:] {
				de := pxlib.DeltaE(legendHexes[nameA], legendHexes[nameB])
				if de < r.DeltaEMin && !(hasDocExempt && docExempt.rules["palette"]) {
					warnings = append(warnings, fmt.Sprintf(
						"色 \"%s\" (%s) と \"%s\" (%s) が近すぎる (ΔE %.1f)",
						nameA, legendHexes[nameA], nameB, legendHexes[nameB], de))
				}
			}
		}
	}

	spriteNames := make([]string, 0, len(sprites))
	for name := range sprites {
		spriteNames = append(spriteNames, name)
	}
	sort.Strings(spriteNames)

	for _, name := range spriteNames {
		if strings.HasPrefix(name, "//") {
			continue
		}
		spec, isObject := pxlib.AsObject(sprites[name])
		var frames map[string]any
		if isObject {
			frames, _ = pxlib.AsObject(spec["frames"])
		}
		if !isObject || frames == nil {
			problems = append(problems, fmt.Sprintf("%s: frames が無い (スプライトは {frames, anchor} の形)", name))
			continue
		}
		spriteCount++

		exemptRules := map[string]bool{}
		if got, ok := r.exemptOf(spec["lint-sprite"]); ok {
			for rule := range got.rules {
				exemptRules[rule] = true
			}
			excluded = append(excluded, exclusion{name, got.reason})
		}
		if hasDocExempt {
			for rule := range docExempt.rules {
				exemptRules[rule] = true
			}
		}
		report := func(rule string, isProblem bool, text string) {
			if exemptRules[rule] {
				return
			}
			if isProblem {
				problems = append(problems, text)
				return
			}
			warnings = append(warnings, text)
		}

		frameNames := make([]string, 0, len(frames))
		for frameName := range frames {
			frameNames = append(frameNames, frameName)
		}
		sort.Strings(frameNames)

		type size struct{ w, h int }
		sizes := map[string]size{}
		var sizeOrder []string
		usedKeys := map[string]bool{}
		seenFrames := map[string]string{}

		for _, frameName := range frameNames {
			where := name + "/" + frameName
			rows, ok := stringRows(frames[frameName])
			if !ok {
				report("structure", true, fmt.Sprintf("%s: rows が文字列の配列でない", where))
				continue
			}
			widths := map[int]bool{}
			for _, row := range rows {
				widths[len([]rune(row))] = true
			}
			if len(rows) == 0 || len(widths) > 1 {
				report("structure", true, fmt.Sprintf("%s: rows が矩形でない (行の長さが不揃い)", where))
				continue
			}
			g, unknown := r.gridOf(rows, legend)
			if len(unknown) > 0 {
				parts := make([]string, 0, len(unknown))
				for _, c := range unknown {
					parts = append(parts, "'"+string(c)+"'")
				}
				report("structure", true, fmt.Sprintf("%s: legend に無い文字 %s (typo なら透明として消えている)",
					where, strings.Join(parts, " ")))
			}
			if g.Count() == 0 {
				report("structure", true, fmt.Sprintf("%s: 絵が空 (不透明な画素が 1 つも無い)", where))
				continue
			}
			if _, dup := sizes[frameName]; !dup {
				sizeOrder = append(sizeOrder, frameName)
			}
			sizes[frameName] = size{g.W, g.H}
			for _, k := range g.Keys() {
				usedKeys[string(k)] = true
			}
			key := rowsKey(rows)
			if first, dup := seenFrames[key]; dup {
				report("structure", true, fmt.Sprintf("%s: コマ \"%s\" と \"%s\" が完全に同じ (コピペ?)", name, first, frameName))
			} else {
				seenFrames[key] = frameName
			}

			for _, f := range r.CheckFrame(g) {
				report(f.Rule, f.Problem, where+": "+f.Msg)
			}
		}

		distinct := map[size]bool{}
		for _, s := range sizes {
			distinct[s] = true
		}
		switch {
		case len(distinct) > 1:
			named := make([]string, 0, len(sizes))
			for _, n := range sortedKeys(sizes) {
				named = append(named, fmt.Sprintf("%s=%dx%d", n, sizes[n].w, sizes[n].h))
			}
			report("structure", true, fmt.Sprintf("%s: コマの大きさが不揃い (%s)", name, strings.Join(named, ", ")))
		case len(sizes) > 0:
			first := sizes[sizeOrder[0]]
			if anchor, ok := pxlib.AsObject(spec["anchor"]); ok {
				ax, axOK := numOf(anchor["x"], 0)
				ay, ayOK := numOf(anchor["y"], 0)
				inside := axOK && ayOK &&
					0 <= ax && ax < float64(first.w) && 0 <= ay && ay < float64(first.h)
				if !inside {
					report("structure", true, fmt.Sprintf("%s: anchor (%s,%s) が格子 %dx%d の外",
						name, numText(anchor["x"], 0), numText(anchor["y"], 0), first.w, first.h))
				}
			}
		}

		big := false
		for _, s := range sizes {
			if max(s.w, s.h) > r.BigSide {
				big = true
			}
		}
		limit := r.MaxColors
		if big {
			limit = r.MaxColorsBig
		}
		if len(usedKeys) > limit {
			report("palette", false, fmt.Sprintf(
				"%s: 色数 %d が目安 %d を超えている (少数パレットの画風なら色を束ねる。色ランプ+ディザの画風なら気にしなくてよい)",
				name, len(usedKeys), limit))
		}
	}

	return problems, warnings, excluded, spriteCount
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// stringRows は JSON の値が文字列だけの配列なら中身を返す。
func stringRows(v any) ([]string, bool) {
	arr, ok := v.([]any)
	if !ok {
		return nil, false
	}
	rows := make([]string, 0, len(arr))
	for _, item := range arr {
		s, ok := item.(string)
		if !ok {
			return nil, false
		}
		rows = append(rows, s)
	}
	return rows, true
}

// rowsKey はコマの丸ごとコピペを見分ける鍵。
// WhyNot: 単純な連結にしないのは、行の中身に改行や NUL が入っていても別のコマを
// 同じ鍵にしないため（行の長さを前に置いて区切る）。
func rowsKey(rows []string) string {
	var b strings.Builder
	for _, row := range rows {
		b.WriteString(strconv.Itoa(len(row)))
		b.WriteByte(':')
		b.WriteString(row)
	}
	return b.String()
}

// ---------------------------------------------------------------- 走査

type target struct {
	shown   string
	path    string
	gameDir string
}

// gameDirOf は個別指定されたファイルの色票を探す起点 (assets/ の親、無ければ同じ場所)。
func gameDirOf(path string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		abs = path
	}
	parent := filepath.Dir(abs)
	if filepath.Base(parent) == "assets" {
		return filepath.Dir(parent)
	}
	return parent
}

func (r *Rules) gatherTargets(argvPaths []string, root string) []target {
	var targets []target
	if len(argvPaths) > 0 {
		for _, path := range argvPaths {
			targets = append(targets, target{path, path, gameDirOf(path)})
		}
		return targets
	}
	for _, game := range pxlib.GameDirsOf(root, func() bool {
		return pxlib.HasDir(filepath.Join(root, "assets"))
	}) {
		gameDir := filepath.Join(root, game)
		for _, rel := range pxlib.WalkJSON(gameDir, r.ExcludedDirs) {
			if strings.HasSuffix(rel, ".sprite.json") {
				targets = append(targets, target{game + "/" + rel, filepath.Join(gameDir, rel), gameDir})
			}
		}
	}
	return targets
}

// Run は検査を走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（規約を読めないまま緑にしない）。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	selfTest, strict := false, false
	var paths []string
	for _, a := range args {
		switch {
		case a == "--self-test":
			selfTest = true
		case a == "--strict":
			strict = true
		case strings.HasPrefix(a, "--"):
		default:
			paths = append(paths, a)
		}
	}
	if selfTest {
		return rules.selfTest(out, errOut), nil
	}

	var problems, warnings, excluded []string
	docCount, spriteCount := 0, 0

	for _, t := range rules.gatherTargets(paths, root) {
		doc, ok := pxlib.AsObject(pxlib.ReadJSON(t.path))
		if !ok {
			problems = append(problems, fmt.Sprintf("%s: JSON として読めない", t.shown))
			continue
		}
		docCount++
		hexes := colorHexesOf(t.gameDir, pxlib.WalkJSON(t.gameDir, rules.ExcludedDirs), doc)
		gotP, gotW, gotE, gotN := rules.checkDoc(doc, hexes, true)
		for _, line := range gotP {
			problems = append(problems, t.shown+": "+line)
		}
		for _, line := range gotW {
			warnings = append(warnings, "注意: "+t.shown+": "+line)
		}
		for _, e := range gotE {
			name := ""
			if e.sprite != "" {
				name = "/" + e.sprite
			}
			excluded = append(excluded, "除外: "+t.shown+name+" — "+e.reason)
		}
		spriteCount += gotN
	}

	for _, line := range excluded {
		fmt.Fprintln(out, line)
	}
	if strict {
		problems = append(problems, warnings...)
		warnings = nil
	}
	for _, line := range warnings {
		fmt.Fprintln(out, line)
	}
	if len(problems) > 0 {
		for _, line := range problems {
			fmt.Fprintln(errOut, line)
		}
		fmt.Fprintf(errOut, "NG: %d 件 (sprite Doc %d 件・スプライト %d 個を検査)\n",
			len(problems), docCount, spriteCount)
		return 1, nil
	}
	fmt.Fprintf(out, "OK: sprite Doc %d 件・スプライト %d 個を検査 (注意 %d 件・除外 %d 件)\n",
		docCount, spriteCount, len(warnings), len(excluded))
	return 0, nil
}

// ---------------------------------------------------------------- 自己検査

// pyListRepr は文字列の並びを [ ] で囲んだ 1 行にする。
func pyListRepr(items []string) string {
	parts := make([]string, 0, len(items))
	for _, s := range items {
		parts = append(parts, "'"+strings.ReplaceAll(s, "'", `\'`)+"'")
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

type selfCase struct {
	title    string
	doc      map[string]any
	wantNG   []string
	wantWarn []string
}

func rowsOf(rows ...string) []any {
	out := make([]any, 0, len(rows))
	for _, row := range rows {
		out = append(out, row)
	}
	return out
}

// selfTest は各規則につき「検出する例」と「しない例」の最小ペアで自分自身を確かめる。
func (r *Rules) selfTest(out, errOut *strings.Builder) int {
	legend := map[string]any{"i": "ink", "s": "skin", "c": "cloth", "h": "hair", "g": "glow"}
	docOf := func(sprite map[string]any, extra map[string]any) map[string]any {
		doc := map[string]any{"version": 1.0, "legend": legend, "sprites": map[string]any{"hero": sprite}}
		for k, v := range extra {
			doc[k] = v
		}
		return doc
	}

	good := docOf(map[string]any{
		"frames": map[string]any{
			"idle": rowsOf("..ii..", ".issi.", ".issi.", ".icci.", ".icci.", "..ii.."),
			"walk": rowsOf("..ii..", ".issi.", ".issi.", ".icci.", "iicc..", "..ii.."),
		},
		"anchor": map[string]any{"x": 2.0, "y": 5.0},
	}, nil)

	bigLegend := map[string]any{}
	for _, c := range "abcdefghijklm" {
		bigLegend[string(c)] = "c" + string(c)
	}

	cases := []selfCase{
		{"良い例は素通し", good, nil, nil},
		{"非矩形",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("ii", "i")}}, nil),
			[]string{"矩形でない"}, nil},
		{"legend 外の文字",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("iii", "iiZ")}}, nil),
			[]string{"legend に無い文字 'Z'"}, nil},
		{"空のコマ",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("..", "..")}}, nil),
			[]string{"絵が空"}, nil},
		{"コマのコピペ",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("ii", "ii"), "walk": rowsOf("ii", "ii")}}, nil),
			[]string{"完全に同じ"}, nil},
		{"コマの大きさ不揃い",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("ii", "ii"), "walk": rowsOf("iii", "iii")}}, nil),
			[]string{"大きさが不揃い"}, nil},
		{"anchor が格子の外",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("ii", "ii")}, "anchor": map[string]any{"x": 5.0, "y": 0.0}}, nil),
			[]string{"格子 2x2 の外"}, nil},
		{"浮いた 1 画素",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("ii...", "ii..s", ".....", ".....")}}, nil),
			[]string{"浮いた 1 画素"}, []string{"塊に分かれている"}},
		{"塊の分裂",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("ii..ii", "ii..ii", "......", "......")}}, nil),
			nil, []string{"2 個の塊に分かれている"}},
		{"斜めだけの接触も分裂",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("ii....", "ii....", "..iii.", "..iii.")}}, nil),
			nil, []string{"塊に分かれている"}},
		{"全面ディザはテクスチャ扱い",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("isis", "sisi", "isis", "sisi")}}, nil),
			nil, nil},
		{"階段の乱れ (3,1,3)",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf(
				"iii............",
				"iiii...........",
				"iiiiiii........",
				"iiiiiiii.......",
				"iiiiiiiiiii....",
				"iiiiiiiiiiii...",
				"iiiiiiiiiiiiiii",
			)}}, nil),
			nil, []string{"階段"}},
		{"縁取り専用色 (banding)",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf(
				"...........",
				"..iiiiiii..",
				".iggggggsi.",
				".igcccccsi.",
				".igcccccsi.",
				".igcccccsi.",
				".igssssssi.",
				"..iiiiiii..",
				"...........",
			)}}, nil),
			nil, []string{"banding の疑い"}},
		{"1px 線の角の 2 重",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf(
				"......",
				".ii...",
				"..ii..",
				"......",
			)}}, nil),
			nil, []string{"2 重"}},
		{"スカスカのシルエット",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf(
				"i.........",
				"..........",
				"..........",
				"..........",
				".........i",
			)}}, nil),
			nil, []string{"スカスカ"}},
		{"色数の超過は注意どまり",
			map[string]any{
				"version": 1.0,
				"legend":  bigLegend,
				"sprites": map[string]any{"hero": map[string]any{"frames": map[string]any{"idle": rowsOf("abcdefghijklm")}}},
			},
			nil, []string{"色数"}},
		{"除外記法 (規則指定)",
			docOf(map[string]any{
				"frames":      map[string]any{"idle": rowsOf("ii...", "ii..s", ".....", ".....")},
				"lint-sprite": "対象外(orphan, connect) — 火の粉は浮かせたい",
			}, nil),
			nil, nil},
		{"除外記法 (全規則・ファイル単位)",
			docOf(map[string]any{"frames": map[string]any{"idle": rowsOf("ii", "i")}},
				map[string]any{"lint-sprite": "対象外 — 移行中の下書き"}),
			nil, nil},
	}

	var failures []string
	for _, c := range cases {
		gotP, gotW, _, _ := r.checkDoc(c.doc, nil, false)
		for _, needle := range c.wantNG {
			if !containsAny(gotP, needle) {
				failures = append(failures, fmt.Sprintf("%s: NG に「%s」が出ない (実際: %s)", c.title, needle, pyListRepr(gotP)))
			}
		}
		for _, needle := range c.wantWarn {
			if !containsAny(gotW, needle) {
				failures = append(failures, fmt.Sprintf("%s: 注意に「%s」が出ない (実際: %s)", c.title, needle, pyListRepr(gotW)))
			}
		}
		if len(c.wantNG) == 0 && len(gotP) > 0 {
			failures = append(failures, fmt.Sprintf("%s: NG が出ないはずが %s", c.title, pyListRepr(gotP)))
		}
		if len(c.wantWarn) == 0 && len(gotW) > 0 &&
			!strings.Contains(c.title, "除外") && !strings.Contains(c.title, "テクスチャ") {
			failures = append(failures, fmt.Sprintf("%s: 注意が出ないはずが %s", c.title, pyListRepr(gotW)))
		}
	}

	if pxlib.DeltaE("#000000", "#ffffff") < 90 {
		failures = append(failures, "ΔE: 黒と白が近すぎる判定になっている")
	}
	if pxlib.DeltaE("#804030", "#814131") > r.DeltaEMin {
		failures = append(failures, "ΔE: ほぼ同じ 2 色が遠い判定になっている")
	}
	// Sharma et al. (2005) の 34 組の参照値のうち、実装違いが最も出る 3 組。
	for _, ref := range []struct {
		a, b pxlib.Lab
		want float64
	}{
		{pxlib.Lab{50.0, 2.6772, -79.7751}, pxlib.Lab{50.0, 0.0, -82.7485}, 2.0425},
		{pxlib.Lab{50.0, 2.5, 0.0}, pxlib.Lab{73.0, 25.0, -18.0}, 27.1492},
		{pxlib.Lab{22.7233, 20.0904, -46.6940}, pxlib.Lab{23.0331, 14.9730, -42.5619}, 2.0373},
	} {
		if math.Abs(pxlib.DeltaELab(ref.a, ref.b)-ref.want) > 0.001 {
			failures = append(failures, fmt.Sprintf("ΔE: CIEDE2000 の参照値 %s と合わない", pyFloat(ref.want)))
		}
	}

	if len(failures) > 0 {
		for _, line := range failures {
			fmt.Fprintln(errOut, line)
		}
		fmt.Fprintf(errOut, "self-test NG: %d 件\n", len(failures))
		return 1
	}
	fmt.Fprintf(out, "self-test OK: %d 例\n", len(cases))
	return 0
}

// pyFloat は小数を字面にする。整数値でも小数点以下 1 桁を残す。
func pyFloat(v float64) string {
	if v == math.Trunc(v) && math.Abs(v) < 1e16 {
		return strconv.FormatFloat(v, 'f', 1, 64)
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}

func containsAny(lines []string, needle string) bool {
	for _, line := range lines {
		if strings.Contains(line, needle) {
			return true
		}
	}
	return false
}
