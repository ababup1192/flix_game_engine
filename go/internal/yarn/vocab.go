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
//	* は object の値を全部たどり、たどった鍵を名前の頭に「鍵.」で付ける（cast.*.faces[] → toma.smile）。
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
//	Specs     引数の表を持つコマンド（v2 の commands で params を書いた物。無いコマンドは名前だけ見る）
type Vocab struct {
	Speakers []string
	Nodes    []string
	NodeRefs []string
	Vars     map[string]string
	Tags     map[string][]string
	Commands []string
	Specs    map[string]*CommandSpec
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
	commands, specs, err := commandsOf(raw.Commands)
	if err != nil {
		return nil, nil, err
	}
	v.Commands = commands
	if head.Version > vocabVersionTwo {
		return nil, nil, fmt.Errorf("語彙の版 %d を知らない（読めるのは 1 と 2。bin/fge を新しくする）", head.Version)
	}
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
	r := &docReader{dir: filepath.Dir(vocabPath), root: root, cache: map[string]any{}, texts: map[string]string{}, failed: map[string]error{},
		users: docUsersOf(data, vocabPath)}
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
		fs, more, skip, err := r.collect(f.key, f.raw)
		if err != nil {
			return nil, nil, err
		}
		notes = append(notes, more...)
		if skip {
			v.skip[f.key] = true
			continue
		}
		f.into(fs)
	}
	more, err := r.resolveSpecs(specs)
	if err != nil {
		return nil, nil, err
	}
	v.Specs = specs
	return v, append(notes, more...), nil
}

// resolveSpecs は引数の表の ref と orNames の Doc から名前を集める（読めない Doc の欄は照らさない）。
func (r *docReader) resolveSpecs(specs map[string]*CommandSpec) ([]string, error) {
	var notes []string
	names := make([]string, 0, len(specs))
	for name := range specs {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		for i := range specs[name].Params {
			p := &specs[name].Params[i]
			for _, f := range []struct {
				raw  json.RawMessage
				set  *map[string]bool
				list *[]string
			}{{p.Ref, &p.refNames, &p.refList}, {p.OrNames, &p.orNameSet, &p.orNameList}} {
				if len(f.raw) == 0 {
					continue
				}
				fs, more, skip, err := r.collect(fmt.Sprintf("commands の %s の %s", name, p.Name), f.raw)
				if err != nil {
					return nil, err
				}
				notes = append(notes, more...)
				if skip {
					continue
				}
				*f.set = map[string]bool{}
				for _, x := range fs {
					if !(*f.set)[x.name] {
						(*f.set)[x.name] = true
						*f.list = append(*f.list, x.name)
					}
				}
			}
		}
	}
	return notes, nil
}

// commandsOf は commands の名前（配列か、名前を鍵にした object）と、params を書いたコマンドの引数の表。
func commandsOf(raw json.RawMessage) ([]string, map[string]*CommandSpec, error) {
	specs := map[string]*CommandSpec{}
	if len(raw) == 0 {
		return nil, specs, nil
	}
	var list []string
	if json.Unmarshal(raw, &list) == nil {
		return list, specs, nil
	}
	var table map[string]json.RawMessage
	if err := json.Unmarshal(raw, &table); err != nil {
		return nil, nil, fmt.Errorf("語彙の commands は名前の配列か、名前を鍵にした object で書く: %v", err)
	}
	names := make([]string, 0, len(table))
	for k, body := range table {
		names = append(names, k)
		var head struct {
			Params json.RawMessage `json:"params"`
		}
		if err := json.Unmarshal(body, &head); err != nil {
			return nil, nil, fmt.Errorf("語彙の commands の %s は object で書く: %v", k, err)
		}
		if len(head.Params) == 0 {
			continue
		}
		var spec CommandSpec
		if err := json.Unmarshal(body, &spec); err != nil {
			return nil, nil, fmt.Errorf("語彙の commands の %s の引数の表を読めない: %v", k, err)
		}
		if err := spec.validate(k); err != nil {
			return nil, nil, err
		}
		specs[k] = &spec
	}
	sort.Strings(names)
	return names, specs, nil
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
	failed    map[string]error
	// users は Doc（絶対パス）→ その Doc を from に書いた欄の名前（読めない時の知らせに並べる）。
	users map[string][]string
}

type fromEntry struct {
	Doc  string  `json:"doc"`
	Keys *string `json:"keys"`
	Path *string `json:"path"`
}

// collect は欄 1 つの名前を集める。Doc を読めない時と from が名前を 1 つも拾わない時は notes に 1 行ずつ
// （欄の検査を飛ばす合図。読めない Doc は最初の欄でだけ言う）、欄の書き方そのものの誤りは err（語彙が壊れているのと同じく止める）。
func (r *docReader) collect(key string, raw json.RawMessage) ([]found, []string, bool, error) {
	var direct []string
	if json.Unmarshal(raw, &direct) == nil {
		out := make([]found, 0, len(direct))
		for _, n := range direct {
			out = append(out, found{name: n, label: n})
		}
		return out, nil, false, nil
	}
	var section struct {
		From []fromEntry `json:"from"`
	}
	if err := json.Unmarshal(raw, &section); err != nil || len(section.From) == 0 {
		return nil, nil, false, fmt.Errorf("語彙の %s は名前の配列か {\"from\": [{\"doc\": …, \"keys\" か \"path\": …}]} で書く", key)
	}
	var out []found
	var notes []string
	skip := false
	for _, e := range section.From {
		if e.Doc == "" || (e.Keys == nil) == (e.Path == nil) {
			return nil, nil, false, fmt.Errorf("語彙の %s の from は doc と、keys か path のどちらか 1 つを書く", key)
		}
		docPath := filepath.Join(r.dir, filepath.FromSlash(e.Doc))
		docRel := rel(r.root, docPath)
		doc, first, err := r.load(docPath)
		if err != nil {
			if first {
				notes = append(notes, fmt.Sprintf("注意: 語彙の from の Doc %s を読めない（%v）— その Doc を見る欄（%s）の検査を飛ばす", docRel, err, r.usersText(docPath, key)))
			}
			skip = true
			continue
		}
		var got []found
		var where string
		var reached bool
		if e.Path != nil {
			where = *e.Path
			got, reached = r.stringsAt(doc, where, docPath, docRel)
		} else {
			where = *e.Keys
			got, reached = r.keysAt(doc, where, docPath, docRel)
		}
		if len(got) == 0 && (reached || starPrefixReached(doc, where)) {
			continue
		}
		if len(got) == 0 {
			notes = append(notes, fmt.Sprintf("注意: 語彙の %s の from（%s の %s）が名前を 1 つも拾わない — %s の検査を飛ばす（綴りを確かめる）", key, docRel, where, key))
			skip = true
			continue
		}
		out = append(out, got...)
	}
	return out, notes, skip, nil
}

// starPrefixReached は path に * があり、最初の * より前の段が最後までたどれるか。* の後の欄は項目ごとに書かない事がある
// （novel.cast.json の markers）ので、* より前に届いていれば、名前を 1 つも拾わなくても「空」と読み、検査は飛ばさない。
func starPrefixReached(doc any, path string) bool {
	head, _, found := strings.Cut(path, "*")
	if !found {
		return false
	}
	head = strings.TrimSuffix(head, ".")
	if head == "" {
		return true
	}
	_, reached := selectPathReached(doc, head)
	return reached
}

// stringsAt は path の先の文字列の全部（* でたどった鍵を名前の頭に付ける）。reached は path が最後までたどれたか
// （空の配列で尽きた時も true。名前を 1 つも拾わなかった時に、綴り違いか、行き先はあるが空なのかを分ける）。
func (r *docReader) stringsAt(doc any, path, docPath, docRel string) ([]found, bool) {
	var out []found
	values, reached := selectPathReached(doc, path)
	for _, x := range values {
		if s, ok := x.value.(string); ok && s != "" {
			out = append(out, found{name: x.prefix + s, label: s, doc: docRel, line: r.lineOf(docPath, s)})
		}
	}
	return out, reached
}

// keysAt は path の先の object の鍵の全部（値が文字列なら表示名・* でたどった鍵を名前の頭に付ける）。
// reached は path の先が全部 object だったか。
func (r *docReader) keysAt(doc any, path, docPath, docRel string) ([]found, bool) {
	var out []found
	values, reached := selectPathReached(doc, path)
	for _, x := range values {
		obj, ok := x.value.(map[string]any)
		if !ok {
			reached = false
			continue
		}
		names := make([]string, 0, len(obj))
		for k := range obj {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, k := range names {
			label, _ := obj[k].(string)
			out = append(out, found{name: x.prefix + k, label: label, doc: docRel, line: r.lineOf(docPath, k)})
		}
	}
	return out, reached
}

// usersText は Doc を from に書いた欄の名前を ・ で並べた字（集めていなければ key だけ）。
func (r *docReader) usersText(docPath, key string) string {
	users := r.users[filepath.Clean(docPath)]
	if len(users) == 0 {
		return key
	}
	return strings.Join(users, "・")
}

// load は Doc を読む（読めた物も読めなかった物も覚える）。first は読めない事をこの呼び出しで初めて知ったか。
func (r *docReader) load(path string) (any, bool, error) {
	if doc, ok := r.cache[path]; ok {
		return doc, false, nil
	}
	if err, ok := r.failed[path]; ok {
		return nil, false, err
	}
	data, err := os.ReadFile(path)
	if err == nil {
		var doc any
		if err = json.Unmarshal(data, &doc); err == nil {
			r.cache[path] = doc
			r.texts[path] = string(data)
			return doc, false, nil
		}
		err = fmt.Errorf("JSON が壊れている: %v", err)
	} else {
		err = fmt.Errorf("無い")
	}
	r.failed[path] = err
	return nil, true, err
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

// picked は path の先の値 1 つと、* でたどった鍵を . で並べた頭（* が無ければ ""）。
type picked struct {
	prefix string
	value  any
}

// selectPathReached は path（. 区切り・xs[] は配列の要素を全部・* は object の値を全部）の先にある値の全部（* でたどった鍵の頭つき）と、途中で鍵が無い・形が違う所に一度も当たらなかったか。
// * より後の段は、どれか 1 つが鍵を持てば足りる（cast.*.markers の markers を持たない役がいても綴り違いにしない）。
func selectPathReached(doc any, path string) ([]picked, bool) {
	cur := []picked{{value: doc}}
	reached := true
	afterStar := false
	for _, seg := range strings.Split(path, ".") {
		var next []picked
		misses := 0
		for _, x := range cur {
			got, ok := stepPath(x, seg)
			if !ok {
				misses++
				continue
			}
			next = append(next, got...)
		}
		if misses > 0 && (!afterStar || misses == len(cur)) {
			reached = false
		}
		afterStar = afterStar || seg == "*"
		cur = next
	}
	return cur, reached
}

// stepPath は値 1 つから段 seg を 1 つ進めた先（ok は鍵があり形が合ったか）。
func stepPath(x picked, seg string) ([]picked, bool) {
	obj, ok := x.value.(map[string]any)
	if !ok {
		return nil, false
	}
	if seg == "*" {
		keys := make([]string, 0, len(obj))
		for k := range obj {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		out := make([]picked, 0, len(keys))
		for _, k := range keys {
			out = append(out, picked{prefix: x.prefix + k + ".", value: obj[k]})
		}
		return out, true
	}
	field := strings.TrimSuffix(seg, "[]")
	val, ok := obj[field]
	if !ok {
		return nil, false
	}
	if !strings.HasSuffix(seg, "[]") {
		return []picked{{prefix: x.prefix, value: val}}, true
	}
	arr, ok := val.([]any)
	if !ok {
		return nil, false
	}
	out := make([]picked, 0, len(arr))
	for _, v := range arr {
		out = append(out, picked{prefix: x.prefix, value: v})
	}
	return out, true
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
	for doc := range docUsersOf(data, vocabPath) {
		out = append(out, doc)
	}
	sort.Strings(out)
	return out
}

// docUsersOf は v2 の語彙の from（欄の from と、commands の引数の ref・orNames の from）が指す Doc（絶対パス）→
// その Doc を見る欄の名前（speakers・commands の bg の who など）。
func docUsersOf(data []byte, vocabPath string) map[string][]string {
	users := map[string][]string{}
	var sections map[string]json.RawMessage
	if json.Unmarshal(data, &sections) != nil {
		return users
	}
	add := func(label string, raw json.RawMessage) {
		var section struct {
			From []fromEntry `json:"from"`
		}
		if len(raw) == 0 || json.Unmarshal(raw, &section) != nil {
			return
		}
		for _, e := range section.From {
			if e.Doc == "" {
				continue
			}
			doc := filepath.Clean(filepath.Join(filepath.Dir(vocabPath), filepath.FromSlash(e.Doc)))
			if !contains(users[doc], label) {
				users[doc] = append(users[doc], label)
			}
		}
	}
	keys := make([]string, 0, len(sections))
	for k := range sections {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		add(k, sections[k])
	}
	var commands map[string]struct {
		Params []struct {
			Name    string          `json:"name"`
			Ref     json.RawMessage `json:"ref"`
			OrNames json.RawMessage `json:"orNames"`
		} `json:"params"`
	}
	if json.Unmarshal(sections["commands"], &commands) == nil {
		names := make([]string, 0, len(commands))
		for name := range commands {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			for _, p := range commands[name].Params {
				add("commands の "+name+" の "+p.Name, p.Ref)
				add("commands の "+name+" の "+p.Name, p.OrNames)
			}
		}
	}
	return users
}
