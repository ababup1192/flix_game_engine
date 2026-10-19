package yarn

// フォルダ 1 つ分の検査: ノード名の重なり・jump の行き先・変数の宣言と式の型と、語彙（vocab.json。正はゲームのコードの enum）との突き合わせ。
// 語彙はゲームの Talk.vocab（中身は Yarn.vocabJson）が書く。形は flow の e2e/vocab.json と同じ決め方（キーの順は固定・配列）。

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"

	"github.com/ababup1192/flix_game_engine/go/internal/suggest"
)

// Vocab はゲームのコードが持つ名前の一覧。
//
//	speakers  話し手の id（話し手: 台詞 の左）
//	nodes     コードが開くノード（.yarn に無ければ止める）
//	tags      タグのキー → 取れる値（空なら値を書かない #key）
//	commands  コマンドの名前（エンジンが読むのは wait だけ）
type Vocab struct {
	Speakers []string            `json:"speakers"`
	Nodes    []string            `json:"nodes"`
	Tags     map[string][]string `json:"tags"`
	Commands []string            `json:"commands"`
}

// ParseVocab は vocab.json を読む。
func ParseVocab(data []byte) (*Vocab, error) {
	var v Vocab
	if err := json.Unmarshal(data, &v); err != nil {
		return nil, fmt.Errorf("語彙の JSON を読めない: %v", err)
	}
	return &v, nil
}

// reservedTags は公式で実行の意味を持つタグ（行の同一性・最後の行のマーカー）。語彙に書いても読まない。
// 行の ID も読まない —— シナリオの行はファイル:行で指す（ID を手で振ると重なりと付け忘れの検査が要る）。
var reservedTags = map[string]string{
	"shadow":   "#shadow（別の行の写し）",
	"lastline": "#lastline（選択肢の前の行の印）",
	"line":     "#line:（行の ID）",
}

// waitCommand はエンジンの実行器が自分で待つコマンド（語彙に無くても読む）。
const waitCommand = "wait"

// CheckProgram はノードどうしの決まりと語彙を見る（vocab が nil なら語彙の検査をしない）。
func CheckProgram(prog *Program, vocab *Vocab, vocabPath string) []Problem {
	var out []Problem
	byTitle := map[string]*Node{}
	var titles []string
	for _, n := range prog.Nodes {
		if n.Title == "" {
			continue
		}
		if first, dup := byTitle[n.Title]; dup {
			out = append(out, Problem{File: n.File, Line: n.Line,
				Msg: fmt.Sprintf("ノード名 %s が 2 つある（先の物は %s:%d）", n.Title, first.File, first.Line)})
			continue
		}
		byTitle[n.Title] = n
		titles = append(titles, n.Title)
	}
	jumped := map[string]bool{}
	for _, n := range prog.Nodes {
		walk(n.Body, func(s *Stmt) {
			if s.Kind != "jump" {
				return
			}
			jumped[s.Node] = true
			if _, ok := byTitle[s.Node]; !ok {
				out = append(out, Problem{File: n.File, Line: s.Line,
					Msg: fmt.Sprintf("<<jump>> の行き先 %s が無い%s", s.Node, suggest.Hint(s.Node, titles))})
			}
		})
	}
	out = append(out, checkTypes(prog, byTitle, titles)...)
	for _, n := range prog.Nodes {
		file := n.File
		walk(n.Body, func(s *Stmt) {
			refuseReserved := func(line int, tags []Tag) {
				for _, t := range tags {
					if what, ok := reservedTags[t.Key]; ok {
						out = append(out, Problem{File: file, Line: line, Unsupported: true,
							Msg: fmt.Sprintf("読まない: %s — 代わりに: 行はファイル:行で指し、出し分けはゲームのコードで決める", what)})
					}
				}
			}
			refuseReserved(s.Line, s.Tags)
			for _, o := range s.Options {
				refuseReserved(o.Line, o.Tags)
			}
			if s.Kind == "command" && s.Name == waitCommand {
				if len(s.Args) != 1 {
					out = append(out, Problem{File: file, Line: s.Line, Msg: "<<wait>> は秒を 1 つ書く（<<wait 0.5>>）"})
				} else if sec, err := strconv.ParseFloat(s.Args[0], 64); err != nil || sec < 0 {
					out = append(out, Problem{File: file, Line: s.Line, Msg: fmt.Sprintf("<<wait>> の秒 %q が 0 以上の数でない", s.Args[0])})
				}
			}
		})
	}
	if vocab == nil {
		return out
	}
	tagKeys := make([]string, 0, len(vocab.Tags))
	for k := range vocab.Tags {
		tagKeys = append(tagKeys, k)
	}
	sort.Strings(tagKeys)
	commands := append([]string{waitCommand}, vocab.Commands...)
	speakers := setOf(vocab.Speakers)
	for _, n := range prog.Nodes {
		file := n.File
		checkSpeaker := func(line int, speaker string) {
			if speaker != "" && !speakers[speaker] {
				out = append(out, Problem{File: file, Line: line,
					Msg: fmt.Sprintf("知らない話し手 %s%s（字の : は \\: と書く）", speaker, suggest.Hint(speaker, vocab.Speakers))})
			}
		}
		checkTags := func(line int, tags []Tag) {
			for _, t := range tags {
				if _, ok := reservedTags[t.Key]; ok {
					continue
				}
				values, ok := vocab.Tags[t.Key]
				switch {
				case !ok:
					out = append(out, Problem{File: file, Line: line,
						Msg: fmt.Sprintf("知らないタグ #%s%s", t.Key, suggest.Hint(t.Key, tagKeys))})
				case len(values) == 0 && t.Value != "":
					out = append(out, Problem{File: file, Line: line,
						Msg: fmt.Sprintf("タグ #%s は値を取らない（#%s と書く）", t.Key, t.Key)})
				case len(values) > 0 && !setOf(values)[t.Value]:
					out = append(out, Problem{File: file, Line: line,
						Msg: fmt.Sprintf("タグ #%s の値 %q を知らない%s", t.Key, t.Value, suggest.Hint(t.Value, values))})
				}
			}
		}
		walk(n.Body, func(s *Stmt) {
			switch s.Kind {
			case "line":
				checkSpeaker(s.Line, s.Speaker)
			case "options":
				for _, o := range s.Options {
					checkSpeaker(o.Line, o.Speaker)
					checkTags(o.Line, o.Tags)
				}
			case "command":
				if !setOf(commands)[s.Name] {
					out = append(out, Problem{File: file, Line: s.Line,
						Msg: fmt.Sprintf("知らないコマンド <<%s>>%s（演出の順番はゲームのコードで決める）", s.Name, suggest.Hint(s.Name, commands))})
				}
			}
			checkTags(s.Line, s.Tags)
		})
	}
	for _, name := range vocab.Nodes {
		if _, ok := byTitle[name]; !ok {
			out = append(out, Problem{File: vocabPath, Line: 1,
				Msg: fmt.Sprintf("コードが開くノード %s が .yarn に無い%s", name, suggest.Hint(name, titles))})
		}
	}
	return out
}

// Unreached はコードも jump も開かないノード（止めずに知らせるだけ）。
func Unreached(prog *Program, vocab *Vocab) []Problem {
	if vocab == nil {
		return nil
	}
	opened := setOf(vocab.Nodes)
	for _, n := range prog.Nodes {
		walk(n.Body, func(s *Stmt) {
			if s.Kind == "jump" {
				opened[s.Node] = true
			}
		})
	}
	var out []Problem
	for _, n := range prog.Nodes {
		if n.Title != "" && !opened[n.Title] {
			out = append(out, Problem{File: n.File, Line: n.Line,
				Msg: fmt.Sprintf("ノード %s はコードからも <<jump>> からも開かれない", n.Title)})
		}
	}
	return out
}

// walk は文を選択肢と <<if>> の中身まで順に辿る。
func walk(stmts []*Stmt, f func(*Stmt)) {
	for _, s := range stmts {
		f(s)
		for _, o := range s.Options {
			walk(o.Body, f)
		}
		for _, c := range s.Clauses {
			walk(c.Body, f)
		}
	}
}

// checkTypes は <<declare>> の重なりと、式の変数・型・visited のノードを見る。
func checkTypes(prog *Program, byTitle map[string]*Node, titles []string) []Problem {
	var out []Problem
	env := &typeEnv{vars: map[string]*Variable{}, nodes: map[string]bool{}, titles: titles}
	for title := range byTitle {
		env.nodes[title] = true
	}
	for _, v := range prog.Variables {
		if first, dup := env.vars[v.Name]; dup {
			out = append(out, Problem{File: v.File, Line: v.Line,
				Msg: fmt.Sprintf("変数 %s の <<declare>> が 2 つある（先の物は %s:%d）", v.Name, first.File, first.Line)})
			continue
		}
		env.vars[v.Name] = v
		env.names = append(env.names, v.Name)
	}
	for _, n := range prog.Nodes {
		file := n.File
		expect := func(line int, x *Expr, want ValueType, what string) {
			if x == nil {
				return
			}
			got, err := env.typeOf(x)
			switch {
			case err != nil:
				out = append(out, Problem{File: file, Line: line, Msg: fmt.Sprintf("%s: %v", what, err)})
			case want != "" && got != want:
				out = append(out, Problem{File: file, Line: line, Msg: fmt.Sprintf("%s は %s の式を書く（%s になっている）", what, want, got)})
			}
		}
		parts := func(line int, ps []*Part) {
			for _, part := range ps {
				expect(line, part.Expr, "", "{} の式")
			}
		}
		walk(n.Body, func(s *Stmt) {
			parts(s.Line, s.Parts)
			for _, o := range s.Options {
				parts(o.Line, o.Parts)
				expect(o.Line, o.Condition, TypeBool, "選択肢の <<if>>")
			}
			for i, c := range s.Clauses {
				expect(c.Line, c.Condition, TypeBool, map[bool]string{true: "<<if>>", false: "<<elseif>>"}[i == 0])
			}
			if s.Kind == "set" {
				v, ok := env.vars[s.Name]
				if !ok {
					out = append(out, Problem{File: file, Line: s.Line,
						Msg: fmt.Sprintf("宣言していない変数 %s%s（<<declare %s = 初めの値>> を書く）", s.Name, nearHint(s.Name, env.names), s.Name)})
					return
				}
				expect(s.Line, s.Expr, v.Value.Type, fmt.Sprintf("<<set %s>>（%s の変数）", s.Name, v.Value.Type))
			}
		})
	}
	return out
}

func setOf(xs []string) map[string]bool {
	m := make(map[string]bool, len(xs))
	for _, x := range xs {
		m[x] = true
	}
	return m
}
