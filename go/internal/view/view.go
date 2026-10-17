package view

// view — View が矩形と円だけになっていないかを検査するゲート
// (bin/lint-view.py と同じ出力)。
//
//	fge-go view [path/to/View.flix ...]
//
// 引数が無ければ templates/ を全部見る。

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// hudTextPattern は world 側に文字を直書きしている印。
const hudTextPattern = `Render\.text|TextDraw\.`

// exemptTrim は除外理由の前に付く飾り。
const exemptTrim = " —-–:"

type badItem struct {
	path  string
	rect  int
	total int
}

type skipItem struct {
	path   string
	reason string
}

// bodyOf はコメント行を落とした本文を返す。
func bodyOf(src string) string {
	var kept []string
	for _, ln := range pxlib.SplitLines(src) {
		if strings.HasPrefix(strings.TrimLeftFunc(ln, unicode.IsSpace), "//") {
			continue
		}
		kept = append(kept, ln)
	}
	return strings.Join(kept, "\n")
}

// exemptReason は `// lint-view: 対象外 — 理由` が書いてあればその理由を返す。
func exemptReason(src string) (string, bool) {
	for _, line := range pxlib.SplitLines(src) {
		stripped := strings.TrimFunc(line, unicode.IsSpace)
		if !strings.HasPrefix(stripped, "//") {
			continue
		}
		if !strings.Contains(stripped, "lint-view:") || !strings.Contains(stripped, "対象外") {
			continue
		}
		_, tail, _ := strings.Cut(stripped, "対象外")
		reason := strings.TrimFunc(strings.TrimLeft(tail, exemptTrim), unicode.IsSpace)
		if reason == "" {
			return "（理由が書かれていません）", true
		}
		return reason, true
	}
	return "", false
}

// check は (矩形数, 総数) を返す。判定対象外なら ok=false。
func (r *Rules) check(src string) (rect, total int, ok bool) {
	body := bodyOf(src)
	rect = len(r.Rect.FindAll(body))
	total = rect + len(r.Rich.FindAll(body))
	if total < r.MinDraws {
		return 0, 0, false
	}
	return rect, total, true
}

// rectCounts は本文で矩形系にあたった関数名ごとの回数を数える。
func (r *Rules) rectCounts(src string) map[string]int {
	counts := map[string]int{}
	for _, m := range r.Rect.FindAll(bodyOf(src)) {
		name := m
		if i := strings.LastIndex(m, "."); i >= 0 {
			name = m[i+1:]
		}
		counts[name]++
	}
	return counts
}

// projectRootOf は検査対象のファイルからゲーム 1 本の根 (src の親) を探す。
func projectRootOf(path string) (string, bool) {
	anchor, parts := pxlib.PathParts(path)
	for i := len(parts) - 1; i >= 1; i-- {
		if parts[i-1] != "src" {
			continue
		}
		joined := strings.Join(parts[:i-1], "/")
		if anchor == "" {
			if joined == "" {
				return ".", true
			}
			return joined, true
		}
		return anchor + joined, true
	}
	return "", false
}

// hudSmell は world 側に文字を直書きしているのに withHudView が無い匂いを返す。
func hudSmell(projectDir string) (string, bool) {
	srcDir := filepath.Join(projectDir, "src")
	if !pxlib.HasDir(srcDir) {
		return "", false
	}
	textRe, err := pxlib.CompilePy(hudTextPattern)
	if err != nil {
		return "", false
	}
	usesText, hasHud := false, false
	for _, p := range pxlib.Rglob(srcDir, ".flix") {
		src, err := pxlib.LoadTextReplace(p)
		if err != nil {
			continue
		}
		body := bodyOf(src)
		if strings.Contains(body, "withHudView") {
			hasHud = true
		}
		if filepath.Base(filepath.Dir(p)) != "render" && textRe.MatchString(body) {
			usesText = true
		}
	}
	if usesText && !hasHud {
		return fmt.Sprintf("警告: %s — 文字（Render.text / TextDraw）を world 側の絵に直書きしていますが"+
			" withHudView がありません。スコアや案内文は App.withHudView に繋ぐと、"+
			"world 側の z がどれだけ大きくても必ず手前に出ます（警告のみ・失敗にはしません）",
			pxlib.PosixPath(projectDir)), true
	}
	return "", false
}

// isTarget は名前で絞る。名前を変えるとスキップできる穴になるので拡張子だけを見る。
func isTarget(path string) bool {
	return strings.HasSuffix(path, ".flix")
}

// isCheckable は実在する .flix ファイルかを見る。
func isCheckable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular() && isTarget(pxlib.PosixPath(path))
}

// readTarget は検査してよいファイルなら中身を返す。
func readTarget(path string) (string, bool) {
	if !isCheckable(path) {
		return "", false
	}
	src, err := pxlib.LoadTextReplace(path)
	if err != nil {
		return "", false
	}
	return src, true
}

// Run は検査を走らせて終了コードを返す。
// err が返ったとき呼ぶ側は必ず止まる（規約を読めないまま緑にしない）。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}

	targets := args
	if len(targets) == 0 {
		targets = pxlib.Rglob(filepath.Join(root, "templates"), ".flix")
	}

	var bad []badItem
	var skipped []skipItem
	for _, path := range targets {
		src, ok := readTarget(path)
		if !ok {
			continue
		}
		if reason, exempt := exemptReason(src); exempt {
			skipped = append(skipped, skipItem{pxlib.PosixPath(path), reason})
			continue
		}
		rect, total, ok := rules.check(src)
		if !ok {
			continue
		}
		if rect*100 > total*rules.RectPct {
			bad = append(bad, badItem{pxlib.PosixPath(path), rect, total})
		}
	}

	for _, s := range skipped {
		fmt.Fprintf(out, "除外: %s — %s\n", s.path, s.reason)
	}

	// HUD の匂いはゲーム 1 本ごとに 1 回だけ・警告のみで終了コードに効かせない。
	seen := map[string]bool{}
	for _, path := range targets {
		if !isCheckable(path) {
			continue
		}
		rootDir, ok := projectRootOf(path)
		if !ok || seen[rootDir] {
			continue
		}
		seen[rootDir] = true
		if smell, ok := hudSmell(rootDir); ok {
			fmt.Fprintln(out, smell)
		}
	}

	if len(bad) == 0 {
		fmt.Fprintf(out, "OK: 矩形だけの View はありません（除外 %d 件）\n", len(skipped))
		return 0, nil
	}

	for _, b := range bad {
		src, ok := readTarget(b.path)
		if !ok {
			src = ""
		}
		counts := rules.rectCounts(src)
		names := make([]string, 0, len(counts))
		for name := range counts {
			names = append(names, name)
		}
		sort.Strings(names)
		parts := make([]string, 0, len(names))
		for _, name := range names {
			parts = append(parts, fmt.Sprintf("%s が %d 回", name, counts[name]))
		}
		fmt.Fprintf(errOut, "%s: 描画がほぼ矩形と円だけです（矩形系 %d / 全体 %d）— %s。%s\n",
			b.path, b.rect, b.total, strings.Join(parts, "、"), rules.Destinations)
	}
	fmt.Fprintln(errOut, "")
	fmt.Fprintf(errOut, "絵の下限 5 性質を満たせていません。%s （決まりは .claude/rules/drawing.md・部品は engine の docs/art-ref/visual-dict/reference.md）\n",
		rules.Destinations)
	return 1, nil
}
