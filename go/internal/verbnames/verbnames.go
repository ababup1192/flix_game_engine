// Package verbnames は .flix の def の名前の頭の動詞と、その型がずれていないかを見る lint。
//
//	fge-go verb-names [path ...]   名指しの .flix だけ見る (コミット時はステージしたファイル)
//	fge-go verb-names --all        git が知っている .flix を全部見る (古い除外もここで裁く)
//	fge-go verb-names --root DIR   リポジトリのルートを差し替える
//
// 止めるのは 2 つ。
//   - boolPrefixes (is / has / can) で始まるのに、戻りの型が Bool ではない
//   - pureGetPrefixes (get) で始まるのに、決まった効果 (IO・Fs など大文字で始まる効果) を持つ
//
// 頭の動詞は「動詞の後ろが大文字か数字」の時だけ数える (isometric・getaway は動詞ではない)。
// 効果の変数 (ef など小文字の名前) と \ {} は純粋と同じに扱う (渡した関数の効果を通すだけなので)。
//
// WhyNot: 1 行の宣言だけを見るのは、型を読むのに Flix の構文解析を持ち込まずに済ませるため。
// 複数行にまたがる宣言は見ない (見逃す側に倒す。誤って止めるよりは良い)。
//
// 規約は bin/lint-rules/verb-names.json、ゲームの除外は verb-names.local.json の exempt
// ("パス::def の名前": 理由)。
package verbnames

import (
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

// Name は規約ファイルの名前 (bin/lint-rules/<Name>.json)。
const Name = "verb-names"

// Rules は規約データ。すべて JSON から来る。
type Rules struct {
	Note            string   `json:"note"`
	ScopeSuffixes   []string `json:"scopeSuffixes"`
	SkipPrefixes    []string `json:"skipPrefixes"`
	SkipDirNames    []string `json:"skipDirNames"`
	BoolPrefixes    []string `json:"boolPrefixes"`
	PureGetPrefixes []string `json:"pureGetPrefixes"`
	Hint            string   `json:"hint"`
	exempt          *lintconf.Exempt
}

// LoadRules は規約と除外を読む。
func LoadRules(root string) (*Rules, error) {
	var r Rules
	ex, err := lintconf.Load(root, Name, &r)
	if err != nil {
		return nil, err
	}
	if len(r.ScopeSuffixes) == 0 || len(r.BoolPrefixes) == 0 || len(r.PureGetPrefixes) == 0 || strings.TrimSpace(r.Hint) == "" {
		return nil, fmt.Errorf("verb-names.json には scopeSuffixes・boolPrefixes・pureGetPrefixes・hint が要ります")
	}
	r.exempt = ex
	return &r, nil
}

// InScope はファイル rel を見るか。
func (r *Rules) InScope(rel string) bool {
	if lintconf.HasPrefixAny(rel, r.SkipPrefixes) {
		return false
	}
	for _, d := range strings.Split(path.Dir(rel), "/") {
		for _, s := range r.SkipDirNames {
			if d == s {
				return false
			}
		}
	}
	for _, s := range r.ScopeSuffixes {
		if strings.HasSuffix(rel, s) {
			return true
		}
	}
	return false
}

// Hit は止める 1 つの def。
type Hit struct {
	Path, Def, Why string
	Line           int
}

func (h Hit) key() string { return h.Path + "::" + h.Def }

var defRe = regexp.MustCompile(`^\s*(?:@\w+\s+)*(?:pub\s+)?(?:inline\s+)?def\s+([a-z]\w*)`)

// Decl は 1 行の def の宣言を分けた物。
type Decl struct {
	Name, Ret, Effect string
}

// ParseDecl は 1 行から def の名前・戻りの型・効果を取り出す。1 行で閉じていない宣言は ok = false。
func ParseDecl(line string) (Decl, bool) {
	m := defRe.FindStringSubmatchIndex(line)
	if m == nil {
		return Decl{}, false
	}
	d := Decl{Name: line[m[2]:m[3]]}
	i := m[1]
	if i < len(line) && line[i] == '[' {
		if i = skipGroup(line, i); i < 0 {
			return Decl{}, false
		}
	}
	if i >= len(line) || line[i] != '(' {
		return Decl{}, false
	}
	if i = skipGroup(line, i); i < 0 {
		return Decl{}, false
	}
	rest := strings.TrimLeft(line[i:], " \t")
	if !strings.HasPrefix(rest, ":") {
		return Decl{}, false
	}
	rest = rest[1:]
	end := -1
	depth := 0
	for j := 0; j < len(rest); j++ {
		switch rest[j] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case '=':
			if depth == 0 && (j+1 >= len(rest) || rest[j+1] != '>') && (j == 0 || rest[j-1] == ' ') {
				end = j
			}
		case ' ':
			if depth == 0 && (strings.HasPrefix(rest[j:], " with ") || strings.HasPrefix(rest[j:], " where ")) {
				end = j
			}
		}
		if end >= 0 {
			break
		}
	}
	if end < 0 {
		return Decl{}, false
	}
	sig := strings.TrimSpace(rest[:end])
	d.Ret = sig
	depth = 0
	for j := 0; j < len(sig); j++ {
		switch sig[j] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case '\\':
			if depth == 0 {
				d.Ret = strings.TrimSpace(sig[:j])
				d.Effect = strings.TrimSpace(sig[j+1:])
				return d, true
			}
		}
	}
	return d, true
}

// skipGroup は line[i] の開き括弧に対応する閉じ括弧の次の位置。閉じなければ -1。
func skipGroup(line string, i int) int {
	depth := 0
	for ; i < len(line); i++ {
		switch line[i] {
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
			if depth == 0 {
				return i + 1
			}
		}
	}
	return -1
}

var effTokenRe = regexp.MustCompile(`[A-Za-z_][\w.]*`)

// ConcreteEffects は効果の式のうち、決まった効果 (大文字で始まる名前) だけを返す。
func ConcreteEffects(eff string) []string {
	var out []string
	for _, t := range effTokenRe.FindAllString(eff, -1) {
		if t[0] >= 'A' && t[0] <= 'Z' {
			out = append(out, t)
		}
	}
	return out
}

// verbOf は名前の頭が一覧のどれかの動詞か (動詞の後ろは大文字か数字か終わり)。
func verbOf(name string, verbs []string) string {
	for _, v := range verbs {
		if !strings.HasPrefix(name, v) {
			continue
		}
		if len(name) == len(v) {
			return v
		}
		c := name[len(v)]
		if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			return v
		}
	}
	return ""
}

// Scan は 1 ファイルの本文から止める def を拾う。
func (r *Rules) Scan(rel, text string) []Hit {
	var hits []Hit
	for n, line := range strings.Split(text, "\n") {
		d, ok := ParseDecl(line)
		if !ok {
			continue
		}
		if v := verbOf(d.Name, r.BoolPrefixes); v != "" && d.Ret != "Bool" {
			hits = append(hits, Hit{Path: rel, Line: n + 1, Def: d.Name,
				Why: fmt.Sprintf("%s* なのに Bool を返しません (返すのは %s)", v, d.Ret)})
			continue
		}
		if v := verbOf(d.Name, r.PureGetPrefixes); v != "" {
			if effs := ConcreteEffects(d.Effect); len(effs) > 0 {
				hits = append(hits, Hit{Path: rel, Line: n + 1, Def: d.Name,
					Why: fmt.Sprintf("%s* なのに効果 %s を持ちます", v, strings.Join(effs, " + "))})
			}
		}
	}
	return hits
}

// Run は fge verb-names の本体。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	all, files, err := lintconf.Args(root, args)
	if err != nil {
		return 2, err
	}
	var hits []Hit
	seen := 0
	for _, rel := range files {
		if !rules.InScope(rel) {
			continue
		}
		abs := filepath.Join(root, filepath.FromSlash(rel))
		// WhyNot: symlink を見ないのは、engine の src/ のように同じ .flix を別名で
		// 指しているだけの物を 2 度数えないため (実体の側で 1 度見る)。
		if info, err := os.Lstat(abs); err != nil || !info.Mode().IsRegular() {
			continue
		}
		body, err := os.ReadFile(abs)
		if err != nil {
			continue
		}
		seen++
		hits = append(hits, rules.Scan(rel, string(body))...)
	}
	return report(out, errOut, root, rules, hits, all, seen), nil
}

func report(out, errOut *strings.Builder, root string, rules *Rules, hits []Hit, all bool, seen int) int {
	live := map[string]bool{}
	var bad []Hit
	for _, h := range hits {
		live[h.key()] = true
		if _, ok := rules.exempt.Why[h.key()]; !ok {
			bad = append(bad, h)
		}
	}
	code := 0
	if all {
		for _, k := range rules.exempt.Stale(root, live) {
			fmt.Fprintf(errOut, "  %s は %s の exempt に載っていますが、もう鳴る所がありません（消してください）\n", k, rules.exempt.From[k])
			code = 1
		}
	}
	if len(bad) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-verb-names] OK (%d ファイル / 除外 %d 件)\n", seen, len(rules.exempt.Why))
		}
		return code
	}
	for _, h := range bad {
		fmt.Fprintf(errOut, "!! %s:%d %s — %s\n", h.Path, h.Line, h.Def, h.Why)
	}
	fmt.Fprintf(errOut, "[lint-verb-names] %d 件。%s\n"+
		"  名前を直す (例: 効果のある get* は load* / fetch*、Bool でない is* は値の名前に)。"+
		"どうしても残すなら bin/lint-rules/verb-names.local.json の exempt へ \"パス::def の名前\" と理由 1 行\n",
		len(bad), rules.Hint)
	return 1
}
