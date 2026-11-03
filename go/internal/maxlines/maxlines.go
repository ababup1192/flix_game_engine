// Package maxlines は、engine のソースの 1 ファイルが決めた行数を超えていないかを数える lint (ESLint の max-lines と同じ考え)。
//
//	fge-go max-lines [path ...]   名指しのファイルだけ見る (コミット時はステージした物)
//	fge-go max-lines --all        git が知っているファイルを全部見る (古い除外もここで裁く)
//	fge-go max-lines --root DIR   リポジトリのルートを差し替える
//
// 見るのは規約の prefixes の下の suffixes のファイルだけ。超えている物は、除外の一覧に載っていれば通す。
// 除外は分けるまでの一覧で、分け終えたら --all が「もう鳴らない」と言うので消す。
//
// WhyNot: 行数の上限をゲームの src にかけない — ゲームの大きさとファイルの分け方はゲームが決める。
// 規約は bin/lint-rules/max-lines.json (除外の鍵は "パス::max-lines")。
package maxlines

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

// Name は規約ファイルの名前 (bin/lint-rules/<Name>.json)。
const Name = "max-lines"

// Rules は規約データ。すべて JSON から来る。
type Rules struct {
	Note     string   `json:"note"`
	Prefixes []string `json:"prefixes"`
	Suffixes []string `json:"suffixes"`
	MaxLines int      `json:"maxLines"`
	Hint     string   `json:"hint"`
	exempt   *lintconf.Exempt
}

// LoadRules は規約と除外を読む。
func LoadRules(root string) (*Rules, error) {
	var r Rules
	ex, err := lintconf.Load(root, Name, &r)
	if err != nil {
		return nil, err
	}
	if len(r.Prefixes) == 0 || len(r.Suffixes) == 0 || r.MaxLines <= 0 || strings.TrimSpace(r.Hint) == "" {
		return nil, fmt.Errorf("max-lines.json には prefixes・suffixes・maxLines (1 以上)・hint が要ります")
	}
	r.exempt = ex
	return &r, nil
}

func (r *Rules) watches(rel string) bool {
	if !lintconf.HasPrefixAny(rel, r.Prefixes) {
		return false
	}
	for _, s := range r.Suffixes {
		if strings.HasSuffix(rel, s) {
			return true
		}
	}
	return false
}

// CountLines は本文の行の数 (wc -l と同じく改行の数。最後の行に改行が無ければ 1 足す)。
func CountLines(body []byte) int {
	n := bytes.Count(body, []byte("\n"))
	if len(body) > 0 && body[len(body)-1] != '\n' {
		n++
	}
	return n
}

// Hit は上限を超えた 1 ファイル。
type Hit struct {
	Path  string
	Lines int
}

func key(p string) string { return p + "::" + Name }

// Run は fge max-lines の本体。
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
		if !rules.watches(rel) {
			continue
		}
		info, err := os.Lstat(filepath.Join(root, filepath.FromSlash(rel)))
		// WhyNot: symlink を数えない — prefixes を写しの置き場 (ルートの src/ など) へ広げても、同じファイルを 2 度数えない。
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		body, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil {
			continue
		}
		seen++
		if n := CountLines(body); n > rules.MaxLines {
			hits = append(hits, Hit{Path: rel, Lines: n})
		}
	}
	return report(out, errOut, root, rules, hits, all, seen), nil
}

func report(out, errOut *strings.Builder, root string, rules *Rules, hits []Hit, all bool, seen int) int {
	live := map[string]bool{}
	var bad []Hit
	for _, h := range hits {
		live[key(h.Path)] = true
		if _, ok := rules.exempt.Why[key(h.Path)]; !ok {
			bad = append(bad, h)
		}
	}
	code := 0
	if all {
		for _, k := range rules.exempt.Stale(root, live) {
			fmt.Fprintf(errOut, "  %s は %s の exempt に載っていますが、もう %d 行以下です（消してください）\n", k, rules.exempt.From[k], rules.MaxLines)
			code = 1
		}
	}
	if len(bad) == 0 {
		if code == 0 {
			fmt.Fprintf(out, "[lint-max-lines] OK (%d ファイル / 上限 %d 行 / 除外 %d 件)\n", seen, rules.MaxLines, len(rules.exempt.Why))
		}
		return code
	}
	sort.Slice(bad, func(i, j int) bool { return bad[i].Path < bad[j].Path })
	for _, h := range bad {
		fmt.Fprintf(errOut, "!! %s は %d 行（上限 %d 行）\n", h.Path, h.Lines, rules.MaxLines)
	}
	fmt.Fprintf(errOut, "[lint-max-lines] %d 件。%s\n"+
		"  分けるまで残すなら bin/lint-rules/max-lines.json の exempt へ \"パス::max-lines\" と理由 1 行\n",
		len(bad), rules.Hint)
	return 1
}
