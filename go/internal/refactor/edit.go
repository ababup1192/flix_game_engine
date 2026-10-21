package refactor

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// Edit は 1 ファイルの中の 1 か所の書き換え。Start・End は元の中身のバイトの位置。
// Make は「今の中身（内側の書き換えを当てた後）」から新しい字を作る（外側の書き換えが内側の結果を写せるように）。
type Edit struct {
	File       string
	Start, End int
	Make       func(cur string) (string, error)
	Site       Row    // 元の場所（報告と --skip 用）
	Check      []Want // 当てる前に確かめる字（索引の範囲 → 字）
	Create     bool   // ファイルが無ければ空の中身から作る（move の移し先の新しい mod）。あれば普通の書き換え
}

// Want は「この範囲はこの字のはず」（索引が古くないかの確かめ）。
type Want struct {
	Span Row
	Text string
}

// ApplyEdits は 1 ファイルの書き換えを内側から順に当てた中身を返す。
// 範囲が交わるのに片方がもう片方を含まない物（解けない重なり）と、同じ範囲の 2 つは誤り。
func ApplyEdits(src string, edits []Edit) (string, error) {
	type span struct {
		s, e int
		i    int
	}
	spans := make([]span, len(edits))
	for i, ed := range edits {
		if ed.Start < 0 || ed.End > len(src) || ed.Start > ed.End {
			return "", fmt.Errorf("%s: 範囲 %d..%d が中身（%d バイト）の外", ed.Site.Where(), ed.Start, ed.End, len(src))
		}
		spans[i] = span{ed.Start, ed.End, i}
	}
	for a := 0; a < len(spans); a++ {
		for b := a + 1; b < len(spans); b++ {
			x, y := spans[a], spans[b]
			if x.s == y.s && x.e == y.e {
				return "", fmt.Errorf("同じ範囲を 2 度書き換える: %s と %s", edits[x.i].Site.Where(), edits[y.i].Site.Where())
			}
			overlap := x.s < y.e && y.s < x.e
			nested := (x.s <= y.s && y.e <= x.e) || (y.s <= x.s && x.e <= y.e)
			if overlap && !nested {
				return "", fmt.Errorf("解けない重なり: %s と %s（片方がもう片方を含まない）", edits[x.i].Site.Where(), edits[y.i].Site.Where())
			}
		}
	}
	// 内側（狭い物）から。同じ広さなら後ろから（前の位置をずらさない）。
	sort.SliceStable(spans, func(a, b int) bool {
		la, lb := spans[a].e-spans[a].s, spans[b].e-spans[b].s
		if la != lb {
			return la < lb
		}
		return spans[a].s > spans[b].s
	})
	text := src
	for k := range spans {
		cur := spans[k]
		repl, err := edits[cur.i].Make(text[cur.s:cur.e])
		if err != nil {
			return "", fmt.Errorf("%s: %v", edits[cur.i].Site.Where(), err)
		}
		text = text[:cur.s] + repl + text[cur.e:]
		delta := len(repl) - (cur.e - cur.s)
		for j := k + 1; j < len(spans); j++ {
			o := &spans[j]
			switch {
			// 字を足すだけの書き換え（空の範囲）が別の範囲の端にある時は、その範囲の外（頭なら前・終わりなら後ろ）。
			case cur.s == cur.e && o.s < o.e && cur.s == o.s:
				o.s += delta
				o.e += delta
			case cur.s == cur.e && o.s < o.e && cur.s == o.e:
			case o.s <= cur.s && cur.e <= o.e: // 含む
				o.e += delta
			case o.s >= cur.e: // 後ろ
				o.s += delta
				o.e += delta
			}
		}
	}
	return text, nil
}

// ByteRange は行・列（1 から・UTF-16）の範囲をバイトの位置にする。
func ByteRange(src string, r Row) (int, int, error) {
	lines := strings.SplitAfter(src, "\n")
	lineStart := func(line int) int {
		n := 0
		for i := 0; i < line-1 && i < len(lines); i++ {
			n += len(lines[i])
		}
		return n
	}
	s, err := offset(lines, r.Line, r.Col)
	if err != nil {
		return 0, 0, err
	}
	e, err := offset(lines, r.EndLine, r.EndCol)
	if err != nil {
		return 0, 0, err
	}
	return lineStart(r.Line) + s, lineStart(r.EndLine) + e, nil
}

// spanOf は extra の `sl:sc:el:ec` を Row にする。
func spanOf(file, s string) (Row, error) {
	var r Row
	if _, err := fmt.Sscanf(s, "%d:%d:%d:%d", &r.Line, &r.Col, &r.EndLine, &r.EndCol); err != nil {
		return r, fmt.Errorf("範囲 %q が読めない", s)
	}
	r.File = file
	return r, nil
}

// Planned は 1 回の操作の計画: ファイルごとの元の中身と新しい中身。
type Planned struct {
	Files map[string]string // 根からの相対 → 新しい中身
	Orig  map[string]string
	New   map[string]bool // 書く前に無かったファイル（戻す時は消す）
	Edits int
}

// Plan は書き換えをファイルごとに当てる（当てる前に Check の字を確かめる）。
func Plan(root string, edits []Edit) (*Planned, error) {
	by := map[string][]Edit{}
	for _, e := range edits {
		by[e.File] = append(by[e.File], e)
	}
	p := &Planned{Files: map[string]string{}, Orig: map[string]string{}, New: map[string]bool{}}
	files := make([]string, 0, len(by))
	for f := range by {
		files = append(files, f)
	}
	sort.Strings(files)
	for _, f := range files {
		data, err := os.ReadFile(filepath.Join(root, f))
		created := false
		if err != nil {
			if !os.IsNotExist(err) || !allCreate(by[f]) {
				return nil, err
			}
			data, created = nil, true
		}
		src := string(data)
		real := realRel(root, f)
		if created {
			p.New[real] = true
		}
		for _, e := range by[f] {
			for _, w := range e.Check {
				got, err := SpanText(src, w.Span)
				if err != nil {
					return nil, fmt.Errorf("索引が古い（%v）。bin/fge refactor index --rebuild の後にやり直す", err)
				}
				if got != w.Text {
					return nil, fmt.Errorf("索引が古い: %s の字が %q（索引では %q）。bin/fge refactor index --rebuild の後にやり直す", w.Span.Where(), got, w.Text)
				}
			}
		}
		out, err := ApplyEdits(src, by[f])
		if err != nil {
			return nil, err
		}
		p.Files[real], p.Orig[real] = out, src
		p.Edits += len(by[f])
	}
	return p, nil
}

// allCreate は edits が全部「無ければ作る」書き換えか。
func allCreate(edits []Edit) bool {
	for _, e := range edits {
		if !e.Create {
			return false
		}
	}
	return len(edits) > 0
}

// Diff は計画の unified diff（git apply・git apply -R にそのまま渡せる -p1 の形）。
// WhyNot: 自前の diff を書かないのは、git apply -R で戻す時に、同じ道具が書いた形なら必ず読めるため。
func Diff(dir string, p *Planned) (string, error) {
	tmp, err := os.MkdirTemp(dir, "diff-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmp)
	var b strings.Builder
	files := make([]string, 0, len(p.Files))
	for f := range p.Files {
		files = append(files, f)
	}
	sort.Strings(files)
	for _, f := range files {
		for side, body := range map[string]string{"a": p.Orig[f], "b": p.Files[f]} {
			path := filepath.Join(tmp, side, f)
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return "", err
			}
			if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
				return "", err
			}
		}
		cmd := exec.Command("git", "diff", "--no-index", "--no-color", "--no-prefix", "--", filepath.ToSlash(filepath.Join("a", f)), filepath.ToSlash(filepath.Join("b", f)))
		cmd.Dir = tmp
		out, err := cmd.Output()
		if err != nil {
			if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 1 {
				return "", fmt.Errorf("git diff が動かない: %v", err)
			}
		}
		b.Write(out)
	}
	return b.String(), nil
}

// realRel は symlink を辿った先の、根からの相対パス（engine の src は symlink 集で、git が知るのは先の方）。
// 根の外へ出る時と辿れない時は元のまま。
func realRel(root, f string) string {
	r, err1 := filepath.EvalSymlinks(root)
	p, err2 := filepath.EvalSymlinks(filepath.Join(root, f))
	if err1 != nil || err2 != nil {
		return f
	}
	rel, err := filepath.Rel(r, p)
	if err != nil || strings.HasPrefix(rel, "..") {
		return f
	}
	return filepath.ToSlash(rel)
}
