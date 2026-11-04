// Package fontbake は、ブラウザへ同梱するフォントアトラスのための字を集め、生成したアトラスに漏れが無いかを見る。
//
// 集める所: assets の台詞（*.yarn）・Doc（*.json の文字列の値・*.schema.json と *.sprite.json は除く）・*.txt / *.csv と、
// src の .flix の文字列リテラルと字のリテラル。字ごとに最初の出所（ファイル:行）を覚える。
package fontbake

import (
	"bufio"
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Origin は字が書いてあった所。File はゲームの根からの / 区切り。
// Dev は開発の道具の所（描き出し・つり合いのシミュレーション・道具向けの説明の欄）で、遊ぶ画面には出ない見込みの所。
type Origin struct {
	File string
	Line int
	Dev  bool
}

func (o Origin) String() string { return o.File + ":" + strconv.Itoa(o.Line) }

// maxOrigins は 1 字ごとに覚える出所の数（漏れを直す人が見る分だけ）。
const maxOrigins = 3

// Charset は集めた字と、その出所。
type Charset struct {
	// Origins は字ごとの出所。遊ぶ画面の出所（Dev でない物）を先に覚える。
	Origins map[rune][]Origin
	// Count は字ごとの出現の数（覚えた出所より多い時に「ほか N か所」と出す）。
	Count map[rune]int
	// Game は遊ぶ画面の出所が 1 つでもある字。開発の道具の所にしか無い字は、漏れても止めずに知らせるだけにする。
	Game map[rune]bool
}

func newCharset() *Charset {
	return &Charset{Origins: map[rune][]Origin{}, Count: map[rune]int{}, Game: map[rune]bool{}}
}

func (c *Charset) add(r rune, o Origin) {
	if r < 0x20 || r == 0x7F || r == 0xFEFF || r == utf8.RuneError || isZeroWidth(r) {
		return
	}
	if isPrivateUse(r) {
		// 私用領域の字は、ゲームが字の並びの中で印に使う（描く前に別の物へ置き換える）ことが多い。漏れても止めない。
		o.Dev = true
	}
	c.Count[r]++
	kept := c.Origins[r]
	if !o.Dev && !c.Game[r] {
		// 道具の所だけを覚えていた字に、初めて遊ぶ画面の出所が来た: そちらを頭へ。
		kept = append([]Origin{o}, kept...)
		if len(kept) > maxOrigins {
			kept = kept[:maxOrigins]
		}
		c.Game[r] = true
	} else if len(kept) < maxOrigins {
		kept = append(kept, o)
	}
	c.Origins[r] = kept
}

// isZeroWidth は幅を持たず字形も要らない字（異体字の選び・ゼロ幅の繋ぎ）。絵文字の後ろに付いてくる。
func isZeroWidth(r rune) bool {
	return (r >= 0xFE00 && r <= 0xFE0F) || r == 0x200B || r == 0x200C || r == 0x200D
}

func isPrivateUse(r rune) bool {
	return (r >= 0xE000 && r <= 0xF8FF) || r >= 0xF0000
}

func (c *Charset) addString(s string, o Origin) {
	for _, r := range s {
		c.add(r, o)
	}
}

// Runes は集めた字を小さい順に返す。
func (c *Charset) Runes() []rune {
	out := make([]rune, 0, len(c.Origins))
	for r := range c.Origins {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// WithASCII は集めた字に ASCII の印字できる字（0x20〜0x7E）を足した字の並び（生成する字の集合のファイルの中身）。
// 得点や残り時間のように、文字列に書かれず実行中に組み立てて出す字があるため（デスクトップの used と同じ）。
func (c *Charset) WithASCII() string {
	set := map[rune]bool{}
	for r := rune(0x20); r <= 0x7E; r++ {
		set[r] = true
	}
	for r := range c.Origins {
		set[r] = true
	}
	rs := make([]rune, 0, len(set))
	for r := range set {
		rs = append(rs, r)
	}
	sort.Slice(rs, func(i, j int) bool { return rs[i] < rs[j] })
	return string(rs)
}

// Notice は前もって集められない字を作る所（実行中に字を組み立てる行）。止めずに知らせる。
type Notice struct {
	At   Origin
	What string
}

// runtimeCharRe は .flix で、書いてない字を実行中に作る呼び出し。ここが作る字は集めた字の外にありうる。
// WhyNot: 文字の入力欄（人が打つ字）の口は engine にまだ無い — 入ったらその口の名前もここへ足す。
var runtimeCharRe = regexp.MustCompile(`\b(Int32\.truncateToChar|Char\.toBmpChar|Char\.highSurrogate|Char\.lowSurrogate|Character\.toChars|String\.fromCodePoint|Character\.toString\(|new String\()`)

// consoleLineRe は画面でなく端末へ出す行。ここの文字列リテラルは集めない（ログの字まで漏れと数えないため）。
var consoleLineRe = regexp.MustCompile(`\b(println|eprintln|print|Log\.[a-zA-Z]+|bug!|unreachable!|debug|Assert\.[a-zA-Z]+)\s*\(`)

// commentKeys は Doc で人へのメモに使う欄。値を画面に出さないので集めない。
var commentKeys = map[string]bool{"note": true, "notes": true, "doc": true, "description": true, "comment": true}

func isCommentKey(k string) bool {
	return commentKeys[k] || strings.HasPrefix(k, "//") || strings.HasPrefix(k, "_") || strings.HasPrefix(k, "$")
}

// DefaultDevDirs は開発の道具を置く慣わしの所（描き出しの入口・つり合いのシミュレーション）。
// ここの字も生成するが、漏れても止めない（ログや報告の Markdown の字で書き出しが止まらないように）。
var DefaultDevDirs = []string{"src/render", "src/sim"}

// docFieldRe は .flix で道具向けの説明を書く欄（`doc = "..."`）。画面に出さない。
var docFieldRe = regexp.MustCompile(`\bdoc\s*=\s*"`)

func isDevPath(rel string, devDirs []string) bool {
	for _, d := range devDirs {
		d = strings.TrimSuffix(filepath.ToSlash(d), "/")
		if rel == d || strings.HasPrefix(rel, d+"/") {
			return true
		}
	}
	return false
}

// Collect はゲームの根 root から字を集める。devDirs の下（根からの / 区切り）の出所は Dev になる。
func Collect(root string, devDirs []string) (*Charset, []Notice, error) {
	cs := newCharset()
	var notices []Notice
	assets := filepath.Join(root, "assets")
	if err := walkFiles(assets, func(path string) error {
		rel := relSlash(root, path)
		dev := isDevPath(rel, devDirs)
		name := filepath.Base(path)
		switch {
		case strings.HasSuffix(name, ".yarn"):
			return readLines(path, func(n int, line string) { collectYarnLine(cs, line, Origin{rel, n, dev}) })
		case strings.HasSuffix(name, ".schema.json"), strings.HasSuffix(name, ".sprite.json"):
			// スキーマの説明とドット絵の見出し・色の記号は画面に字として出ない（拾うと絵文字や私用領域の字まで漏れと数える）。
			return nil
		case strings.HasSuffix(name, ".json"):
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			collectJSON(cs, data, rel, dev)
			return nil
		case strings.HasSuffix(name, ".txt"), strings.HasSuffix(name, ".csv"):
			return readLines(path, func(n int, line string) { cs.addString(line, Origin{rel, n, dev}) })
		}
		return nil
	}); err != nil {
		return nil, nil, err
	}
	if err := walkFiles(filepath.Join(root, "src"), func(path string) error {
		if !strings.HasSuffix(path, ".flix") {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel := relSlash(root, path)
		notices = append(notices, collectFlix(cs, data, rel, isDevPath(rel, devDirs))...)
		return nil
	}); err != nil {
		return nil, nil, err
	}
	return cs, notices, nil
}

func walkFiles(dir string, fn func(string) error) error {
	if _, err := os.Stat(dir); err != nil {
		return nil
	}
	return filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path != dir && strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		return fn(path)
	})
}

func relSlash(root, path string) string {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return filepath.ToSlash(path)
	}
	return filepath.ToSlash(rel)
}

func readLines(path string, fn func(int, string)) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1024*1024), 16*1024*1024)
	n := 0
	for sc.Scan() {
		n++
		fn(n, sc.Text())
	}
	return sc.Err()
}

// collectYarnLine は台詞の 1 行。注釈の行（//）と、ノードの見出し・区切りは読まない。
func collectYarnLine(cs *Charset, line string, o Origin) {
	t := strings.TrimSpace(line)
	if t == "" || strings.HasPrefix(t, "//") || t == "---" || t == "===" {
		return
	}
	for _, head := range []string{"title:", "tags:", "position:", "colorID:"} {
		if strings.HasPrefix(t, head) {
			return
		}
	}
	cs.addString(t, o)
}

// collectJSON は Doc の文字列の値を集める（欄の名前は画面に出ないので集めない）。
// 壊れた JSON でも読めた所までは集める — 壊れていれば Doc の検査が先に止める。
func collectJSON(cs *Charset, data []byte, rel string, dev bool) {
	type frame struct {
		object bool
		key    string
		skip   bool
	}
	stack := []frame{{skip: false}}
	line := 1
	for i := 0; i < len(data); i++ {
		c := data[i]
		switch c {
		case '\n':
			line++
		case '{', '[':
			top := stack[len(stack)-1]
			skip := top.skip || (top.object && isCommentKey(top.key))
			stack = append(stack, frame{object: c == '{', key: top.key, skip: skip})
			if c == '{' {
				stack[len(stack)-1].key = ""
			}
		case '}', ']':
			if len(stack) > 1 {
				stack = stack[:len(stack)-1]
			}
		case '"':
			startLine := line
			s, next, lines := readJSONString(data, i+1)
			line += lines
			i = next
			j := i + 1
			for j < len(data) && (data[j] == ' ' || data[j] == '\t' || data[j] == '\r' || data[j] == '\n') {
				j++
			}
			top := &stack[len(stack)-1]
			if top.object && j < len(data) && data[j] == ':' {
				top.key = s
				continue
			}
			if top.skip || (top.object && isCommentKey(top.key)) {
				continue
			}
			// 根の title はエディタの目次に出す名前（docs/doc-conventions.md）で、ゲームの画面には出さない。
			if top.object && len(stack) == 2 && top.key == "title" {
				continue
			}
			cs.addString(s, Origin{rel, startLine, dev})
		}
	}
}

// readJSONString は開きの " の次から読み、中身・閉じの " の位置・中で越えた改行の数を返す。
func readJSONString(data []byte, from int) (string, int, int) {
	var b strings.Builder
	lines := 0
	i := from
	for i < len(data) {
		c := data[i]
		if c == '"' {
			return b.String(), i, lines
		}
		if c == '\n' {
			lines++
		}
		if c == '\\' && i+1 < len(data) {
			e := data[i+1]
			switch e {
			case 'n', 't', 'r', 'b', 'f':
				i += 2
				continue
			case 'u':
				if r, used := decodeJSONUnicode(data, i); used > 0 {
					b.WriteRune(r)
					i += used
					continue
				}
			}
			b.WriteByte(e)
			i += 2
			continue
		}
		b.WriteByte(c)
		i++
	}
	return b.String(), i, lines
}

// decodeJSONUnicode は data[i:] の \uXXXX（サロゲートの対なら 2 つ）を読み、字と使った byte 数を返す。
func decodeJSONUnicode(data []byte, i int) (rune, int) {
	hex := func(at int) (rune, bool) {
		if at+6 > len(data) || data[at] != '\\' || data[at+1] != 'u' {
			return 0, false
		}
		v, err := strconv.ParseUint(string(data[at+2:at+6]), 16, 32)
		return rune(v), err == nil
	}
	hi, ok := hex(i)
	if !ok {
		return 0, 0
	}
	if hi >= 0xD800 && hi < 0xDC00 {
		if lo, ok := hex(i + 6); ok && lo >= 0xDC00 && lo < 0xE000 {
			return 0x10000 + (hi-0xD800)<<10 + (lo - 0xDC00), 12
		}
	}
	return hi, 6
}

// collectFlix は .flix の文字列リテラル（${...} の中の入れ子も）と字のリテラルを集め、実行中に字を作る行を知らせる。
// 注釈（// と /* */）は読まない。端末へ出す行（println・Log など）のリテラルも集めない。`doc = "..."` の行の字は Dev。
func collectFlix(cs *Charset, data []byte, rel string, dev bool) []Notice {
	var notices []Notice
	lines := bytes.Split(data, []byte("\n"))
	for n, l := range lines {
		code := string(l)
		if t := strings.TrimSpace(code); strings.HasPrefix(t, "//") {
			continue
		}
		if m := runtimeCharRe.FindString(code); m != "" {
			notices = append(notices, Notice{At: Origin{rel, n + 1, dev}, What: strings.TrimSpace(code)})
		}
	}
	console := map[int]bool{}
	docLine := map[int]bool{}
	for n, l := range lines {
		if consoleLineRe.Match(l) {
			console[n+1] = true
		}
		if docFieldRe.Match(l) {
			docLine[n+1] = true
		}
	}
	sc := flixScanner{src: []rune(string(data)), line: 1}
	sc.emit = func(r rune, line int) {
		if !console[line] {
			cs.add(r, Origin{rel, line, dev || docLine[line]})
		}
	}
	sc.code(false)
	return notices
}

type flixScanner struct {
	src  []rune
	i    int
	line int
	emit func(rune, int)
}

func (s *flixScanner) peek(k int) rune {
	if s.i+k < len(s.src) {
		return s.src[s.i+k]
	}
	return 0
}

// code はコードの所を読む。inInterp なら対応の閉じ } で戻る（${ ... } の中）。
func (s *flixScanner) code(inInterp bool) {
	depth := 0
	for s.i < len(s.src) {
		c := s.src[s.i]
		switch {
		case c == '\n':
			s.line++
			s.i++
		case c == '/' && s.peek(1) == '/':
			for s.i < len(s.src) && s.src[s.i] != '\n' {
				s.i++
			}
		case c == '/' && s.peek(1) == '*':
			s.i += 2
			for s.i < len(s.src) && !(s.src[s.i] == '*' && s.peek(1) == '/') {
				if s.src[s.i] == '\n' {
					s.line++
				}
				s.i++
			}
			s.i += 2
		case c == '"':
			s.i++
			s.str()
		case c == '\'':
			s.char()
		case c == '{':
			depth++
			s.i++
		case c == '}':
			if inInterp && depth == 0 {
				s.i++
				return
			}
			depth--
			s.i++
		default:
			s.i++
		}
	}
}

// str は文字列リテラルの中を、閉じの " まで読む。
func (s *flixScanner) str() {
	for s.i < len(s.src) {
		c := s.src[s.i]
		switch {
		case c == '"':
			s.i++
			return
		case c == '\n':
			s.line++
			s.i++
		case c == '\\':
			s.escape()
		case c == '$' && s.peek(1) == '{':
			s.i += 2
			s.code(true)
		default:
			s.emit(c, s.line)
			s.i++
		}
	}
}

// escape は \ から始まる 1 つを読む。\uXXXX は字として数える。
func (s *flixScanner) escape() {
	if s.peek(1) == 'u' && s.i+6 <= len(s.src) {
		if v, err := strconv.ParseUint(string(s.src[s.i+2:s.i+6]), 16, 32); err == nil {
			s.emit(rune(v), s.line)
			s.i += 6
			return
		}
	}
	switch s.peek(1) {
	case 'n', 't', 'r', 'b', 'f', '0':
	default:
		if s.peek(1) != 0 {
			s.emit(s.peek(1), s.line)
		}
	}
	s.i += 2
}

// char は ' から始まる字のリテラル（'a'・'　'・'\”）を読む。形が合わなければ ' を飛ばすだけ。
func (s *flixScanner) char() {
	if s.peek(1) == '\\' {
		end := s.i + 2
		for end < len(s.src) && end < s.i+9 && s.src[end] != '\'' {
			end++
		}
		if end < len(s.src) && s.src[end] == '\'' {
			s.i++
			s.escape()
			s.i = end + 1
			return
		}
	} else if s.peek(1) != 0 && s.peek(1) != '\n' && s.peek(2) == '\'' {
		s.emit(s.peek(1), s.line)
		s.i += 3
		return
	}
	s.i++
}
