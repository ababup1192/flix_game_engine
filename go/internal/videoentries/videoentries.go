// Package videoentries は、動画の見回り (全部の動画の入口を絵を描かずに流してコマごとに検査する口) が
// 流す入口の一覧を、ゲームの Makefile の動画の口から Flix のファイルへ書き出す。
//
//	fge-go video-entries [--root DIR]           書き出す (中身が同じなら書かない)
//	fge-go video-entries --check [--root DIR]   書いてある物が Makefile と食い違えば 1 で終わる (make lint)
//
// 入口の正は Makefile のレシピの `$(call <macro>,入口,…)` の行だけ。そこへ extraVar の変数
// ($(call) を通らない動画の口の入口) を足し、skipVar の変数 (見回りで流さない入口) を除く。
// Makefile に動画の口が 1 つも無ければ何も書かずに通す (動画を持たないゲーム)。
//
// 規約は bin/lint-rules/video-entries.json (makefile・out・module・macro・extraVar・skipVar)。
// ゲームは video-entries.local.json に同じ鍵を書けば上書きできる。
//
// WhyNot: 入口を Flix の側に手で並べないのは、動画の口を Makefile に足したのに見回りが流さない、
// という漏れが黙って起きるため。正を 1 か所にして、もう 1 か所は生成物にする。
package videoentries

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Name は規約ファイルの名前 (bin/lint-rules/<Name>.json)。
const Name = "video-entries"

// Rules は規約。すべて JSON から来る。
type Rules struct {
	Makefile string `json:"makefile"`
	Out      string `json:"out"`
	Module   string `json:"module"`
	Macro    string `json:"macro"`
	ExtraVar string `json:"extraVar"`
	SkipVar  string `json:"skipVar"`

	head *regexp.Regexp // $(call <macro>,…) を含む行か
	call *regexp.Regexp // $(call <macro>,入口,…) の入口
}

// compilePatterns は macro から正規表現を組む。LoadRules が local.json を重ねた後に 1 回だけ呼ぶ。
func (r *Rules) compilePatterns() *Rules {
	macro := regexp.QuoteMeta(r.Macro)
	r.head = regexp.MustCompile(`\$\(call\s+` + macro + `\s*[,)]`)
	r.call = regexp.MustCompile(`\$\(call\s+` + macro + `\s*,\s*([A-Za-z0-9_]+\.[A-Za-z0-9_]+)\s*,`)
	return r
}

// LoadRules は規約を読み、ゲームの上書き (local.json の書いた鍵だけ) を重ねる。
func LoadRules(root string) (*Rules, error) {
	rulesRel := filepath.Join("bin", "lint-rules", Name+".json")
	localRel := filepath.Join("bin", "lint-rules", Name+".local.json")
	var r Rules
	data, err := os.ReadFile(filepath.Join(root, rulesRel))
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("%s が壊れています: %v", filepath.ToSlash(rulesRel), err)
	}
	local, err := os.ReadFile(filepath.Join(root, localRel))
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		// WhyNot: 同じ構造体へ重ねて読むのは、local に書いた鍵だけが上書きされ、書かない鍵は engine の値が残るため。
		if err := json.Unmarshal(local, &r); err != nil {
			return nil, fmt.Errorf("%s が壊れています: %v", filepath.ToSlash(localRel), err)
		}
	}
	if r.Makefile == "" || r.Out == "" || r.Module == "" || r.Macro == "" || r.ExtraVar == "" || r.SkipVar == "" {
		return nil, fmt.Errorf("%s には makefile・out・module・macro・extraVar・skipVar が要ります", filepath.ToSlash(rulesRel))
	}
	return r.compilePatterns(), nil
}

// LogicalLines は行末の \ で続けた行を 1 行につなぐ。
func LogicalLines(text string) []string {
	return strings.Split(strings.ReplaceAll(text, "\\\n", " "), "\n")
}

// RecipeCalls はレシピの行 (タブで始まり、# で止めていない) のうち $(call <macro>,…) を含む行。
// WhyNot: 名前の前だけで探さないのは、$(call video-mix-env,…) のように名前が macro で始まる
// 別のマクロ (define video の中で呼ぶ物) まで拾い、入口を読めない行と言って止めるため。
func (r *Rules) RecipeCalls(text string) []string {
	var out []string
	for _, line := range LogicalLines(text) {
		if strings.HasPrefix(line, "\t") && !strings.HasPrefix(strings.TrimLeft(line, " \t"), "#") &&
			r.head.MatchString(line) {
			out = append(out, line)
		}
	}
	return out
}

// Variable は name の値 (:= / = / ?= で置いた値に += で足した物を順に)。
func Variable(text, name string) []string {
	re := regexp.MustCompile(`^` + regexp.QuoteMeta(name) + `\s*(\+=|:=|\?=|=)(.*)$`)
	var words []string
	for _, line := range LogicalLines(text) {
		m := re.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		if m[1] != "+=" {
			words = nil
		}
		words = append(words, strings.Fields(m[2])...)
	}
	return words
}

// Entries は流す入口を Makefile に並んだ順に返す (同じ入口は 1 回)。
func (r *Rules) Entries(text string) []string {
	skip := map[string]bool{}
	for _, s := range Variable(text, r.SkipVar) {
		skip[s] = true
	}
	var seen []string
	add := func(e string) {
		for _, s := range seen {
			if s == e {
				return
			}
		}
		seen = append(seen, e)
	}
	for _, line := range r.RecipeCalls(text) {
		if m := r.call.FindStringSubmatch(line); m != nil {
			add(m[1])
		}
	}
	for _, e := range Variable(text, r.ExtraVar) {
		add(e)
	}
	var out []string
	for _, e := range seen {
		if !skip[e] {
			out = append(out, e)
		}
	}
	return out
}

// Render は書き出す Flix の本文。
func (r *Rules) Render(names []string) string {
	calls := make([]string, len(names))
	for i, n := range names {
		calls[i] = "        " + n + "()"
	}
	return "// 生成物 — 手で直さない。bin/fge video-entries が " + r.Makefile + " の $(call " + r.Macro + ",入口,…) の行と\n" +
		"// " + r.ExtraVar + " / " + r.SkipVar + " から書く（動画の見回りが流す前に書き直す）。\n" +
		"mod " + r.Module + " {\n" +
		"\n" +
		"    /// 見回りで流す動画の入口を、Makefile に並んだ順に全部流す。\n" +
		"    pub def runAll(): Unit \\ IO =\n" +
		strings.Join(calls, ";\n") + "\n" +
		"}\n"
}

// Run は書き出す (check なら食い違いを見るだけ)。
func Run(out io.Writer, root string, check bool) (int, error) {
	const tag = "[video-entries]"
	r, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(r.Makefile)))
	if err != nil {
		return 2, err
	}
	text := string(body)
	names := r.Entries(text)
	if len(names) == 0 && len(r.RecipeCalls(text)) == 0 {
		fmt.Fprintf(out, "%s %s に $(call %s,…) の行が無いので見ていません\n", tag, r.Makefile, r.Macro)
		return 0, nil
	}
	if len(names) == 0 {
		return 2, fmt.Errorf("%s の動画の口がどれも %s で外されていて、流す入口が 1 つもありません", r.Makefile, r.SkipVar)
	}
	want := r.Render(names)
	outPath := filepath.Join(root, filepath.FromSlash(r.Out))
	have := ""
	if b, err := os.ReadFile(outPath); err == nil {
		have = string(b)
	}
	unread := 0
	for _, line := range r.RecipeCalls(text) {
		if !r.call.MatchString(line) {
			fmt.Fprintf(out, "%s 入口を読めない $(call %s …) の行: %s\n", tag, r.Macro, strings.TrimSpace(line))
			unread++
		}
	}
	if check {
		if unread > 0 {
			return 1, nil
		}
		if have != want {
			fmt.Fprintf(out, "%s %s が %s の動画の口と食い違います — bin/fge video-entries で書き直す\n", tag, r.Out, r.Makefile)
			return 1, nil
		}
		fmt.Fprintf(out, "%s OK\n", tag)
		return 0, nil
	}
	if have != want {
		if err := os.WriteFile(outPath, []byte(want), 0o644); err != nil {
			return 2, err
		}
		fmt.Fprintf(out, "%s %s を書き直しました\n", tag, r.Out)
	}
	return 0, nil
}
