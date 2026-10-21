package docrefs

// doc の呼び手: .flix のコメント（/// と //）に書いた「名前 ＋ が呼ぶ・から呼ぶ・が読む・が使う・が組む・が受け取る・で受け取る」を
// 数え、上限（callersLimitFile）より増やさない。呼び手の名前は関数を移すと古くなり、名前は今も在るので名前の確かめでは
// 止まらない（マージ前レビューで 3 回続いた）。doc には何をするか・なぜかを書き、呼び手は道具で引く。
//
//	/// `World.step` が呼ぶ。          → 数える（` ` の中の Mod.name）
//	/// View が読む入力。               → 数える（地の文の素の名前）
//	/// 盤の光（PuzzleScene.hover）が読む → 数える（閉じ括弧の直後の動詞も）
//	/// `A.first`・`B.second` から呼ぶ → 1 か所（区切りで並ぶ名前は 1 つにまとめる）
//	/// ゲームが読む Doc。              → 数えない（動詞の直前が名前でない）
//
// 数えない物は名前の確かめと同じ: 生成物の文書・予定の印・~~消し線~~・` ` の中の '…'（引用）。docs/*.md は見ない
// （.md は呼び手を説明する文書もあり、付く def も決まらない）。
//
// WhyNot: 呼び出しの事実（refactor の索引）と照らさないのは、照らせる書き方が少なく（Mod.name の形だけ）、索引は .flix を
// 触ると古くなるのでコミットの時にほぼ効かないため。字だけで数えれば速く、コミットの時にも効く。

import (
	"regexp"
	"strings"
	"unicode/utf8"
)

// callerVerbs は「名前 ＿」の名前を呼び手と読む動詞（名前の直後・間の空白と閉じ括弧と だけ・のみ は許す）。
var callerVerbs = []string{"が呼ぶ", "から呼ぶ", "が読む", "が使う", "が組む", "が受け取る", "で受け取る"}

// chainSeps は呼び手を並べる区切り（`A.first`・`B.second` が呼ぶ）。
var chainSeps = []string{"・", "、", "と", ",", "，", "/", "や"}

// bareRe は素の名前（Mod.name でない 1 語の識別子。2 字以上）。
var bareRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]+$`)

// Claim はコメントの中の「名前 が呼ぶ」1 つ。
type Claim struct {
	Line    int      // ファイルの行（1 から）
	Callers []string // 名前（区切りで並ぶ物は全部）
	Verb    string
}

// Text は書かれた形（A・B が呼ぶ）。
func (c Claim) Text() string { return strings.Join(c.Callers, "・") + " " + c.Verb }

// nameTok はコメントの 1 行の中の名前 1 つと、その字の範囲（` ` の物は ` ` を含む）。
type nameTok struct {
	text       string
	start, end int
	planned    bool
}

// ScanCallerClaims は .flix の本文のコメント（/// と //）から「名前 が呼ぶ」を拾う。
func ScanCallerClaims(text string, fileExt map[string]bool, planned []string) []Claim {
	var out []Claim
	for i, line := range strings.Split(text, "\n") {
		at := commentStart(line)
		if at < 0 {
			continue
		}
		for _, c := range lineClaims(strings.TrimLeft(line[at:], "/"), fileExt, planned) {
			c.Line = i + 1
			out = append(out, c)
		}
	}
	return out
}

// lineClaims はコメントの 1 行（// を除いた物）の「名前 が呼ぶ」。
func lineClaims(body string, fileExt map[string]bool, planned []string) []Claim {
	body = unstruck(body)
	if !utf8.ValidString(body) {
		return nil
	}
	toks := nameToks(body, fileExt, planned)
	var out []Claim
	for k, t := range toks {
		rest := strings.TrimLeft(body[t.end:], " 　")
		// 括弧の中の名前（盤の光（`PuzzleScene.hoveredCellOf`）が読む）も、閉じ括弧の直後の動詞を受ける。
		for _, p := range []string{"）", ")"} {
			if strings.HasPrefix(rest, p) {
				rest = strings.TrimLeft(rest[len(p):], " 　")
			}
		}
		// 「WorldFight と ReplayTrack だけが使う」の だけ・のみ も挟んでよい。
		for _, p := range []string{"だけ", "のみ"} {
			rest = strings.TrimPrefix(rest, p)
		}
		verb := ""
		for _, v := range callerVerbs {
			if strings.HasPrefix(rest, v) {
				verb = v
			}
		}
		if verb == "" || t.planned {
			continue
		}
		chain := []nameTok{t}
		for p := k - 1; p >= 0; p-- {
			if !contains(chainSeps, strings.TrimSpace(body[toks[p].end:chain[0].start])) {
				break
			}
			chain = append([]nameTok{toks[p]}, chain...)
		}
		c := Claim{Verb: verb}
		for _, n := range chain {
			c.Callers = append(c.Callers, n.text)
		}
		out = append(out, c)
	}
	return out
}

// flixTypes は Flix の基本の型の名前（「Float32 で受け取る」は受け取り方で、呼び手でない）。
var flixTypes = map[string]bool{"Bool": true, "Char": true, "String": true, "Unit": true, "Int8": true, "Int16": true, "Int32": true,
	"Int64": true, "Float32": true, "Float64": true, "BigInt": true, "BigDecimal": true}

// name は 1 語を名前として読む（Mod.name・欄の名指し・素の名前。仮の字・パス・ファイル名は名前でない）。
func name(w string, fileExt map[string]bool) (string, bool) {
	if r, ok := classify(w, 0, fileExt); ok {
		return r.Text, r.Kind == RefName
	}
	w = strings.Trim(w, ".:-")
	if bareRe.MatchString(w) && !placeholder(w) && !flixTypes[w] {
		return w, true
	}
	return "", false
}

// nameToks は 1 行の名前を字の順に並べる（` ` の中の物はその中の最初の名前で、範囲は ` ` ごと）。
func nameToks(body string, fileExt map[string]bool, planned []string) []nameTok {
	var out []nameTok
	parts := codeSpans(body)
	at := 0
	for k, p := range parts {
		if p.code {
			// codeSpans は字の順に返し、` ` の物の直前の字の物は ` の手前で切れる。` の数は本文から数える。
			n := 0
			for at+n < len(body) && body[at+n] == '`' {
				n++
			}
			end := at + n + len(p.text) + n
			for _, w := range words(unquoted(p.text)) {
				if s, ok := name(w.text, fileExt); ok {
					pl := k+1 < len(parts) && plannedAfter(parts[k+1].text, planned)
					out = append(out, nameTok{text: s, start: at, end: end, planned: pl})
					break
				}
			}
			at = end
			continue
		}
		for _, w := range words(p.text) {
			s, ok := name(w.text, fileExt)
			if !ok {
				continue
			}
			wordStart := at + w.end - len(w.text)
			st := wordStart + strings.Index(w.text, s)
			out = append(out, nameTok{text: s, start: st, end: st + len(s), planned: plannedAfter(p.text[w.end:], planned)})
		}
		at += len(p.text)
	}
	return out
}

// callerHits は .flix 1 本の「名前 が呼ぶ」を当たりにする。
func callerHits(doc, text string, fileExt map[string]bool, planned []string) []Hit {
	var out []Hit
	for _, c := range ScanCallerClaims(text, fileExt, planned) {
		out = append(out, Hit{Code: CodeCaller, Doc: doc, Line: c.Line, Text: c.Text(), Msg: "doc に呼び手を書いている", Caller: true})
	}
	return out
}
