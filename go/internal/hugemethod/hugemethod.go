// Package hugemethod は、ビルドした class の中から JVM が JIT しない大きさのメソッドを数える lint。
//
//	fge-go huge-methods <jar か class のフォルダ> ...   名指しの物の中の class を全部見る
//	fge-go huge-methods --stale <jar> ...               除外の一覧のうち、もう超えていない物も知らせる
//	fge-go huge-methods --root DIR ...                  リポジトリのルートを差し替える
//
// HotSpot は bytecode が HugeMethodLimit (8,000 バイト) を超えるメソッドを JIT しない (-XX:-DontCompileHugeMethods を付けない限り)。
// Flix はラムダを渡した def を呼ぶ所へインライン展開するので、ソースでは短いループが 1 つのメソッドに膨らみ、インタプリタのまま回る。
// 超えている物は、除外の一覧に理由つきで載っていれば通す (毎コマ通らない関数・1 コマに 1 回しか通らない関数)。
//
// WhyNot: .flix のソースを見ない — 大きさはインライン展開の後に決まり、ソースの行数からは分からない。
// WhyNot: Flix が出した class (Def$ と Clo$) だけを見る — jar に入った Java のライブラリは、こちらで直せない。
// 規約は bin/lint-rules/huge-methods.json (除外の鍵は "モジュール.関数::huge-methods")。ゲームの除外は huge-methods.local.json。
package hugemethod

import (
	"archive/zip"
	"encoding/binary"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

// Name は規約ファイルの名前 (bin/lint-rules/<Name>.json)。
const Name = "huge-methods"

// Rules は規約データ。すべて JSON から来る。
type Rules struct {
	Note     string `json:"note"`
	MaxBytes int    `json:"maxBytes"`
	Hint     string `json:"hint"`
	exempt   *lintconf.Exempt
}

// LoadRules は規約と除外を読む。
func LoadRules(root string) (*Rules, error) {
	var r Rules
	ex, err := lintconf.Load(root, Name, &r)
	if err != nil {
		return nil, err
	}
	if r.MaxBytes <= 0 || strings.TrimSpace(r.Hint) == "" {
		return nil, fmt.Errorf("huge-methods.json には maxBytes (1 以上) と hint が要ります")
	}
	r.exempt = ex
	return &r, nil
}

// Method は class の中のメソッド 1 つと、その bytecode の長さ。
type Method struct {
	Name  string
	Bytes int
}

// CodeLengths は class ファイル 1 つを読み、Code を持つメソッドの bytecode の長さを返す。
func CodeLengths(data []byte) ([]Method, error) {
	r := &reader{b: data}
	if r.u4() != 0xCAFEBABE {
		return nil, fmt.Errorf("class ファイルではありません")
	}
	r.skip(4)
	n := int(r.u2())
	utf8 := make(map[int]string, n)
	for i := 1; i < n; i++ {
		tag := r.u1()
		switch tag {
		case 1:
			l := int(r.u2())
			utf8[i] = string(r.bytes(l))
		case 3, 4, 9, 10, 11, 12, 17, 18:
			r.skip(4)
		case 5, 6:
			// long と double は constant pool の番号を 2 つ使う。
			r.skip(8)
			i++
		case 7, 8, 16, 19, 20:
			r.skip(2)
		case 15:
			r.skip(3)
		default:
			return nil, fmt.Errorf("constant pool の知らない tag %d", tag)
		}
		if r.err != nil {
			return nil, r.err
		}
	}
	r.skip(6)
	r.skip(2 * int(r.u2()))
	var out []Method
	for member := 0; member < 2; member++ {
		count := int(r.u2())
		for i := 0; i < count; i++ {
			r.skip(2)
			name := utf8[int(r.u2())]
			r.skip(2)
			attrs := int(r.u2())
			for a := 0; a < attrs; a++ {
				attrName := utf8[int(r.u2())]
				length := int(r.u4())
				if member == 1 && attrName == "Code" && length >= 8 {
					body := r.peek(8)
					if body != nil {
						out = append(out, Method{Name: name, Bytes: int(binary.BigEndian.Uint32(body[4:]))})
					}
				}
				r.skip(length)
			}
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	return out, nil
}

type reader struct {
	b   []byte
	p   int
	err error
}

func (r *reader) peek(n int) []byte {
	if r.err != nil || r.p+n > len(r.b) {
		if r.err == nil {
			r.err = io.ErrUnexpectedEOF
		}
		return nil
	}
	return r.b[r.p : r.p+n]
}

func (r *reader) bytes(n int) []byte {
	b := r.peek(n)
	if b != nil {
		r.p += n
	}
	return b
}

func (r *reader) skip(n int) { r.bytes(n) }

func (r *reader) u1() int {
	if b := r.bytes(1); b != nil {
		return int(b[0])
	}
	return 0
}

func (r *reader) u2() uint16 {
	if b := r.bytes(2); b != nil {
		return binary.BigEndian.Uint16(b)
	}
	return 0
}

func (r *reader) u4() uint32 {
	if b := r.bytes(4); b != nil {
		return binary.BigEndian.Uint32(b)
	}
	return 0
}

// FlixName は class の名前 (/ 区切り・.class なし) を Flix の「モジュール.関数」へ直す。Flix が出した def でも closure でもなければ ok = false。
// 依存の package の頭 ($pkg$…/) と、同じ def の複製を分ける末尾の番号は落とす (1 つの関数として数える)。
func FlixName(class string) (name string, ok bool) {
	parts := strings.Split(class, "/")
	last := parts[len(parts)-1]
	mods := parts[:len(parts)-1]
	if len(mods) > 0 && strings.HasPrefix(mods[0], "$pkg$") {
		mods = mods[1:]
	}
	var base string
	closure := false
	switch {
	case strings.HasPrefix(last, "Def$"):
		base = strings.TrimPrefix(last, "Def$")
	case strings.HasPrefix(last, "Clo$"):
		base = strings.TrimPrefix(last, "Clo$")
		closure = true
	default:
		return "", false
	}
	if i := strings.LastIndex(base, "$"); i > 0 && isDigits(base[i+1:]) {
		base = base[:i]
	}
	if closure {
		base += " の中のラムダ"
	}
	return strings.Join(append(append([]string{}, mods...), base), "."), true
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// Hit は上限を超えた関数 1 つ (複製はまとめる)。
type Hit struct {
	Name   string
	Bytes  int
	Copies int
}

type scan struct {
	maxBytes int
	classes  int
	hits     map[string]*Hit
}

func (s *scan) class(name string, data []byte) {
	flix, ok := FlixName(strings.TrimSuffix(filepath.ToSlash(name), ".class"))
	if !ok {
		return
	}
	methods, err := CodeLengths(data)
	if err != nil {
		return
	}
	s.classes++
	for _, m := range methods {
		if m.Bytes <= s.maxBytes {
			continue
		}
		h := s.hits[flix]
		if h == nil {
			h = &Hit{Name: flix}
			s.hits[flix] = h
		}
		h.Copies++
		if m.Bytes > h.Bytes {
			h.Bytes = m.Bytes
		}
	}
}

func (s *scan) jar(path string) error {
	z, err := zip.OpenReader(path)
	if err != nil {
		return err
	}
	defer z.Close()
	for _, f := range z.File {
		if !strings.HasSuffix(f.Name, ".class") {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		data, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			return err
		}
		s.class(f.Name, data)
	}
	return nil
}

func (s *scan) dir(path string) error {
	return filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".class") {
			return err
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(path, p)
		s.class(rel, data)
		return nil
	})
}

func key(name string) string { return name + "::" + Name }

// Run は fge huge-methods の本体。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	stale := false
	var inputs []string
	for _, a := range args {
		if a == "--stale" {
			stale = true
		} else {
			inputs = append(inputs, a)
		}
	}
	if len(inputs) == 0 {
		return 2, fmt.Errorf("見る物がありません。flix build-jar で作った jar か、class のフォルダを渡してください")
	}
	s := &scan{maxBytes: rules.MaxBytes, hits: map[string]*Hit{}}
	for _, in := range inputs {
		info, err := os.Stat(in)
		if err != nil {
			return 2, fmt.Errorf("読めません (%s): %v", in, err)
		}
		if info.IsDir() {
			err = s.dir(in)
		} else {
			err = s.jar(in)
		}
		if err != nil {
			return 2, fmt.Errorf("読めません (%s): %v", in, err)
		}
	}
	if s.classes == 0 {
		return 2, fmt.Errorf("Flix の class が 1 つもありません (jar か build/class のフォルダを渡してください)")
	}
	return report(out, errOut, rules, s, stale), nil
}

func report(out, errOut *strings.Builder, rules *Rules, s *scan, stale bool) int {
	var bad []*Hit
	for name, h := range s.hits {
		if _, ok := rules.exempt.Why[key(name)]; !ok {
			bad = append(bad, h)
		}
	}
	code := 0
	if stale {
		// WhyNot: --stale を既定にしない — Flix は main から届く関数だけを jar に入れるので、jar ごとに入っている関数が違う。
		//   除外の関数が「直った」のか「この jar に入っていないだけ」かは、全部の関数が届く jar を渡した人にしか分からない。
		var gone []string
		for k := range rules.exempt.Why {
			if _, ok := s.hits[strings.TrimSuffix(k, "::"+Name)]; !ok {
				gone = append(gone, k)
			}
		}
		sort.Strings(gone)
		for _, k := range gone {
			fmt.Fprintf(errOut, "  %s は %s の exempt に載っていますが、渡した class の中では %d バイト以下か、入っていません\n", k, rules.exempt.From[k], rules.MaxBytes)
			code = 1
		}
	}
	if len(bad) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-huge-methods] OK (Flix の class %d 個 / 上限 %d バイト / 超えていて除外の物 %d 件)\n", s.classes, rules.MaxBytes, len(s.hits))
		}
		return code
	}
	sort.Slice(bad, func(i, j int) bool {
		if bad[i].Bytes != bad[j].Bytes {
			return bad[i].Bytes > bad[j].Bytes
		}
		return bad[i].Name < bad[j].Name
	})
	for _, h := range bad {
		copies := ""
		if h.Copies > 1 {
			copies = fmt.Sprintf("・複製 %d 個", h.Copies)
		}
		fmt.Fprintf(errOut, "!! %s は %d バイト（上限 %d バイト%s）\n", h.Name, h.Bytes, rules.MaxBytes, copies)
	}
	fmt.Fprintf(errOut, "[lint-huge-methods] %d 件。%s\n"+
		"  毎コマ通らない関数なら bin/lint-rules/huge-methods.json（ゲームは huge-methods.local.json）の exempt へ \"モジュール.関数::huge-methods\" と理由 1 行\n",
		len(bad), rules.Hint)
	return 1
}
