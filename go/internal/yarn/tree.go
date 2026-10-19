package yarn

// 書き出す木（dialogue.json）の形。Flix の engine_world/src/Yarn.flix の fromJson が同じ形を読む
// （片方だけ欄を足すと、ゲームは既定値へ落ちて知らせずに台詞が欠ける）。

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// Version は木の JSON の形の版。形を変えたら上げ、Yarn.flix の読み手も合わせる。
// 書く版は木が使う物で決める（変数も条件も {式} も無い木は 1 のまま書く。
// いつも 2 にすると、文法を足す前に組んだゲームの dialogue.json が全部ずれて組み直しになる）。
const Version = 2

// versionOne は変数・条件・{式} の無い木の版（読める古い engine_world がある）。
const versionOne = 1

// Program は 1 つのフォルダの .yarn を全部読んだ物（ノード名はフォルダの中で 1 つ）。
//
// Vocab は組んだ時に読んだ語彙のパス（ゲームのルートから。--no-vocab なら空）。check と次の build は、
// 指定が無ければこれと同じ語彙で組み直す（テストのシナリオのように、隣に vocab.json を置かないフォルダのため）。
//
// Variables は <<declare>> の全部（どのノードに書いてもフォルダの中で 1 つ。実行の順には関わらない）。
type Program struct {
	Version   int         `json:"version"`
	Note      string      `json:"note"`
	Vocab     string      `json:"vocab"`
	Files     []string    `json:"files"`
	Variables []*Variable `json:"variables,omitempty"`
	Nodes     []*Node     `json:"nodes"`
}

// Node は title: 〜 --- 〜 === の 1 つ。
type Node struct {
	Title   string   `json:"title"`
	File    string   `json:"file"`
	Line    int      `json:"line"`
	Headers []Header `json:"headers"`
	Body    []*Stmt  `json:"body"`

	declared []*Variable // このノードに書いた <<declare>>（BuildProgram が Program.Variables へ集める）
}

// Header は title 以外のヘッダ（tags: や position: など。読むだけで実行には使わない）。
type Header struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

// Tag は #key:value（値の無い #key は Value が空）。
type Tag struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

// Stmt は本文の 1 文。Kind で使う欄が決まる:
//
//	line     Speaker・Text・Tags・Parts
//	options  Options（選択肢の並び。1 つずつ Speaker・Text・Tags・Parts・Condition・Body）
//	jump     Node
//	stop     （無し）
//	command  Name・Args・Tags
//	set      Name（$ から書く変数）・Expr
//	if       Clauses（上から順に見て、最初に真になった物の Body を流す。Condition の無い物は <<else>>）
//
// Parts は {式} のある行だけに書く（字と式の並び。Text は書いたとおりの {式} を残した字で、人とエディタが読む）。
type Stmt struct {
	Kind    string    `json:"kind"`
	Line    int       `json:"line"`
	Speaker string    `json:"speaker,omitempty"`
	Text    string    `json:"text,omitempty"`
	Parts   []*Part   `json:"parts,omitempty"`
	Tags    []Tag     `json:"tags,omitempty"`
	Options []*Option `json:"options,omitempty"`
	Node    string    `json:"node,omitempty"`
	Name    string    `json:"name,omitempty"`
	Args    []string  `json:"args,omitempty"`
	Expr    *Expr     `json:"expr,omitempty"`
	Clauses []*Clause `json:"clauses,omitempty"`
}

// Option は -> の 1 つ。Body は字下げした続き（選んだ時に流れ、終わると選択肢の後ろへ戻る）。
// Condition は行末の <<if 式>>（偽なら選べない印を付けて並べる。まとまりの全部が偽なら、まとまりごと飛ばす）。
type Option struct {
	Line      int     `json:"line"`
	Speaker   string  `json:"speaker,omitempty"`
	Text      string  `json:"text"`
	Parts     []*Part `json:"parts,omitempty"`
	Tags      []Tag   `json:"tags,omitempty"`
	Condition *Expr   `json:"condition,omitempty"`
	Body      []*Stmt `json:"body"`
}

// Part は {式} のある行の 1 切れ（Text か Expr のどちらか）。
type Part struct {
	Text string `json:"text,omitempty"`
	Expr *Expr  `json:"expr,omitempty"`
}

// Clause は <<if>>・<<elseif>>・<<else>> の 1 つ（<<else>> は Condition が無い）。
type Clause struct {
	Line      int     `json:"line"`
	Condition *Expr   `json:"condition,omitempty"`
	Body      []*Stmt `json:"body"`
}

// usesVersionTwo は木が版 2 の物（変数・条件・{式}）を使うか。
func usesVersionTwo(p *Program) bool {
	if len(p.Variables) > 0 {
		return true
	}
	found := false
	for _, n := range p.Nodes {
		walk(n.Body, func(s *Stmt) {
			if s.Kind == "set" || s.Kind == "if" || len(s.Parts) > 0 {
				found = true
			}
			for _, o := range s.Options {
				if o.Condition != nil || len(o.Parts) > 0 {
					found = true
				}
			}
		})
	}
	return found
}

// Encode は木を JSON の文字にする（< や & をそのまま残す。台詞の字が < になると人が読めない）。
func Encode(p *Program) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(p); err != nil {
		return nil, fmt.Errorf("木を JSON にできない: %v", err)
	}
	return buf.Bytes(), nil
}
