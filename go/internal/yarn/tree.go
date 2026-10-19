package yarn

// 書き出す木（dialogue.json）の形。Flix の engine_world/src/Yarn.flix の fromJson が同じ形を読む
// （片方だけ欄を足すと、ゲームは既定値へ落ちて知らせずに台詞が欠ける）。

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// Version は木の JSON の形の版。形を変えたら上げ、Yarn.flix の読み手も合わせる。
const Version = 1

// Program は 1 つのフォルダの .yarn を全部読んだ物（ノード名はフォルダの中で 1 つ）。
type Program struct {
	Version int      `json:"version"`
	Note    string   `json:"note"`
	Files   []string `json:"files"`
	Nodes   []*Node  `json:"nodes"`
}

// Node は title: 〜 --- 〜 === の 1 つ。
type Node struct {
	Title   string   `json:"title"`
	File    string   `json:"file"`
	Line    int      `json:"line"`
	Headers []Header `json:"headers"`
	Body    []*Stmt  `json:"body"`
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
//	line     Speaker・Text・Tags
//	options  Options（選択肢の並び。1 つずつ Speaker・Text・Tags・Body）
//	jump     Node
//	stop     （無し）
//	command  Name・Args・Tags
type Stmt struct {
	Kind    string    `json:"kind"`
	Line    int       `json:"line"`
	Speaker string    `json:"speaker,omitempty"`
	Text    string    `json:"text,omitempty"`
	Tags    []Tag     `json:"tags,omitempty"`
	Options []*Option `json:"options,omitempty"`
	Node    string    `json:"node,omitempty"`
	Name    string    `json:"name,omitempty"`
	Args    []string  `json:"args,omitempty"`
}

// Option は -> の 1 つ。Body は字下げした続き（選んだ時に流れ、終わると選択肢の後ろへ戻る）。
type Option struct {
	Line    int     `json:"line"`
	Speaker string  `json:"speaker,omitempty"`
	Text    string  `json:"text"`
	Tags    []Tag   `json:"tags,omitempty"`
	Body    []*Stmt `json:"body"`
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
