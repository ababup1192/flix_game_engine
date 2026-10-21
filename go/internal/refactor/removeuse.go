package refactor

// remove-use: 使っていない use・import を消す（lint の unused-use の直し）。
//
//	remove-use <file>:<行>     その行の use の使っていない名前
//	remove-use <file> --all    そのファイルの全部
//	remove-use --all           sources の全部
//
// どれが使っていないかは flixlint の unused-use と同じ判定（unuseduse.go）。波括弧の中（use A.{b, c}）なら名前を
// 1 つ消し、全部消えた use は行ごと消す（直後の空行が残って 2 つ並ぶなら 1 つ消す）。書けない形（同じ行に別の物が
// ある・名前が見つからない）は fix。

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// useDecl は 1 つの use・import の宣言の字の範囲（バイト）と、波括弧の中の名前の並び。
type useDecl struct {
	start, end  int       // 宣言（use … の頭から、終わりの字の次まで）
	open, close int       // 波括弧の { と } の位置（無ければ -1）
	path        string    // use の後ろの名前（波括弧の前まで・=> の前まで）
	items       []useItem // 波括弧の中の名前（無ければ空）
}

type useItem struct {
	start, end int    // 中の 1 つの字（前後の空白を除く）
	name       string // 頭の名前（b => c なら b）
}

// parseUseDecl は src の line（1 から）の行の頭の use・import を読む。
func parseUseDecl(src string, line int) (useDecl, error) {
	d := useDecl{open: -1, close: -1}
	at := lineOffset(src, line)
	if at < 0 {
		return d, fmt.Errorf("%d 行目が無い", line)
	}
	i := at
	for i < len(src) && (src[i] == ' ' || src[i] == '\t') {
		i++
	}
	var kw string
	for _, k := range []string{"use ", "import "} {
		if strings.HasPrefix(src[i:], k) {
			kw = k
		}
	}
	if kw == "" {
		return d, fmt.Errorf("行の頭が use・import でない")
	}
	d.start = i
	j := i + len(kw)
	for j < len(src) && src[j] == ' ' {
		j++
	}
	k := j
	for k < len(src) && src[k] != '{' && src[k] != '\n' && src[k] != ' ' && src[k] != '\r' {
		k++
	}
	d.path = strings.TrimSuffix(src[j:k], ".")
	if k < len(src) && src[k] == '{' {
		d.open = k
		depth := 0
		for m := k; m < len(src); m++ {
			switch src[m] {
			case '{':
				depth++
			case '}':
				depth--
				if depth == 0 {
					d.close = m
				}
			}
			if d.close >= 0 {
				break
			}
		}
		if d.close < 0 {
			return d, fmt.Errorf("波括弧が閉じない")
		}
		d.end = d.close + 1
		from := d.open + 1
		for m := d.open + 1; m <= d.close; m++ {
			if m == d.close || src[m] == ',' {
				part := src[from:m]
				s := from + len(part) - len(strings.TrimLeft(part, " \t\r\n"))
				e := m - (len(part) - len(strings.TrimRight(part, " \t\r\n")))
				if s < e {
					name := src[s:e]
					if f := strings.Fields(name); len(f) > 0 {
						name = f[0]
					}
					d.items = append(d.items, useItem{s, e, name})
				}
				from = m + 1
			}
		}
		return d, nil
	}
	// 波括弧の無い宣言: 行の終わりまで（=> の別名も含む）。
	e := strings.IndexByte(src[i:], '\n')
	if e < 0 {
		e = len(src) - i
	}
	d.end = i + len(strings.TrimRight(src[i:i+e], " \t\r"))
	return d, nil
}

// lineOffset は line（1 から）の行の頭のバイトの位置（無ければ -1）。
func lineOffset(src string, line int) int {
	at := 0
	for n := 1; n < line; n++ {
		k := strings.IndexByte(src[at:], '\n')
		if k < 0 {
			return -1
		}
		at += k + 1
	}
	if at > len(src) {
		return -1
	}
	return at
}

func lastSeg(name string) string {
	if i := strings.LastIndexAny(name, "."); i >= 0 {
		return name[i+1:]
	}
	return name
}

// removeUseEdit は file の line の宣言から names（取り込んだ物の名前）を消す書き換え。消せない時は誤り（fix へ）。
func removeUseEdit(src, file string, line int, names []string) (Edit, error) {
	site := Row{Kind: KindUse, File: file, Line: line, Col: 1}
	d, err := parseUseDecl(src, line)
	// 折った波括弧の中の行（lint は名前の行を言う）: 上へ戻って、その行を波括弧に含む use を探す。
	for l := line - 1; err != nil && l >= 1 && l >= line-50; l-- {
		if up, upErr := parseUseDecl(src, l); upErr == nil && up.open >= 0 && up.close >= lineOffset(src, line) {
			d, err, line = up, nil, l
		}
	}
	if err != nil {
		return Edit{}, err
	}
	drop := map[string]bool{}
	for _, n := range names {
		drop[lastSeg(n)] = true
	}
	whole := false
	if d.open < 0 {
		if !drop[lastSeg(d.path)] {
			return Edit{}, fmt.Errorf("use の名前 %s が %s と合わない", d.path, strings.Join(names, "・"))
		}
		whole = true
	} else {
		left := 0
		for _, it := range d.items {
			if !drop[it.name] {
				left++
			}
		}
		matched := len(d.items) - left
		if matched != len(drop) {
			return Edit{}, fmt.Errorf("波括弧の中に %s が見つからない", strings.Join(names, "・"))
		}
		whole = left == 0
	}
	if whole {
		ls := lineOffset(src, line)
		if strings.TrimSpace(src[ls:d.start]) != "" {
			return Edit{}, fmt.Errorf("同じ行の use の前に別の物がある")
		}
		end := d.end
		nl := strings.IndexByte(src[end:], '\n')
		rest := src[end:]
		if nl >= 0 {
			rest = src[end : end+nl]
		}
		if strings.TrimSpace(rest) != "" {
			return Edit{}, fmt.Errorf("同じ行の use の後ろに別の物がある")
		}
		if nl >= 0 {
			end += nl + 1
		} else {
			end = len(src)
		}
		// 消した後に空行が 2 つ並ぶ・{ の直後に空行が残るなら、後ろの空行を 1 つ消す。
		if next := strings.IndexByte(src[end:], '\n'); next >= 0 && strings.TrimSpace(src[end:end+next]) == "" {
			prev := ""
			if ls > 0 {
				before := src[:ls-1]
				prev = before[strings.LastIndexByte(before, '\n')+1:]
			}
			if ls > 0 && (strings.TrimSpace(prev) == "" || strings.HasSuffix(strings.TrimSpace(prev), "{")) {
				end += next + 1
			}
		}
		return Edit{File: file, Start: ls, End: end, Site: site, Make: func(string) (string, error) { return "", nil }}, nil
	}
	// 波括弧の中の名前だけ: 後ろに続く名前があればその頭まで、最後の物なら前の名前の終わりから消す。
	keep := d.items[:0:0]
	for _, it := range d.items {
		if !drop[it.name] {
			keep = append(keep, it)
		}
	}
	var b strings.Builder
	b.WriteString(src[d.start:d.items[0].start])
	for k, it := range keep {
		if k > 0 {
			// 元の並びの区切り（, と空白・改行）を、残した物の前の物から写す。
			b.WriteString(sepBefore(src, d.items, it))
		}
		b.WriteString(src[it.start:it.end])
	}
	b.WriteString(src[d.items[len(d.items)-1].end:d.end])
	repl := b.String()
	return Edit{File: file, Start: d.start, End: d.end, Site: site, Make: func(string) (string, error) { return repl, nil }}, nil
}

// sepBefore は it の前の区切り（前の名前の終わりから it の頭まで: `, ` や `,\n    `）。
func sepBefore(src string, items []useItem, it useItem) string {
	for k := 1; k < len(items); k++ {
		if items[k].start == it.start {
			return src[items[k-1].end:it.start]
		}
	}
	return ", "
}

// removeUseReport は remove-use の入口。
func removeUseReport(root string, a args, cfg Config, o Options, b Builder) (report, error) {
	found, err := b.UnusedUses()
	if err != nil {
		return report{}, fmt.Errorf("使っていない use を flixlint の判定で探せない: %v", err)
	}
	file, line := a.target, 0
	if f, l, ok := strings.Cut(a.target, ":"); ok {
		n, convErr := strconv.Atoi(l)
		if convErr != nil || n < 1 {
			return report{}, fmt.Errorf("行は 1 以上の数で: %s", a.target)
		}
		file, line = f, n
	}
	file = filepath.ToSlash(file)
	type key struct {
		file string
		line int
	}
	groups := map[key][]UseFinding{}
	var order []key
	for _, f := range found {
		if file != "" && f.File != file || line > 0 && f.Line != line {
			continue
		}
		k := key{f.File, f.Line}
		if _, ok := groups[k]; !ok {
			order = append(order, k)
		}
		groups[k] = append(groups[k], f)
	}
	sort.Slice(order, func(i, j int) bool {
		if order[i].file != order[j].file {
			return order[i].file < order[j].file
		}
		return order[i].line < order[j].line
	})
	var edits []Edit
	var sites, fix []Fixed
	names := 0
	srcs := map[string]string{}
	for _, k := range order {
		src, ok := srcs[k.file]
		if !ok {
			data, err := os.ReadFile(filepath.Join(root, k.file))
			if err != nil {
				return report{}, err
			}
			src = string(data)
			srcs[k.file] = src
		}
		var ns []string
		for _, f := range groups[k] {
			ns = append(ns, f.Name)
		}
		row := Row{Kind: KindUse, File: k.file, Line: k.line, Col: 1, Sym: strings.Join(ns, "・"), Owner: groups[k][0].Module}
		if a.skip[fmt.Sprintf("%s:%d", k.file, k.line)] {
			fix = append(fix, Fixed{row, "--skip で外した"})
			continue
		}
		e, err := removeUseEdit(src, k.file, k.line, ns)
		if err != nil {
			fix = append(fix, Fixed{row, err.Error() + "（手で消す）"})
			continue
		}
		e.Site = row
		edits = append(edits, e)
		sites = append(sites, Fixed{row, "使っていない"})
		names += len(ns)
	}
	out := Change(root, edits, a.applyWith(cfg.Verify, o))
	target := a.target
	if target == "" {
		target = "（全部のファイル）"
	}
	r := report{Op: "remove-use", Target: target, code: CodeRemoveUse, Outcome: &out, Fix: fix}
	r.got = len(fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = len(sites) + len(fix)
	}
	r.Sites = sites
	files := map[string]bool{}
	for _, s := range sites {
		files[s.File] = true
	}
	r.gotText = fmt.Sprintf("使っていない use %d（名前 %d・%d ファイル）・人へ回す %d", len(sites), names, len(files), len(fix))
	r.wantText = "flixlint の unused-use の違反 0（書けない形は fix）"
	r.extra = append(r.extra, fmt.Sprintf("判定は flixlint の unused-use と同じ（Flixlint.Flix.namesUsed・isUnused・resolved の段。全体で %d）", len(found)))
	for _, s := range sites {
		r.lines = append(r.lines, fmt.Sprintf("%s:%d\t消す\t%s（%s）", s.File, s.Line, s.Sym, s.Owner))
	}
	for _, f := range fix {
		r.fixLines = append(r.fixLines, fmt.Sprintf("%s:%d\tfix\t%s（%s）", f.File, f.Line, f.Sym, f.Why))
	}
	base := "bin/fge refactor remove-use"
	if a.target != "" {
		base += " " + a.target
	}
	if a.all {
		base += " --all"
	}
	nextOf(&r, base, a, &out)
	switch {
	case out.State == StateNothing && len(fix) == 0:
		r.NextWhy = "当てる所が無い（使っていない use は 0。全体は bin/fge refactor usages --unused）"
	case out.State == StateApplied:
		r.Done = fmt.Sprintf("done: %d names → 消した · check ok", names)
		r.Next, r.NextWhy = "bin/fge refactor usages --unused", "残りの使っていない use と pub の def"
		r.lines = nil
	}
	return r, nil
}
