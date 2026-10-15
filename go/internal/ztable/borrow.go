package ztable

// 借用 — 同じパッケージの別のモジュールが決めた z を呼んでいる所。
//
// 借りた側から見ると、その z がどの帯・層の物なのかは貸した側のファイルにしか書かれていない。
// 貸した側が自分の画面の都合で数を動かすと、借りた側の前後も黙って変わる。
// 表 (tableFileNames) のモジュールから引くのは借用ではない (表はそのためにある)。
// パッケージの外 (エンジンの Render.zShiftedAll など) は z を作る道具で、表でも画面でもないので見ない。

import (
	"bufio"
	"regexp"
	"sort"
	"strings"
)

var (
	modDeclRe   = regexp.MustCompile(`^\s*(?:pub\s+)?mod\s+([A-Z][A-Za-z0-9_.]*)`)
	qualifiedRe = regexp.MustCompile(`\b([A-Z][A-Za-z0-9_]*)\.(z[A-Z][A-Za-z0-9_]*)\b`)
	useGroupRe  = regexp.MustCompile(`^\s*use\s+([A-Z][A-Za-z0-9_.]*)\.\{([^}]*)\}`)
	useOneRe    = regexp.MustCompile(`^\s*use\s+([A-Z][A-Za-z0-9_.]*)\.(z[A-Z][A-Za-z0-9_]*)\b`)
	zNameRe     = regexp.MustCompile(`^z[A-Z][A-Za-z0-9_]*$`)
)

// lastSegment は "A.B.C" の最後の名前。
// WhyNot: 入れ子のモジュールを丸ごとの名前で突き合わせないのは、呼ぶ側が
// use で短く書いた名前と、宣言の側の名前の書き方がそろわないため。
func lastSegment(name string) string {
	if i := strings.LastIndex(name, "."); i >= 0 {
		return name[i+1:]
	}
	return name
}

// zModule はパッケージの中で z の関数を持つモジュール 1 つ。
type zModule struct {
	path  string
	names map[string]bool
}

// moduleZDefs は 1 ファイルの本文から、モジュール名 → そこで宣言した z の関数名 を拾う。
// ファイルの中の mod はどれも同じ一覧にまとめる (どの mod の中かまでは追わない)。
func (r *Rules) moduleZDefs(text string) ([]string, map[string]bool) {
	var mods []string
	names := map[string]bool{}
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	for sc.Scan() {
		line := stripComment(sc.Text())
		if m := modDeclRe.FindStringSubmatch(line); m != nil {
			mods = append(mods, lastSegment(m[1]))
		}
		if m := r.ZDef.FindStringSubmatch(line); m != nil {
			names[m[1]] = true
		}
	}
	return mods, names
}

// stripComment は行の // 以降を落とす。
func stripComment(line string) string {
	if i := strings.Index(line, "//"); i >= 0 {
		return line[:i]
	}
	return line
}

// BorrowHits は 1 パッケージの本文 (パス → 本文) から借用を拾う。tables は表として扱うファイル
// (表のファイルが無いパッケージで z の数を 1 ファイルに集めていれば、そのファイルも表と同じ扱い)。
func (r *Rules) BorrowHits(bodies map[string]string, tables map[string]bool) []Hit {
	lenders := map[string]zModule{}
	ownMods := map[string][]string{}
	paths := make([]string, 0, len(bodies))
	for p := range bodies {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		mods, names := r.moduleZDefs(bodies[p])
		ownMods[p] = mods
		if tables[p] || len(names) == 0 {
			continue
		}
		for _, m := range mods {
			lenders[m] = zModule{path: p, names: names}
		}
	}

	var hits []Hit
	for _, p := range paths {
		own := map[string]bool{}
		for _, m := range ownMods[p] {
			own[m] = true
		}
		seen := map[string]bool{}
		add := func(line int, mod, name string) {
			lender, ok := lenders[mod]
			if !ok || own[mod] || !lender.names[name] || lender.path == p {
				return
			}
			key := mod + "." + name
			if seen[key] {
				return
			}
			seen[key] = true
			hits = append(hits, Hit{
				Def:    Def{Path: p, Line: line, Name: key},
				Borrow: lender.path,
			})
		}
		sc := bufio.NewScanner(strings.NewReader(bodies[p]))
		sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
		for n := 1; sc.Scan(); n++ {
			line := stripComment(sc.Text())
			if m := useGroupRe.FindStringSubmatch(line); m != nil {
				for _, item := range strings.Split(m[2], ",") {
					name := strings.TrimSpace(item)
					if zNameRe.MatchString(name) {
						add(n, lastSegment(m[1]), name)
					}
				}
				continue
			}
			if m := useOneRe.FindStringSubmatch(line); m != nil {
				add(n, lastSegment(m[1]), m[2])
				continue
			}
			for _, m := range qualifiedRe.FindAllStringSubmatch(line, -1) {
				add(n, m[1], m[2])
			}
		}
	}
	return hits
}
