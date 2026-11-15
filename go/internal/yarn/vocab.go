package yarn

// 語彙（vocab.json）を読む。
//
//	v1（version が無い）: 名前を配列で直に書く。{"speakers": [...], "nodes": [...], "tags": {...}, "commands": [...]}
//	v2: 名前の正が Doc にある欄は「どの Doc のどの鍵を見るか」（from）だけを書き、ここで Doc から名前を集める。
//	    {"version": 2,
//	     "speakers": {"from": [{"doc": "../novel.story.json", "keys": "names"}]},     鍵の名前を集める
//	     "vars":     {"from": [{"doc": "../novel.story.json", "keys": "vars"}]},      鍵 = $ を付けない変数の名前・値 = 表示名
//	     "nodes":    {"from": [{"doc": "../novel.story.json", "path": "opening"}]},   その場所の文字列を集める
//	     "nodeRefs": {"from": [{"doc": "../novel.shots.json", "path": "shots[].node"}]},
//	     "tags": {...}, "commands": {"bg": {...}, ...}}
//	doc は vocab.json のフォルダから数える。path と keys は . で区切り、xs[] は配列の要素を全部たどる。
//	v2 の欄に配列を直に書いてもよい（v1 と同じ読み方）。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Vocab はシナリオの外が持つ名前の一覧。
//
//	Speakers  話し手の id（話し手: 台詞 の左）
//	Nodes     コードが開くノード（.yarn に無ければ止める・届かないノードの知らせの起点）
//	NodeRefs  名前で指すだけのノード（.yarn に無ければ止める。起点には混ぜない）
//	Vars      変数の名前（$ 付き）→ 表示名。nil なら見ない（v1・Doc を読めない時）
//	Tags      タグのキー → 取れる値（空なら値を書かない #key）
//	Commands  コマンドの名前（エンジンが読むのは wait だけ）
type Vocab struct {
	Speakers []string
	Nodes    []string
	NodeRefs []string
	Vars     map[string]string
	Tags     map[string][]string
	Commands []string
	// skip は v2 の from を読めずに検査を飛ばす欄（"speakers"・"nodes"・"nodeRefs"）。
	skip map[string]bool
	// origin はノードの名前を集めた Doc の場所（ゲームのルートからのパスと行）。無いノードの知らせを Doc の行へ向ける。
	origin map[string]Problem
}

const vocabVersionTwo = 2

// ParseVocab は vocab.json を読む（v2 の from は vocabPath のフォルダから数え、知らせのパスは root から数える）。
// notes は読めなかった Doc の 1 行ずつ（その欄の検査だけを飛ばし、止めない）。
func ParseVocab(data []byte, vocabPath, root string) (*Vocab, []string, error) {
	var head struct {
		Version int `json:"version"`
	}
	if err := json.Unmarshal(data, &head); err != nil {
		return nil, nil, fmt.Errorf("語彙の JSON を読めない: %v", err)
	}
	var raw struct {
		Speakers json.RawMessage     `json:"speakers"`
		Vars     json.RawMessage     `json:"vars"`
		Nodes    json.RawMessage     `json:"nodes"`
		NodeRefs json.RawMessage     `json:"nodeRefs"`
		Tags     map[string][]string `json:"tags"`
		Commands json.RawMessage     `json:"commands"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, nil, fmt.Errorf("語彙の JSON を読めない: %v", err)
	}
	v := &Vocab{Tags: raw.Tags, skip: map[string]bool{}, origin: map[string]Problem{}}
	commands, err := commandNamesOf(raw.Commands)
	if err != nil {
		return nil, nil, err
	}
	v.Commands = commands
	if head.Version < vocabVersionTwo {
		for _, f := range []struct {
			raw json.RawMessage
			to  *[]string
		}{{raw.Speakers, &v.Speakers}, {raw.Nodes, &v.Nodes}} {
			if len(f.raw) > 0 {
				if err := json.Unmarshal(f.raw, f.to); err != nil {
					return nil, nil, fmt.Errorf("語彙の JSON を読めない: %v", err)
				}
			}
		}
		return v, nil, nil
	}
	r := &docReader{dir: filepath.Dir(vocabPath), root: root, cache: map[string]any{}}
	var notes []string
	for _, f := range []struct {
		key  string
		raw  json.RawMessage
		into func(found []found)
	}{
		{"speakers", raw.Speakers, func(fs []found) { v.Speakers = namesOfFound(fs) }},
		{"nodes", raw.Nodes, func(fs []found) { v.Nodes = namesOfFound(fs); v.noteOrigins(fs) }},
		{"nodeRefs", raw.NodeRefs, func(fs []found) { v.NodeRefs = namesOfFound(fs); v.noteOrigins(fs) }},
		{"vars", raw.Vars, func(fs []found) {
			v.Vars = map[string]string{}
			for _, x := range fs {
				v.Vars["$"+x.name] = x.label
			}
		}},
	} {
		if len(f.raw) == 0 {
			v.skip[f.key] = true
			continue
		}
		fs, note, err := r.collect(f.key, f.raw)
		if err != nil {
			return nil, nil, err
		}
		if note != "" {
			notes = append(notes, note)
			v.skip[f.key] = true
			continue
		}
		f.into(fs)
	}
	return v, notes, nil
}

// commandNamesOf は commands の名前（配列か、名前を鍵にした object）。
func commandNamesOf(raw json.RawMessage) ([]string, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	var list []string
	if json.Unmarshal(raw, &list) == nil {
		return list, nil
	}
	var table map[string]json.RawMessage
	if err := json.Unmarshal(raw, &table); err != nil {
		return nil, fmt.Errorf("語彙の commands は名前の配列か、名前を鍵にした object で書く: %v", err)
	}
	names := make([]string, 0, len(table))
	for k := range table {
		names = append(names, k)
	}
	sort.Strings(names)
	return names, nil
}

// found は Doc から集めた名前 1 つ（label は keys の時の値の字・doc と line は知らせの場所）。
type found struct {
	name, label, doc string
	line             int
}

func namesOfFound(fs []found) []string {
	out := make([]string, 0, len(fs))
	for _, f := range fs {
		out = append(out, f.name)
	}
	return out
}

func (v *Vocab) noteOrigins(fs []found) {
	for _, f := range fs {
		if _, ok := v.origin[f.name]; !ok {
			v.origin[f.name] = Problem{File: f.doc, Line: f.line}
		}
	}
}

type docReader struct {
	dir, root string
	cache     map[string]any
	texts     map[string]string
}

type fromEntry struct {
	Doc  string  `json:"doc"`
	Keys *string `json:"keys"`
	Path *string `json:"path"`
}

// collect は欄 1 つの名前を集める。Doc を読めない時は note に 1 行（欄の検査を飛ばす合図）、
// 欄の書き方そのものの誤りは err（語彙が壊れているのと同じく止める）。
func (r *docReader) collect(key string, raw json.RawMessage) ([]found, string, error) {
	var direct []string
	if json.Unmarshal(raw, &direct) == nil {
		out := make([]found, 0, len(direct))
		for _, n := range direct {
			out = append(out, found{name: n, label: n})
		}
		return out, "", nil
	}
	var section struct {
		From []fromEntry `json:"from"`
	}
	if err := json.Unmarshal(raw, &section); err != nil || len(section.From) == 0 {
		return nil, "", fmt.Errorf("語彙の %s は名前の配列か {\"from\": [{\"doc\": …, \"keys\" か \"path\": …}]} で書く", key)
	}
	var out []found
	for _, e := range section.From {
		if e.Doc == "" || (e.Keys == nil) == (e.Path == nil) {
			return nil, "", fmt.Errorf("語彙の %s の from は doc と、keys か path のどちらか 1 つを書く", key)
		}
		docPath := filepath.Join(r.dir, filepath.FromSlash(e.Doc))
		doc, err := r.load(docPath)
		if err != nil {
			return nil, fmt.Sprintf("注意: 語彙の %s の Doc %s を読めない（%v）— %s の検査を飛ばす", key, rel(r.root, docPath), err, key), nil
		}
		docRel := rel(r.root, docPath)
		if e.Path != nil {
			for _, x := range selectPath(doc, *e.Path) {
				if s, ok := x.(string); ok && s != "" {
					out = append(out, found{name: s, label: s, doc: docRel, line: r.lineOf(docPath, s)})
				}
			}
			continue
		}
		for _, x := range selectPath(doc, *e.Keys) {
			obj, ok := x.(map[string]any)
			if !ok {
				continue
			}
			names := make([]string, 0, len(obj))
			for k := range obj {
				names = append(names, k)
			}
			sort.Strings(names)
			for _, k := range names {
				label, _ := obj[k].(string)
				out = append(out, found{name: k, label: label, doc: docRel, line: r.lineOf(docPath, k)})
			}
		}
	}
	return out, "", nil
}

func (r *docReader) load(path string) (any, error) {
	if doc, ok := r.cache[path]; ok {
		return doc, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("無い")
	}
	var doc any
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("JSON が壊れている: %v", err)
	}
	r.cache[path] = doc
	if r.texts == nil {
		r.texts = map[string]string{}
	}
	r.texts[path] = string(data)
	return doc, nil
}

// lineOf は Doc の中で "name" と書いた最初の行（見つからなければ 1）。
func (r *docReader) lineOf(path, name string) int {
	quoted, _ := json.Marshal(name)
	for i, line := range strings.Split(r.texts[path], "\n") {
		if strings.Contains(line, string(quoted)) {
			return i + 1
		}
	}
	return 1
}

// selectPath は path（. 区切り・xs[] は配列の要素を全部）の先にある値の全部。
func selectPath(doc any, path string) []any {
	cur := []any{doc}
	for _, seg := range strings.Split(path, ".") {
		spread := strings.HasSuffix(seg, "[]")
		field := strings.TrimSuffix(seg, "[]")
		var next []any
		for _, x := range cur {
			obj, ok := x.(map[string]any)
			if !ok {
				continue
			}
			val, ok := obj[field]
			if !ok {
				continue
			}
			if !spread {
				next = append(next, val)
				continue
			}
			if arr, ok := val.([]any); ok {
				next = append(next, arr...)
			}
		}
		cur = next
	}
	return cur
}

// DocsOf は vocab.json（v2）の from が指す Doc の全部（絶対パス）。v1 と読めない語彙は空。
func DocsOf(data []byte, vocabPath string) []string {
	var head struct {
		Version int `json:"version"`
	}
	if json.Unmarshal(data, &head) != nil || head.Version < vocabVersionTwo {
		return nil
	}
	var sections map[string]json.RawMessage
	if json.Unmarshal(data, &sections) != nil {
		return nil
	}
	var out []string
	for _, raw := range sections {
		var section struct {
			From []fromEntry `json:"from"`
		}
		if json.Unmarshal(raw, &section) != nil {
			continue
		}
		for _, e := range section.From {
			if e.Doc != "" {
				out = append(out, filepath.Clean(filepath.Join(filepath.Dir(vocabPath), filepath.FromSlash(e.Doc))))
			}
		}
	}
	return out
}
