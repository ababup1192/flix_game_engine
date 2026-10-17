package status

// 閉じるボタンの口 (App.withCloseRequest) が繋がっているかの 1 行。
//
// WhyNot: precommit の検査にしないのは、これが「ある物が無い」というソース全体の性質で、
// コミットに載った差分だけを見る precommit とは噛み合わず、しかも止めない警告は
// コミットの出力に埋もれるため。status はセッションの最初にエージェントが必ず見る 1 画面なので、
// 止めずに目に入る。

import (
	"github.com/ababup1192/flix_game_engine/go/internal/flixdecl"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

func sectionCloseRequest(c *ctx, out *[]string) {
	if c.isDir("templates") {
		return // engine リポ自身。templates の Main は engine 側で面倒を見る
	}
	r := c.rules.CloseRequest
	launches := false
	for _, path := range flixdecl.FlixFiles(c.root, r.SrcDir) {
		text, err := pxlib.ReadTextReplace(path)
		if err != nil {
			continue
		}
		code := stripFlixComments(text)
		if r.Hook.MatchString(code) {
			return
		}
		if r.App.MatchString(code) {
			launches = true
		}
	}
	if launches {
		*out = append(*out, r.Message)
	}
}

// stripFlixComments は // から行末と /* */ を空白にする（改行は残す）。文字列・文字の
// リテラルの中の // や /* は残す（"assets/*.json" のような glob で後ろを飲み込まない）。
// WhyNot: 行頭の // だけを見る手抜きにしないのは、`|> App.launch // App.withCloseRequest は後で`
// のような行末のコメントで口があると読み違えるため。
func stripFlixComments(text string) string {
	src := []rune(text)
	out := make([]rune, 0, len(src))
	var quote rune // 0 / '"' / '\''
	line, block := false, false
	for i := 0; i < len(src); i++ {
		ch := src[i]
		next := rune(0)
		if i+1 < len(src) {
			next = src[i+1]
		}
		switch {
		case line:
			if ch == '\n' {
				line = false
				out = append(out, ch)
			}
		case block:
			if ch == '*' && next == '/' {
				block = false
				i++
			} else if ch == '\n' {
				out = append(out, ch)
			}
		case quote != 0:
			out = append(out, ch)
			if ch == '\\' && next != 0 {
				out = append(out, next)
				i++
			} else if ch == quote || ch == '\n' {
				quote = 0
			}
		case ch == '/' && next == '/':
			line = true
		case ch == '/' && next == '*':
			block = true
			i++
		default:
			if ch == '"' || ch == '\'' {
				quote = ch
			}
			out = append(out, ch)
		}
	}
	return string(out)
}
