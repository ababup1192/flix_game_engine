package apiindex

// apiindex — pub def を持つモジュールが索引 (docs/*-module-index.md) に載っているかを
// 検査するゲート。
//
//	fge-go check-api-index              リポジトリ全体を検査
//	fge-go check-api-index --root DIR   リポジトリのルートを差し替える
//
// 検査は 2 方向:
//  1. engine/src・engine_world/src の pub def を持つモジュールが、対応する索引に
//     モジュール名で載っているか
//  2. 索引が「Mod.関数」の形で挙げている関数が、ソースに pub def として実在するか
//
// WhyNot: 宣言の抽出に flixdecl を使わないのは、ここが数えるのは 1 行で書かれた
// `^(pub )?mod ` と `^\s*pub def ` だけで、複数行にまたがる宣言も eff の op も数に入れないため。
// flixdecl に寄せると拾う件数が変わり、「pub def N 本」の数字がずれる。
// ファイルの並べ方だけは flixdecl.FlixFiles を借りる。

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/ababup1192/flix_game_engine/go/internal/flixdecl"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// pySpace は空白とみなす字の集合（Unicode の空白すべて）。
// WhyNot: Go の `\s` を使わないのは ASCII だけしか見ないため（全角空白で切れ方が変わる）。
const pySpace = `[\t\n\v\f\r \x{1c}-\x{1f}\x{85}\p{Z}]`

var (
	modDeclRe = regexp.MustCompile(`(?m)^(?:pub )?mod ([A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)*)`)
	pubDefRe  = regexp.MustCompile(`(?m)^` + pySpace + `*pub def ([a-zA-Z][A-Za-z0-9_]*)`)
	// 索引が関数を指す形は「Mod.func」（func は小文字始まり）。前後の語境界は Go の
	// 正規表現が ASCII しか見ないので、当てた後に自分で見る（docFuncRefs）。
	docFuncBodyRe = regexp.MustCompile(`[A-Z][A-Za-z0-9]*\.[a-z][A-Za-z0-9]*`)
)

// isWordRune は語を作る文字かを返す（Unicode の字・数字・アンダースコア）。
func isWordRune(r rune) bool {
	return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r)
}

// isWordAt は位置 i の（before なら手前の）文字が語の文字かを返す。
func isWordAt(s string, i int, before bool) bool {
	var r rune
	if before {
		if i <= 0 {
			return false
		}
		r, _ = utf8.DecodeLastRuneInString(s[:i])
	} else {
		if i >= len(s) {
			return false
		}
		r, _ = utf8.DecodeRuneInString(s[i:])
	}
	return isWordRune(r)
}

// wordIn は name が語として独立して text に出るかを見る（前後が語の文字でない位置）。
func wordIn(name, text string) bool {
	for i := 0; ; {
		j := strings.Index(text[i:], name)
		if j < 0 {
			return false
		}
		start := i + j
		end := start + len(name)
		if !isWordAt(text, start, true) && !isWordAt(text, end, false) {
			return true
		}
		i = start + 1
	}
}

// funcRef は索引に出てくる「Mod.func」1 件。
type funcRef struct {
	Mod  string
	Func string
}

// docFuncRefs は索引に出てくる「Mod.func」を、書かれた順に拾う。
//
// WhyNot: `\b(...)\.(...)\b` をそのまま Go の正規表現に渡さないのは、Go の `\b` が
// ASCII しか語とみなさず、日本語に挟まれた「Mod.func」を語の途中とみなして落とすため。
// 境界の判定だけを自分で行い、外れた所は 1 文字進めて探し直す。
func docFuncRefs(doc string) []funcRef {
	var out []funcRef
	for pos := 0; pos <= len(doc); {
		loc := docFuncBodyRe.FindStringIndex(doc[pos:])
		if loc == nil {
			break
		}
		start, end := pos+loc[0], pos+loc[1]
		// 前後が語の文字なら語の途中なので採らない。1 バイト進めて探し直す。
		if isWordAt(doc, start, true) || isWordAt(doc, end, false) {
			pos = start + 1
			continue
		}
		dot := strings.IndexByte(doc[start:end], '.') + start
		out = append(out, funcRef{Mod: doc[start:dot], Func: doc[dot+1 : end]})
		pos = end
	}
	return out
}

// stripComments はコメント行に書かれた mod 名・pub def を拾わないための下ごしらえ。
func stripComments(src string) string {
	var kept []string
	for _, ln := range pxlib.SplitLines(src) {
		if strings.HasPrefix(strings.TrimLeftFunc(ln, flixdecl.IsSpace), "//") {
			continue
		}
		kept = append(kept, ln)
	}
	return strings.Join(kept, "\n")
}

// hasSkippedParent は path の親フォルダのどれかが skip に載っているかを見る。
func hasSkippedParent(path string, skip map[string]bool) bool {
	dir := filepath.Dir(path)
	for {
		if skip[filepath.Base(dir)] {
			return true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return false
		}
		dir = parent
	}
}

// scanPackage は {トップレベルモジュール名: pub def 名の集合} を返す。
func scanPackage(root, srcRel string, skip map[string]bool) map[string]map[string]bool {
	mods := map[string]map[string]bool{}
	for _, path := range flixdecl.FlixFiles(root, srcRel) {
		if hasSkippedParent(path, skip) {
			continue
		}
		text, err := pxlib.ReadTextReplace(path)
		if err != nil {
			continue
		}
		body := stripComments(text)
		decls := modDeclRe.FindAllStringSubmatch(body, -1)
		if len(decls) == 0 {
			continue
		}
		// 1 ファイル複数 mod でも、索引の粒度（トップレベル名）にまとめて数える。
		top := strings.SplitN(decls[0][1], ".", 2)[0]
		defs := map[string]bool{}
		for _, m := range pubDefRe.FindAllStringSubmatch(body, -1) {
			defs[m[1]] = true
		}
		if len(defs) == 0 {
			continue
		}
		if mods[top] == nil {
			mods[top] = map[string]bool{}
		}
		for name := range defs {
			mods[top][name] = true
		}
	}
	return mods
}

func mergeInto(dst map[string]map[string]bool, src map[string]map[string]bool) {
	for name, defs := range src {
		if dst[name] == nil {
			dst[name] = map[string]bool{}
		}
		for d := range defs {
			dst[name][d] = true
		}
	}
}

func sortedKeys(m map[string]map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// scanned は 1 つの (ソースの根, 索引) の走査結果。
type scanned struct {
	src  string
	doc  string
	mods map[string]map[string]bool
}

// exemptNote は「索引に載せないと決めたモジュール」1 件。
type exemptNote struct {
	name   string
	reason string
}

// Options は呼ぶ側が差し替えられる所。Rules が nil なら規約ファイルから読む。
type Options struct {
	Rules *Rules
}

// Run は検査を走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（規約を読めないまま緑にしない）。
func Run(out, errOut *strings.Builder, root string, args []string, opts Options) (int, error) {
	rules := opts.Rules
	if rules == nil {
		loaded, err := LoadRules(root)
		if err != nil {
			return 2, err
		}
		rules = loaded
	}
	// WhyNot: 引数を弾かないのは、この検査に引数が無いため（余分な語を渡しても
	// 通常の検査が走る）。
	_ = args

	// WhyNot: 絶対パスに直すのは、SKIP_DIRS の判定が「親フォルダの名前ぜんぶ」を
	// 見るため（相対のままだと根より上の名前が見えない）。
	absRoot, err := filepath.Abs(root)
	if err != nil {
		return 2, fmt.Errorf("根のパスを決められません: %v", err)
	}

	allDefs := map[string]map[string]bool{}
	var targets []scanned
	for _, t := range rules.Targets {
		mods := scanPackage(absRoot, t.Src, rules.SkipDirs)
		mergeInto(allDefs, mods)
		targets = append(targets, scanned{src: t.Src, doc: t.Doc, mods: mods})
	}
	// 幽霊参照の照合には描き出し側 (engine_tools) の pub def も混ぜる。
	for _, extra := range rules.ExtraDefSources {
		mergeInto(allDefs, scanPackage(absRoot, extra, rules.SkipDirs))
	}

	var problems []string
	var exempted []exemptNote
	for _, t := range targets {
		docPath := filepath.Join(absRoot, filepath.FromSlash(t.doc))
		data, err := os.ReadFile(docPath)
		if err != nil {
			fmt.Fprintf(errOut, "読めません: %s\n", t.doc)
			return 1, nil
		}
		doc := string(data)

		// 1. モジュールが索引に載っているか。
		for _, name := range sortedKeys(t.mods) {
			if reason, ok := rules.Exempt[name]; ok {
				exempted = append(exempted, exemptNote{name: name, reason: reason})
				continue
			}
			if !wordIn(name, doc) {
				problems = append(problems, fmt.Sprintf(
					"%s: モジュール %s（%s 配下・pub def %d 本）が載っていません",
					t.doc, name, t.src, len(t.mods[name])))
			}
		}

		// 2. 索引の「Mod.関数」参照が実在するか。
		for _, ref := range uniqueSorted(docFuncRefs(doc)) {
			if rules.FileExts[ref.Func] {
				continue
			}
			defs, known := allDefs[ref.Mod]
			if !known {
				continue // 標準ライブラリや別リポのモジュールは照合しない
			}
			if !defs[ref.Func] {
				problems = append(problems, fmt.Sprintf(
					"%s: %s.%s は pub def に見つかりません（改名か削除の可能性）",
					t.doc, ref.Mod, ref.Func))
			}
		}
	}

	for _, e := range exempted {
		fmt.Fprintf(out, "除外: %s — %s\n", e.name, e.reason)
	}

	if len(problems) == 0 {
		fmt.Fprintf(out, "OK: 索引とソースの pub def はそろっています（除外 %d 件）\n", len(exempted))
		return 0, nil
	}

	for _, p := range problems {
		fmt.Fprintf(errOut, "%s\n", p)
	}
	fmt.Fprintf(errOut, "\n")
	fmt.Fprintf(errOut, "モジュールを足したら docs/module-index.md（engine_world）か\n"+
		"docs/engine-module-index.md（engine）に 1 行足してください。\n"+
		"内部専用なら bin/check-api-index.py の EXEMPT に理由付きで載せてください。\n")
	return 1, nil
}

// uniqueSorted は重複を落として並べ替える（モジュール名・関数名の順）。
func uniqueSorted(refs []funcRef) []funcRef {
	seen := map[funcRef]bool{}
	var out []funcRef
	for _, r := range refs {
		if seen[r] {
			continue
		}
		seen[r] = true
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Mod != out[j].Mod {
			return out[i].Mod < out[j].Mod
		}
		return out[i].Func < out[j].Func
	})
	return out
}
