// Package reference はリファレンス画像（reference/SHA256SUMS.txt）と gallery/ の絵を比べる・基準を作り直す
// （fge reference check / update・make reference-check / reference-update の中身）。
//
// SHA256SUMS.txt の形は shasum -a 256 の出力のまま（"<ハッシュ>  <名前>"・名前はバイト順）。
package reference

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const (
	sumsRel  = "reference/SHA256SUMS.txt"
	itemsRel = "reference/ITEMS.tsv"
)

const usage = "使い方: fge reference check | update [BUDGET=accept]"

// Deps は外の世界とつなぐ所。
type Deps struct {
	Out, Err io.Writer
	// Fge は同じ fge のサブコマンドを起こす（絵の値段の判定とキャッシュの片付け）。
	Fge    func(dir string, args ...string) error
	Getenv func(string) string
}

// DefaultDeps は os.Executable() の fge を起こす。
func DefaultDeps(out, errOut io.Writer) Deps {
	return Deps{
		Out: out, Err: errOut,
		Fge: func(dir string, args ...string) error {
			exe, err := os.Executable()
			if err != nil {
				return err
			}
			c := exec.Command(exe, args...)
			c.Dir = dir
			c.Stdout, c.Stderr = out, errOut
			return c.Run()
		},
		Getenv: os.Getenv,
	}
}

// Run は fge reference の本体。dir はゲームのフォルダ。
func Run(dir string, args []string, d Deps) int {
	if len(args) == 0 {
		fmt.Fprintln(d.Err, usage)
		return 2
	}
	budget := d.Getenv("BUDGET")
	for _, a := range args[1:] {
		v, ok := strings.CutPrefix(a, "BUDGET=")
		if !ok {
			fmt.Fprintf(d.Err, "知らない引数です: %s\n%s\n", a, usage)
			return 2
		}
		budget = v
	}
	switch args[0] {
	case "check":
		return Check(dir, d)
	case "update":
		return Update(dir, budget == "accept", d)
	}
	fmt.Fprintln(d.Err, usage)
	return 2
}

// galleryPNGs は gallery/ 直下の *.png の名前（バイト順）。
func galleryPNGs(dir string) ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(dir, "gallery"))
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".png") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

type sumLine struct{ hash, name string }

// readSums は SHA256SUMS.txt を読む（CRLF でも読む）。
func readSums(path string) ([]sumLine, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []sumLine
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" {
			continue
		}
		hash, name, ok := strings.Cut(line, "  ")
		if !ok {
			hash, name, _ = strings.Cut(line, " *")
		}
		out = append(out, sumLine{hash: hash, name: name})
	}
	return out, sc.Err()
}

// Check は gallery/*.png を SHA256SUMS.txt と比べ、続けて絵の値段を見る。
//
// WhyNot: 一覧に載っている名前だけを照らさない — 増えた絵を見逃す。名前の集合を先に比べて、増減も退行として落とす。
func Check(dir string, d Deps) int {
	sumsPath := filepath.Join(dir, filepath.FromSlash(sumsRel))
	if _, err := os.Stat(sumsPath); err != nil {
		fmt.Fprintf(d.Err, "リファレンス画像がまだありません: %s がありません。\n", sumsRel)
		fmt.Fprintf(d.Err, "いまの絵を基準にしてよければ make reference-update（bin/fge reference update）を実行してください。\n")
		return 1
	}
	actual, err := galleryPNGs(dir)
	if err != nil {
		fmt.Fprintf(d.Err, "error: gallery/ がありません。先に make render-all を実行してください\n")
		return 1
	}
	sums, err := readSums(sumsPath)
	if err != nil {
		fmt.Fprintf(d.Err, "error: %s を読めません: %v\n", sumsRel, err)
		return 1
	}
	want := map[string]bool{}
	for _, s := range sums {
		want[s.name] = true
	}
	have := map[string]bool{}
	for _, n := range actual {
		have[n] = true
	}
	var added, removed []string
	for _, n := range actual {
		if !want[n] {
			added = append(added, n)
		}
	}
	for n := range want {
		if !have[n] {
			removed = append(removed, n)
		}
	}
	sort.Strings(removed)
	if len(added) > 0 || len(removed) > 0 {
		fmt.Fprintln(d.Err, "reference-check NG: 絵の顔ぶれが変わりました")
		for _, n := range added {
			fmt.Fprintf(d.Err, "  増えた: %s\n", n)
		}
		for _, n := range removed {
			fmt.Fprintf(d.Err, "  消えた: %s\n", n)
		}
		fmt.Fprintln(d.Err, "  意図した変更なら make reference-update でリファレンス画像を更新してください。")
		return 1
	}
	failed := 0
	for _, s := range sums {
		got, err := sha256File(filepath.Join(dir, "gallery", s.name))
		if err != nil || got != s.hash {
			fmt.Fprintf(d.Out, "%s: FAILED\n", s.name)
			failed++
			continue
		}
		fmt.Fprintf(d.Out, "%s: OK\n", s.name)
	}
	if failed > 0 {
		fmt.Fprintf(d.Err, "reference-check NG: %d 枚がリファレンス画像と違います\n", failed)
		return 1
	}
	fmt.Fprintf(d.Out, "reference-check OK: %d 枚すべてリファレンス画像と一致しました\n", len(want))
	// WhyNot: 絵が一致したら終わりにしない — 絵が同じでも値段が変わっていることはある（box 列と 1 コマ 1 クアッドは画素が同一）。
	_ = d.Fge(dir, "render-cache", "prune", "--quiet")
	if err := d.Fge(dir, "check-render-budget", "."); err != nil {
		return 1
	}
	return 0
}

var (
	totalRe  = regexp.MustCompile(`total=([0-9]*)`)
	staticRe = regexp.MustCompile(`static=([0-9]*)`)
)

// Update はいまの gallery/*.png を reference/ に写し、SHA256SUMS.txt と絵の値段の基準 ITEMS.tsv を作り直す。
func Update(dir string, acceptBudget bool, d Deps) int {
	names, err := galleryPNGs(dir)
	if err != nil {
		fmt.Fprintf(d.Err, "error: gallery/ がありません。先に make render-all を実行してください\n")
		return 1
	}
	if len(names) == 0 {
		fmt.Fprintf(d.Err, "error: gallery/*.png が 1 枚もありません。先に make render-all を実行してください\n")
		return 1
	}
	refDir := filepath.Join(dir, "reference")
	if err := os.MkdirAll(refDir, 0o755); err != nil {
		fmt.Fprintf(d.Err, "error: %v\n", err)
		return 1
	}
	// WhyNot: 絵を写した後に値段を裁かない — 拒否した時に「PNG と SHA だけ新しく、基準の数だけ古い」割れた状態が残る。
	// 意図した増加は BUDGET=accept で明示する。
	if !acceptBudget {
		if err := d.Fge(dir, "check-render-budget", ".", "--gate", itemsRel); err != nil {
			return 1
		}
	}
	var sums strings.Builder
	for _, n := range names {
		src := filepath.Join(dir, "gallery", n)
		body, err := os.ReadFile(src)
		if err != nil {
			fmt.Fprintf(d.Err, "error: %v\n", err)
			return 1
		}
		if err := os.WriteFile(filepath.Join(refDir, n), body, 0o644); err != nil {
			fmt.Fprintf(d.Err, "error: %v\n", err)
			return 1
		}
		sum := sha256.Sum256(body)
		fmt.Fprintf(&sums, "%s  %s\n", hex.EncodeToString(sum[:]), n)
	}
	// WhyNot: reference/ へ手で置いた PNG（Studio のジャンルカードが読む title.png 等）を一覧に載せない —
	// check が gallery と名前の集合を突き合わせるので「消えた」扱いで必ず落ちる。
	if err := os.WriteFile(filepath.Join(dir, filepath.FromSlash(sumsRel)), []byte(sums.String()), 0o644); err != nil {
		fmt.Fprintf(d.Err, "error: %v\n", err)
		return 1
	}
	items := buildItems(dir, names)
	if err := os.WriteFile(filepath.Join(dir, filepath.FromSlash(itemsRel)), []byte(items), 0o644); err != nil {
		fmt.Fprintf(d.Err, "error: %v\n", err)
		return 1
	}
	fmt.Fprintf(d.Out, "updated: reference/*.png と reference/SHA256SUMS.txt を更新しました (%d 枚)\n", len(names))
	if items != "" {
		fmt.Fprintln(d.Out, "updated: reference/ITEMS.tsv（絵の値段の基準）も更新しました")
	}
	return 0
}

// buildItems は ITEMS.tsv の本文。行にするのは gallery にある PNG の名前で、記録（<名前>.items.tsv）がある物だけ。
// WhyNot: 改名で残ったサイドカーやシルエット（*_sil）の残骸を基準に混ぜない — 名前は gallery の PNG から引く。
func buildItems(dir string, names []string) string {
	var b strings.Builder
	for _, n := range names {
		base := strings.TrimSuffix(n, ".png")
		total, ok := firstNumber(filepath.Join(dir, "gallery", base+".items.tsv"), totalRe)
		if !ok {
			continue
		}
		static, sok := firstNumber(filepath.Join(dir, "gallery", base+".static.tsv"), staticRe)
		if !sok {
			static = 0
		}
		fmt.Fprintf(&b, "%s\tdynamic=%d\tstatic=%d\n", base, total-static, static)
	}
	return b.String()
}

func firstNumber(path string, re *regexp.Regexp) (int, bool) {
	body, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	m := re.FindSubmatch(body)
	if m == nil {
		return 0, true
	}
	n, _ := strconv.Atoi(string(m[1]))
	return n, true
}
