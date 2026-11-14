package hugemethod

// OSR の諦めを拾う側。8,000 バイト未満でも、1 コマに 1 回しか呼ばれない関数の中のループは、
// JVM が途中から JIT（OSR）するのを「stack not empty」で諦めることがあり、class の大きさからは分からない。
// -XX:+PrintCompilation の出力を読んで、Flix の関数のうち OSR を諦めたまま一度も通らなかった物を知らせる。
//
//	fge-go osr-skipped <PrintCompilation の出力のファイル> ...   (- で標準入力)
//
// WhyNot: 諦めた行を全部知らせない — "retry at different tier" のとおり、別の tier で後から OSR が通る物がある。
//   同じメソッドの同じ位置（@ bci）に、諦めの付かない OSR の行が 1 つでもあれば通ったとみなす。
// WhyNot: 諦めの理由を stack の 2 つに絞る — "Jvmti state change" などは JFR を付けた時の JDK の都合で、ループの形とは関係ない。
// 除外は huge-methods.json の exempt に "モジュール.関数::osr-skipped"（1 コマに 1 回だけ回るループ・ベンチの外側のループ）。

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strings"
)

// OSRSuffix は除外の鍵の後ろ ("モジュール.関数::osr-skipped")。
const OSRSuffix = "osr-skipped"

// PrintCompilation の 1 行: 時刻・compile id・% (OSR)・tier・クラス::メソッド @ bci (大きさ) [理由]。
var osrLine = regexp.MustCompile(`^\s*\d+\s+(\d+)\s+%\S*\s+\d+\s+(\S+)::(\S+)\s+@\s+(\d+)\s+\(\d+ bytes\)(.*)$`)

var stackReasons = []string{"stack not empty at OSR entry point", "OSR starts with non-empty stack"}

// OSRSkip は OSR を諦めたまま通らなかったループ 1 つ (同じ関数の複製はまとめる)。
type OSRSkip struct {
	Name   string
	Reason string
	Copies int
}

// ScanOSR は PrintCompilation の出力を読み、Flix の関数のうち OSR を諦めたまま通らなかった物を返す。
func ScanOSR(r io.Reader) ([]OSRSkip, error) {
	type site struct{ class, bci string }
	type attempt struct {
		at      site
		skipped string
	}
	attempts := map[string]*attempt{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		m := osrLine.FindStringSubmatch(sc.Text())
		if m == nil {
			continue
		}
		id, at, rest := m[1], site{m[2], m[4]}, m[5]
		a := attempts[id]
		if a == nil {
			a = &attempt{at: at}
			attempts[id] = a
		}
		for _, why := range stackReasons {
			if strings.Contains(rest, "COMPILE SKIPPED: "+why) {
				a.skipped = why
			}
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	passed := map[site]bool{}
	for _, a := range attempts {
		if a.skipped == "" {
			passed[a.at] = true
		}
	}
	bySite := map[site]string{}
	for _, a := range attempts {
		if a.skipped != "" && !passed[a.at] {
			bySite[a.at] = a.skipped
		}
	}
	byName := map[string]*OSRSkip{}
	for at, why := range bySite {
		name, ok := FlixName(strings.ReplaceAll(at.class, ".", "/"))
		if !ok {
			continue
		}
		s := byName[name]
		if s == nil {
			s = &OSRSkip{Name: name, Reason: why}
			byName[name] = s
		}
		s.Copies++
	}
	out := make([]OSRSkip, 0, len(byName))
	for _, s := range byName {
		out = append(out, *s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// RunOSR は fge osr-skipped の本体。
func RunOSR(out, errOut *strings.Builder, root string, args []string) (int, error) {
	rules, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	if len(args) == 0 {
		return 2, fmt.Errorf("読む物がありません。JAVA_TOOL_OPTIONS=-XX:+PrintCompilation を付けて走らせた出力のファイル（- で標準入力）を渡してください")
	}
	var skips []OSRSkip
	lines := 0
	for _, in := range args {
		var r io.Reader = os.Stdin
		if in != "-" {
			f, err := os.Open(in)
			if err != nil {
				return 2, fmt.Errorf("読めません (%s): %v", in, err)
			}
			defer f.Close()
			r = f
		}
		got, err := ScanOSR(io.TeeReader(r, &lineCounter{n: &lines}))
		if err != nil {
			return 2, fmt.Errorf("読めません (%s): %v", in, err)
		}
		skips = append(skips, got...)
	}
	if lines == 0 {
		return 2, fmt.Errorf("出力が空です（PrintCompilation の旗が効いていないかもしれません）")
	}
	var bad []OSRSkip
	for _, s := range skips {
		if _, ok := rules.exempt.Why[s.Name+"::"+OSRSuffix]; !ok {
			bad = append(bad, s)
		}
	}
	if len(bad) == 0 {
		fmt.Fprintf(out, "[osr-skipped] OK (OSR を諦めたまま通らなかった Flix の関数 %d 件・うち除外 %d 件)\n", len(skips), len(skips)-len(bad))
		return 0, nil
	}
	for _, s := range bad {
		copies := ""
		if s.Copies > 1 {
			copies = fmt.Sprintf("・%d か所", s.Copies)
		}
		fmt.Fprintf(errOut, "!! %s のループは OSR を諦めたまま（%s%s）\n", s.Name, s.Reason, copies)
	}
	fmt.Fprintf(errOut, "[osr-skipped] %d 件。ループのラムダの中身を別の def に出して @DontInline を付ける（ラムダはその def を呼ぶだけにする。docs/performance.md の 13 節）。\n"+
		"  1 コマに 1 回だけ回る外側のループなら bin/lint-rules/huge-methods.json（ゲームは huge-methods.local.json）の exempt へ \"モジュール.関数::%s\" と理由 1 行\n",
		len(bad), OSRSuffix)
	return 1, nil
}

type lineCounter struct{ n *int }

func (c *lineCounter) Write(p []byte) (int, error) {
	*c.n += strings.Count(string(p), "\n")
	return len(p), nil
}
