package precommit

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ReferenceDrift は「描き出した絵がリファレンスと違うのに、そのままコミットする」を止める決まり。
// 無い（古い precommit.json）なら見ない。
type ReferenceDrift struct {
	// Affects は 1 つのゲーム（テンプレート）の中で、絵を変えうるファイル（ゲームの根からの相対で当てる）。
	Affects Matcher `json:"affects"`
	// EngineSources は engine の作業場で、どのテンプレートの絵も変えうるファイル。
	EngineSources Matcher `json:"engineSources"`
}

func (d ReferenceDrift) enabled() bool {
	return len(d.Affects.AnyOf)+len(d.Affects.Suffixes)+len(d.Affects.Prefixes) > 0
}

type refPair struct{ base, sums, gallery string }

// refPairs はゲームなら自分 1 組、engine の作業場なら templates/* の組。
func refPairs(root string) []refPair {
	if fileExists(filepath.Join(root, "reference", "SHA256SUMS.txt")) {
		return []refPair{{"", "reference/SHA256SUMS.txt", "gallery"}}
	}
	sums, _ := filepath.Glob(filepath.Join(root, "templates", "*", "reference", "SHA256SUMS.txt"))
	sort.Strings(sums)
	var out []refPair
	for _, s := range sums {
		rel, _ := filepath.Rel(root, filepath.Dir(filepath.Dir(s)))
		rel = filepath.ToSlash(rel)
		out = append(out, refPair{rel + "/", rel + "/reference/SHA256SUMS.txt", rel + "/gallery"})
	}
	return out
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

// checkReferenceDrift は、絵を変えうるファイルをコミットする時に、前のコミットより後に描き出した gallery が
// reference/SHA256SUMS.txt と違えば止める。SHA256SUMS.txt も同じコミットに入れていれば（make reference-update した = 意図した差のマーカー）通す。
//
// WhyNot: 描き出しをここで流さない — 1 本で数十秒〜数分かかり、コミットのたびには払えない。
// 前のコミットより後に描き出した gallery だけを見る（描き出していないなら何も言わない）。描いて差を見たのに入れる、を止める物。
func (r *runner) checkReferenceDrift(staged []string) []string {
	d := r.rules.ReferenceDrift
	if !d.enabled() {
		return nil
	}
	headTime := r.headCommitTime()
	engineTouched := len(selectPaths(staged, d.EngineSources)) > 0
	var problems []string
	for _, p := range refPairs(r.root) {
		if containsPath(staged, p.sums) {
			continue
		}
		touched := engineTouched
		for _, s := range staged {
			if rel, ok := strings.CutPrefix(s, p.base); ok && d.Affects.Match(rel) {
				touched = true
				break
			}
		}
		if !touched {
			continue
		}
		newest, bad, err := galleryDrift(filepath.Join(r.root, p.sums), filepath.Join(r.root, p.gallery))
		if err != nil || newest.IsZero() || len(bad) == 0 {
			continue
		}
		sumsInfo, err := os.Stat(filepath.Join(r.root, p.sums))
		if err != nil || !newest.After(sumsInfo.ModTime()) || !newest.After(headTime) {
			continue
		}
		name := strings.TrimSuffix(p.base, "/")
		if name == "" {
			name = "."
		}
		shown := bad
		more := ""
		if len(bad) > 4 {
			shown, more = bad[:4], fmt.Sprintf(" ほか %d 枚", len(bad)-4)
		}
		problems = append(problems, fmt.Sprintf("%s: 前のコミットの後に描き出した gallery がリファレンスと %d 枚違う（%s%s）", name, len(bad), strings.Join(shown, " "), more))
	}
	return problems
}

func (r *runner) headCommitTime() time.Time {
	out, err := exec.Command("git", "-C", r.root, "log", "-1", "--format=%ct").Output()
	if err != nil {
		return time.Time{}
	}
	sec, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err != nil {
		return time.Time{}
	}
	return time.Unix(sec, 0)
}

// galleryDrift は gallery の一番新しい PNG の時刻と、SHA256SUMS.txt と食い違う名前（足りない・余分・中身違い）を返す。
func galleryDrift(sumsPath, gallery string) (time.Time, []string, error) {
	f, err := os.Open(sumsPath)
	if err != nil {
		return time.Time{}, nil, err
	}
	defer f.Close()
	want := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) == 2 {
			want[strings.TrimPrefix(fields[1], "*")] = fields[0]
		}
	}
	pngs, _ := filepath.Glob(filepath.Join(gallery, "*.png"))
	if len(pngs) == 0 {
		return time.Time{}, nil, nil
	}
	var newest time.Time
	bad := map[string]bool{}
	seen := map[string]bool{}
	for _, p := range pngs {
		name := filepath.Base(p)
		seen[name] = true
		if info, err := os.Stat(p); err == nil && info.ModTime().After(newest) {
			newest = info.ModTime()
		}
		sum, ok := want[name]
		if !ok {
			bad[name] = true
			continue
		}
		if got, err := sha256Of(p); err != nil || got != sum {
			bad[name] = true
		}
	}
	for name := range want {
		if !seen[name] {
			bad[name] = true
		}
	}
	list := make([]string, 0, len(bad))
	for n := range bad {
		list = append(list, n)
	}
	sort.Strings(list)
	return newest, list, nil
}

func sha256Of(p string) (string, error) {
	f, err := os.Open(p)
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
