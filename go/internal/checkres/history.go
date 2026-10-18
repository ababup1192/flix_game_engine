package checkres

// 周の記録: debug/history/<名前>/rN.check.json（Round）。px snap・snd snap が rounds snap の後に書き、
// 次の周がそれを読んで、前の周との差（delta）と止め時（stop）を出す。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// RoundFile は周 n の記録のパス。
func RoundFile(hist string, n int) string {
	return filepath.Join(hist, fmt.Sprintf("r%d.check.json", n))
}

// LoadHistory は r1 から r(n-1) までの記録を古い順に読む（無い周は飛ばす。--new で退けた周は数えない）。
func LoadHistory(hist string, n int) []Round {
	var out []Round
	for i := 1; i < n; i++ {
		data, err := os.ReadFile(RoundFile(hist, i))
		if err != nil {
			continue
		}
		var r Round
		if json.Unmarshal(data, &r) == nil {
			out = append(out, r)
		}
	}
	return out
}

// Snap は周 n の記録に前の周との差と止め時を入れて書き、人向けの行を返す。
func Snap(hist string, n int, cur Round, rules *Rules) (Round, string, error) {
	if !cur.Summary.Round {
		return cur, "", fmt.Errorf("周の外の検査（--only・--no-check）は周に積まない")
	}
	history := LoadHistory(hist, n)
	if len(history) > 0 {
		cur.Delta = Compare(history[len(history)-1].Results, cur.Results)
	}
	stop := JudgeStop(history, cur, rules)
	cur.Stop = &stop
	if err := os.WriteFile(RoundFile(hist, n), JSON(cur), 0o644); err != nil {
		return cur, "", err
	}
	var b strings.Builder
	prev := ""
	if len(history) > 0 {
		p := history[len(history)-1].Summary.Score
		prev = fmt.Sprintf("（前の周 %d → %+d）", p, cur.Summary.Score-p)
	}
	fmt.Fprintf(&b, "周 r%d の検査: score %d%s\n", n, cur.Summary.Score, prev)
	for _, l := range DeltaLines(cur.Delta, 5) {
		b.WriteString("  " + l + "\n")
	}
	for _, next := range cur.Summary.Next {
		fmt.Fprintf(&b, "  next: %s %s（%s）", next.Code, next.Where.Short(), next.Short())
		if len(next.Fix.Try) > 0 {
			b.WriteString(" 試す: " + next.Fix.Try[0].String())
		} else if next.Fix.Hint != "" {
			b.WriteString(" 直し: " + next.Fix.Hint)
		}
		b.WriteString("\n")
	}
	if n := cur.Summary.Near; n != nil {
		fmt.Fprintf(&b, "  near %d 件は fail が 0 になってから（%s）\n", n.Count, strings.Join(n.Codes, "・"))
	}
	verdict := "続ける"
	if stop.Stop {
		verdict = "止める"
	}
	fmt.Fprintf(&b, "  stop: %s（%s: %s）\n", verdict, stop.Rule, stop.Reason)
	return cur, b.String(), nil
}

// ParseTokens は --tokens の値（使った/予算。例 120000/400000）を読む。
func ParseTokens(s string) (*Tokens, error) {
	a, b, ok := strings.Cut(s, "/")
	used, err1 := strconv.Atoi(strings.TrimSpace(a))
	budget, err2 := strconv.Atoi(strings.TrimSpace(b))
	if !ok || err1 != nil || err2 != nil || used < 0 || budget <= 0 {
		return nil, fmt.Errorf("--tokens は 使った/予算 の整数で書く（例 120000/400000）")
	}
	return &Tokens{Used: used, Budget: budget}, nil
}
