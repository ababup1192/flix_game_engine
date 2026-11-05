package quadratic

// perf-near-scan — ループの中で List を頭から探す形を拾う。全員が全員を探すと N の二乗になり、
// 位置で探しているなら SpatialGrid・番号や名前で探しているなら Set / Map で引ける。
//
// 見るのは、List / Vector / Array を回すラムダの本体の List.filter / exists / find と、
// その本体が呼ぶ同じファイルの def の中の同じ形 (1 段だけ)。
// 回す物の大きさは字からは分からないので、止めずに知らせるだけにする。

import (
	"fmt"
	"regexp"
	"strings"
)

var (
	loopRe   = regexp.MustCompile(`\b(?:List|Vector|Array)\.(map|mapWithIndex|flatMap|filter|filterMap|forEach|forEachWithIndex|foldLeft|foldRight|exists|forAll|count|find)\s*\(`)
	scanRe   = regexp.MustCompile(`\bList\.(filter|exists|find)\s*\(`)
	callRe   = regexp.MustCompile(`(?:^|[^.#\w])([a-z][A-Za-z0-9_]*)\s*\(`)
	singleRe = regexp.MustCompile(`^\s*[a-z_][A-Za-z0-9_]*\s*->`)
)

// NearHit は知らせる 1 件。Line は探している所、LoopLine は回している所。
type NearHit struct {
	Path     string
	Line     int
	LoopLine int
	Def      string
	Loop     string // 回している口 (List.map など)
	Scan     string // 探している口 (List.filter など)
}

func (h NearHit) key() string { return h.Path + "::" + h.Def }

// lambdaBody は呼び出しの 1 つ目の引数がラムダなら本体の範囲を返す。
func lambdaBody(code string, open int) (int, int, bool) {
	end := argEnd(code, open)
	if params, start, ok := lambdaOf(code, open+1, end); ok && params != nil {
		return start, end, true
	}
	if m := singleRe.FindStringIndex(code[open+1 : end]); m != nil {
		return open + 1 + m[1], end, true
	}
	return 0, 0, false
}

// defSpans は def の名前ごとの本文の範囲 (次の def の手前まで)。同じ名前が複数あれば最初の物。
func defSpans(code string) map[string][2]int {
	spans := map[string][2]int{}
	found := defRe.FindAllStringSubmatchIndex(code, -1)
	for i, m := range found {
		end := len(code)
		if i+1 < len(found) {
			end = found[i+1][0]
		}
		name := code[m[2]:m[3]]
		if _, dup := spans[name]; !dup {
			spans[name] = [2]int{m[1], end}
		}
	}
	return spans
}

// ScanNear は 1 ファイルの本文から拾う。
func ScanNear(rel, text string) []NearHit {
	code := blank(text, true)
	spans := defSpans(code)
	var hits []NearHit
	seen := map[int]bool{}
	for _, m := range loopRe.FindAllStringIndex(code, -1) {
		open := m[1] - 1
		start, end, ok := lambdaBody(code, open)
		if !ok {
			continue
		}
		loop := strings.TrimSpace(code[m[0]:open])
		add := func(pos int, name string) {
			line := lineAt(text, pos)
			if seen[line] {
				return
			}
			seen[line] = true
			hits = append(hits, NearHit{Path: rel, Line: line, LoopLine: lineAt(text, m[0]), Def: defAt(code, pos), Loop: loop, Scan: name})
		}
		for _, s := range scanRe.FindAllStringIndex(code[start:end], -1) {
			add(start+s[0], strings.TrimSpace(strings.TrimSuffix(code[start+s[0]:start+s[1]], "(")))
		}
		called := map[string]bool{}
		for _, c := range callRe.FindAllStringSubmatch(code[start:end], -1) {
			called[c[1]] = true
		}
		for name := range called {
			span, known := spans[name]
			// WhyNot: ループを含む def 自身をたどらない — ラムダの外の探しまで拾ってしまう。
			if !known || (span[0] <= m[0] && m[0] < span[1]) {
				continue
			}
			for _, s := range scanRe.FindAllStringIndex(code[span[0]:span[1]], -1) {
				add(span[0]+s[0], strings.TrimSpace(strings.TrimSuffix(code[span[0]+s[0]:span[0]+s[1]], "(")))
			}
		}
	}
	return hits
}

// reportNear は知らせる行を書く。除外に載った物は書かない。
// WhyNot: 終了コードへ効かせない — 回す物の大きさが字から分からず誤検知が残るので、害を測れた形だけを後で止める規則へ上げる。
func reportNear(out *strings.Builder, rules *Rules, hits []NearHit) {
	shown := 0
	for _, h := range hits {
		if _, ok := rules.Exempt[h.key()]; ok {
			continue
		}
		shown++
		fmt.Fprintf(out, "?? %s:%d (%s) %s の中で %s を呼んでいます (回している所 %d 行目)\n", h.Path, h.Line, h.Def, h.Loop, h.Scan, h.LoopLine)
	}
	if shown > 0 {
		fmt.Fprintf(out, "[perf-near-scan] %d 件 (知らせるだけ)。回す物と探す物が同じ大きさなら二乗になります。"+
			"\n  位置の近さで探すなら SpatialGrid、番号や名前で探すなら先に Set / Map を 1 回作る (docs/performance.md「重くなったらこれ」)。"+
			"\n  小さいと決まった列なら quadratic.local.json (ゲーム) か quadratic.json (エンジン) の exempt へ \"パス::def の名前\" と理由 1 行\n", shown)
	}
}
