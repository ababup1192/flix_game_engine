package checkres

// Brief — 道具の人向けの答えの形（出力の約束。docs/check-results.md の「道具の答え」）。
//
// 道具の出力はそのまま AI の読む量になるので、既定は数行にする: 何に当てたか 1 行・数 1 行・注 0〜3 行・
// 結末と直し方 0〜2 行・場所の上位 N 行・ファイルごとの数 1 行・全部の置き場 1 行・終わりに次のコマンド。
// 場所の全部・diff・ログはファイルに書き、画面には場所だけ。-v（verbose）は道具が今までの全文を出す。
//
// 道具は Brief の値を作って返すだけで、場所の行を自分で回して画面へ書かない（場所の一覧は Sites でしか画面へ出ない）。

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

// MaxNotes は既定の答えに出す注の行の数（残りは「-v で」と 1 行）。
const MaxNotes = 3

// Sites は場所の一覧: 人向けの行（頭が file:line:col・列はタブで区切る）と、画面に出す数・全部を書いたファイル。
type Sites struct {
	Lines []string
	Limit int    // 画面に出す行の数（0 は全部）
	Path  string // 全部を書いたファイル（Save が切った時に入れる）
}

// Truncated は画面に出す行より多いか。
func (s Sites) Truncated() bool { return s.Limit > 0 && len(s.Lines) > s.Limit }

// Save は切って見せる時に、行の全部を path へ書く（書けたら Path に入れる）。切らない時は書かない。
func (s *Sites) Save(path string) {
	if !s.Truncated() {
		return
	}
	if os.MkdirAll(filepath.Dir(path), 0o755) != nil {
		return
	}
	if os.WriteFile(path, []byte(strings.Join(AlignTabs(s.Lines), "\n")+"\n"), 0o644) == nil {
		s.Path = path
	}
}

// Write は上位 Limit 行を出し、切った時はファイルごとの数と、全部の置き場を 1 行ずつ。shown は Path を画面に出す時の字面。
func (s Sites) Write(b *strings.Builder, indent string, shown func(string) string) {
	lines := s.Lines
	if s.Truncated() {
		lines = lines[:s.Limit]
	}
	for _, l := range AlignTabs(lines) {
		fmt.Fprintf(b, "%s%s\n", indent, l)
	}
	if !s.Truncated() {
		return
	}
	if files := PerFile(s.Lines); files != "" {
		fmt.Fprintf(b, "%sファイルごと: %s\n", indent, files)
	}
	where := "--all で全部・--json"
	if s.Path != "" {
		p := s.Path
		if shown != nil {
			p = shown(p)
		}
		where = "全部は " + p + "・--all で画面に"
	}
	fmt.Fprintf(b, "%s…ほか %d 件（%s）\n", indent, len(s.Lines)-s.Limit, where)
}

// Brief は 1 回の答えの短い形。空の欄の行は出さない。
type Brief struct {
	Head    string   // 何に当てたか（例 usages World.moveTo（def・src/World.flix:120:13））
	Count   string   // 数の 1 行
	Notes   []string // 注（MaxNotes 行まで出す）
	State   string   // 結末か歯止めの 1 行（例 dry-run（diff: …）・fail: 12 件（--max 0 を超えた））
	Fix     string   // 直し方の 1 行
	Sites   Sites
	Next    string              // 写してそのまま流せるコマンドだけ
	NextWhy string              // next の訳（next が無ければこれが next の行になる）
	Shown   func(string) string // ファイルの場所を画面に出す字面（nil はそのまま）
	Done    string              // 言い切りの 1 行（いつも最後の行。例 done: 36 sites → 0 left outside World · check ok）
}

// Text は Brief を人向けの字にする。
func (r Brief) Text() string {
	var b strings.Builder
	b.WriteString(r.Head + "\n")
	if r.Count != "" {
		fmt.Fprintf(&b, "  %s\n", r.Count)
	}
	notes := r.Notes
	if len(notes) > MaxNotes {
		notes = append(append([]string{}, notes[:MaxNotes]...), fmt.Sprintf("（注ほか %d 行は -v で）", len(r.Notes)-MaxNotes))
	}
	for _, n := range notes {
		fmt.Fprintf(&b, "  %s\n", n)
	}
	if r.State != "" {
		fmt.Fprintf(&b, "  %s\n", r.State)
	}
	if r.Fix != "" {
		fmt.Fprintf(&b, "  fix: %s\n", r.Fix)
	}
	r.Sites.Write(&b, "  ", r.Shown)
	switch {
	case r.Next != "":
		fmt.Fprintf(&b, "next: %s\n", r.Next)
		if r.NextWhy != "" {
			fmt.Fprintf(&b, "  （%s）\n", r.NextWhy)
		}
	case r.NextWhy != "":
		fmt.Fprintf(&b, "next: %s\n", r.NextWhy)
	}
	if r.Done != "" {
		b.WriteString(r.Done + "\n")
	}
	return b.String()
}

// PerFile は「src/World.flix 12・src/Main.flix 5・…ほか 3 ファイル」（行の頭の file:line:col から数える。多い順に 6 つ）。
func PerFile(lines []string) string {
	n := map[string]int{}
	for _, l := range lines {
		f, _, ok := strings.Cut(strings.TrimSpace(l), ":")
		if ok && strings.Contains(f, ".") && !strings.ContainsAny(f, " \t") {
			n[f]++
		}
	}
	files := make([]string, 0, len(n))
	for f := range n {
		files = append(files, f)
	}
	sort.Slice(files, func(i, j int) bool {
		if n[files[i]] != n[files[j]] {
			return n[files[i]] > n[files[j]]
		}
		return files[i] < files[j]
	})
	var parts []string
	for i, f := range files {
		if i == 6 {
			parts = append(parts, fmt.Sprintf("…ほか %d ファイル", len(files)-6))
			break
		}
		parts = append(parts, fmt.Sprintf("%s %d", f, n[f]))
	}
	return strings.Join(parts, "・")
}

// AlignTabs はタブで区切った列を、出す行の中で一番長い字に揃える（最後の列は揃えない）。幅は見た目の字数
// （日本語も 1）で数える。固定の幅にしないのは、短い名前ばかりの時に空白で読む量を増やさないため。
func AlignTabs(lines []string) []string {
	var width []int
	cells := make([][]string, len(lines))
	for i, l := range lines {
		cells[i] = strings.Split(l, "\t")
		for j, c := range cells[i][:len(cells[i])-1] {
			if j >= len(width) {
				width = append(width, 0)
			}
			width[j] = max(width[j], utf8.RuneCountInString(c))
		}
	}
	out := make([]string, len(lines))
	for i, cs := range cells {
		var b strings.Builder
		for j, c := range cs {
			b.WriteString(c)
			if j < len(cs)-1 {
				b.WriteString(strings.Repeat(" ", width[j]-utf8.RuneCountInString(c)+2))
			}
		}
		out[i] = strings.TrimRight(b.String(), " ")
	}
	return out
}
