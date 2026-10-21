package docrefs

// 文書（.md）から確かめる物を拾う所。` ` の中と表の行（| で始まる行）だけを見て、``` の中は見ない。

import (
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// RefKind は拾った物の種類。
type RefKind int

const (
	RefName RefKind = iota // Mod.name
	RefFile                // src/World.flix・docs/x.md（/ を含むパス）
	RefLine                // path:行（path:行-行）
)

// Ref は文書の 1 か所。
type Ref struct {
	Kind RefKind
	Line int    // 文書の行（1 から）
	Text string // 書かれた字（World.moveTo・src/World.flix:120-130）
	Path string // RefFile・RefLine のパス
	From int    // RefLine の行（から）
	To   int    // RefLine の行（まで。1 行なら From と同じ）
	// Engine は「engine の `docs/…`」のようにエンジンの物と書いてある所（ゲームのリポでは引かない）。
	Engine bool
}

var (
	nameRe = regexp.MustCompile(`^[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$`)
	lineRe = regexp.MustCompile(`^([A-Za-z0-9_./-]*[A-Za-z0-9_-]\.[A-Za-z0-9]+):([0-9]+)(?:-([0-9]+))?(?::[0-9]+)?$`)
	pathRe = regexp.MustCompile(`^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+$`)
)

// wordByte は 1 語に含める字（ASCII の英数字と、パス・名前・目印に使う記号）。ほかの字（空白・` ・|・括弧・
// カンマ・日本語）で語を切る。
func wordRune(r rune) bool {
	switch {
	case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		return true
	}
	return strings.ContainsRune("_./:-#*<>$~@{}…", r)
}

// placeholder は書き手の仮の字（<名前>・*・{a,b}・$(…)・…・#）を含む語か（確かめない）。
func placeholder(w string) bool {
	return strings.ContainsAny(w, "*<>${}~@#") || strings.Contains(w, "…") || strings.HasPrefix(w, "/") ||
		strings.Contains(w, "//") || strings.Contains(w, "..") || strings.HasPrefix(w, "http")
}

// enginePrefixes は直前に置くと「エンジンの物」と読む字（AGENTS.md の「engine の `docs/…`」の書き方）。
var enginePrefixes = []string{"engine の", "engine の ", "エンジンの", "engine's", "engine "}

// words は字列を語に切る。
func words(s string) []string {
	var out []string
	start := -1
	for i, r := range s {
		if wordRune(r) {
			if start < 0 {
				start = i
			}
			continue
		}
		if start >= 0 {
			out = append(out, s[start:i])
			start = -1
		}
	}
	if start >= 0 {
		out = append(out, s[start:])
	}
	return out
}

// span は 1 行の中の切れ目 1 つ（` ` の中身か、その外の字）。
type span struct {
	text   string
	code   bool
	engine bool // 直前が「engine の」
}

// codeSpans は 1 行を ` ` の中身（同じ数の ` で閉じる物）とその外の字に分ける。閉じない ` は字のまま。
func codeSpans(line string) []span {
	var out []span
	plain := 0
	for i := 0; i < len(line); {
		if line[i] != '`' {
			i++
			continue
		}
		n := 0
		for i+n < len(line) && line[i+n] == '`' {
			n++
		}
		fence := strings.Repeat("`", n)
		rest := line[i+n:]
		end := -1
		for off := 0; off < len(rest); {
			j := strings.Index(rest[off:], fence)
			if j < 0 {
				break
			}
			j += off
			k := j + n
			if (j == 0 || rest[j-1] != '`') && (k >= len(rest) || rest[k] != '`') {
				end = j
				break
			}
			off = k
			for off < len(rest) && rest[off] == '`' {
				off++
			}
		}
		if end < 0 {
			i += n
			continue
		}
		before := strings.TrimRight(line[:i], " ")
		eng := false
		for _, p := range enginePrefixes {
			if strings.HasSuffix(before, strings.TrimRight(p, " ")) {
				eng = true
			}
		}
		out = append(out, span{text: line[plain:i]}, span{text: rest[:end], code: true, engine: eng})
		i += n + end + n
		plain = i
	}
	return append(out, span{text: line[plain:]})
}

// classify は 1 語を Ref にする（確かめない物は ok=false）。fileExt は Mod.name でなくファイル名と読む末尾。
func classify(w string, line int, fileExt map[string]bool) (Ref, bool) {
	w = strings.TrimRight(w, ".:-")
	w = strings.TrimLeft(w, ".:-")
	if w == "" || placeholder(w) {
		return Ref{}, false
	}
	if m := lineRe.FindStringSubmatch(w); m != nil {
		from, _ := strconv.Atoi(m[2])
		to := from
		if m[3] != "" {
			to, _ = strconv.Atoi(m[3])
		}
		if from <= 0 || to < from {
			return Ref{}, false
		}
		return Ref{Kind: RefLine, Line: line, Text: w, Path: m[1], From: from, To: to}, true
	}
	if strings.Contains(w, ":") {
		return Ref{}, false
	}
	if strings.Contains(w, "/") {
		last := w[strings.LastIndex(w, "/")+1:]
		dot := strings.LastIndex(last, ".")
		if !pathRe.MatchString(w) || dot <= 0 || !fileExt[last[dot+1:]] {
			return Ref{}, false
		}
		return Ref{Kind: RefFile, Line: line, Text: w, Path: w}, true
	}
	if nameRe.MatchString(w) {
		last := w[strings.LastIndex(w, ".")+1:]
		// WhyNot: 1 字の最後の節（Phase.X・Scene.X）は書き手の仮の字として見ない。
		if fileExt[last] || len(last) == 1 {
			return Ref{}, false
		}
		return Ref{Kind: RefName, Line: line, Text: w}, true
	}
	return Ref{}, false
}

// unstruck は ~~消し線~~ の中を空白にする（消した物を記録として残す書き方。確かめない）。
func unstruck(line string) string {
	for {
		i := strings.Index(line, "~~")
		if i < 0 {
			return line
		}
		j := strings.Index(line[i+2:], "~~")
		if j < 0 {
			return line
		}
		end := i + 2 + j + 2
		line = line[:i] + strings.Repeat(" ", end-i) + line[end:]
	}
}

// ScanMarkdown は文書の本文から確かめる物を拾う（同じ行の同じ字は 1 つ）。
func ScanMarkdown(text string, fileExt map[string]bool) []Ref {
	var out []Ref
	inFence := false
	fenceMark := ""
	inComment := false
	for i, line := range strings.Split(text, "\n") {
		n := i + 1
		t := strings.TrimSpace(line)
		if inFence {
			if strings.HasPrefix(t, fenceMark) {
				inFence = false
			}
			continue
		}
		if strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~") {
			inFence, fenceMark = true, t[:3]
			continue
		}
		// HTML のコメント（<!-- -->）の中は書き手の控えで、確かめない。
		if inComment {
			if strings.Contains(line, "-->") {
				inComment = false
			}
			continue
		}
		if strings.HasPrefix(t, "<!--") && !strings.Contains(t, "-->") {
			inComment = true
			continue
		}
		line = unstruck(line)
		table := strings.HasPrefix(t, "|")
		seen := map[string]bool{}
		for _, p := range codeSpans(line) {
			if !p.code && !table || !utf8.ValidString(p.text) {
				continue
			}
			for _, w := range words(p.text) {
				r, ok := classify(w, n, fileExt)
				if !ok || seen[r.Text] {
					continue
				}
				seen[r.Text] = true
				r.Engine = p.engine
				out = append(out, r)
			}
		}
	}
	return out
}
