package tickets

// suspects: 直したコミットが触った関数（無ければファイル）を、チケットを切る前の windowDays 日に
// 触ったコミットを並べる。決めるのは閉じる人で、ここは候補と confidence の目安を出すだけ。

import (
	"fmt"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Touch は 1 つのコミットが触った所（ファイル → 関数の名前の組。関数が読めない所は "" を入れる）。
type Touch map[string]map[string]bool

// Suspect は候補 1 件。
type Suspect struct {
	Commit     string   `json:"commit"`
	Date       string   `json:"date"`
	Subject    string   `json:"subject"`
	Files      []string `json:"files"`           // 直しと同じファイル
	Funcs      []string `json:"funcs,omitempty"` // 直しと同じ関数（ファイル::名前）
	TicketFix  bool     `json:"ticketFix"`       // そのコミット自身がチケットの直し
	Confidence string   `json:"confidence"`      // high・medium・low
}

var hunkRe = regexp.MustCompile(`^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@`)

type span struct{ start, count int }

type fileHunks struct {
	path     string
	old, new []span
}

// diffHunks は 1 コミットの -U0 の差分を、ファイルごとの古い側・新しい側の行の範囲にする。
func diffHunks(root, commit string) ([]fileHunks, error) {
	out, err := git(root, "show", "--format=", "-U0", "--no-color", "--no-renames", "--no-ext-diff", commit)
	if err != nil {
		return nil, err
	}
	var files []fileHunks
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "+++ "):
			p := strings.TrimPrefix(line, "+++ ")
			if p == "/dev/null" {
				continue
			}
			files[len(files)-1].path = strings.TrimPrefix(p, "b/")
		case strings.HasPrefix(line, "--- "):
			p := strings.TrimPrefix(line, "--- ")
			files = append(files, fileHunks{path: strings.TrimPrefix(p, "a/")})
		case strings.HasPrefix(line, "@@ "):
			m := hunkRe.FindStringSubmatch(line)
			if m == nil || len(files) == 0 {
				continue
			}
			f := &files[len(files)-1]
			f.old = append(f.old, span{atoi(m[1]), countOf(m[2])})
			f.new = append(f.new, span{atoi(m[3]), countOf(m[4])})
		}
	}
	return files, nil
}

func atoi(s string) int { n, _ := strconv.Atoi(s); return n }

func countOf(s string) int {
	if s == "" {
		return 1
	}
	return atoi(s)
}

// touchOf はコミットの触った関数を、古い側は親の版・新しい側はそのコミットの版で引く。
// only が nil でなければそのファイルだけ見る（候補のコミットが触った別のファイルの版は読まない）。
func (r *Rules) touchOf(root, commit string, only map[string]bool) (Touch, error) {
	hunks, err := diffHunks(root, commit)
	if err != nil {
		return nil, err
	}
	t := Touch{}
	for _, f := range hunks {
		if only != nil && !only[f.path] {
			continue
		}
		names := map[string]bool{}
		re := r.funcRe[filepath.Ext(f.path)]
		if re == nil {
			names[""] = true
		} else {
			for _, side := range []struct {
				rev   string
				spans []span
			}{{commit + "^", f.old}, {commit, f.new}} {
				body, err := git(root, "show", side.rev+":"+f.path)
				if err != nil {
					continue
				}
				lines := strings.Split(body, "\n")
				for _, s := range side.spans {
					last := s.start + s.count - 1
					if s.count == 0 {
						last = s.start
					}
					for n := s.start; n <= last; n++ {
						names[enclosing(lines, n, re)] = true
					}
				}
			}
		}
		t[f.path] = names
	}
	return t, nil
}

// enclosing は 1 始まりの行 n を含む関数の名前（上へ探して最初に当たる宣言）。無ければ ""。
func enclosing(lines []string, n int, re *regexp.Regexp) string {
	if n > len(lines) {
		n = len(lines)
	}
	for i := n - 1; i >= 0; i-- {
		if m := re.FindStringSubmatch(lines[i]); m != nil {
			return m[1]
		}
	}
	return ""
}

// Suspects は候補を confidence の高い順に返す。before はチケットを切った時刻（その後のコミットは生めない）。
func (r *Rules) Suspects(root, fix string, before time.Time) ([]Suspect, error) {
	fixT, err := r.touchOf(root, fix, nil)
	if err != nil {
		return nil, err
	}
	if len(fixT) == 0 {
		return nil, nil
	}
	var paths []string
	only := map[string]bool{}
	for p := range fixT {
		if lintconf.HasPrefixAny(p, r.SkipPrefixes) {
			continue
		}
		paths = append(paths, p)
		only[p] = true
	}
	if len(paths) == 0 {
		return nil, nil
	}
	sort.Strings(paths)
	since := before.AddDate(0, 0, -r.WindowDays)
	args := append([]string{"log", "--no-merges", "--format=%H%x09%aI%x09%s",
		"--since=" + since.Format(time.RFC3339), "--until=" + before.Format(time.RFC3339), fix + "^", "--"}, paths...)
	out, err := git(root, args...)
	if err != nil {
		return nil, err
	}
	var res []Suspect
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) < 3 {
			continue
		}
		t, err := r.touchOf(root, parts[0], only)
		if err != nil {
			return nil, err
		}
		s := Suspect{Commit: parts[0], Date: parts[1], Subject: parts[2], TicketFix: r.ticketFix.MatchString(parts[2])}
		for _, p := range paths {
			names, ok := t[p]
			if !ok {
				continue
			}
			s.Files = append(s.Files, p)
			for name := range fixT[p] {
				if name != "" && names[name] {
					s.Funcs = append(s.Funcs, p+"::"+name)
				}
			}
		}
		if len(s.Files) == 0 {
			continue
		}
		res = append(res, s)
	}
	// WhyNot: 場面の一覧や World の初期値のような、ほとんどのコミットが触る関数で high を付けないため、
	// 期間内に hubCommits を超える候補が触った関数は「同じ関数」に数えない。
	seen := map[string]int{}
	for _, s := range res {
		for _, f := range s.Funcs {
			seen[f]++
		}
	}
	for i := range res {
		var keep []string
		for _, f := range res[i].Funcs {
			if seen[f] <= r.HubCommits {
				keep = append(keep, f)
			}
		}
		sort.Strings(keep)
		res[i].Funcs = keep
		res[i].Confidence = confidenceOf(res[i])
	}
	rank := map[string]int{"high": 0, "medium": 1, "low": 2}
	sort.SliceStable(res, func(i, j int) bool {
		if rank[res[i].Confidence] != rank[res[j].Confidence] {
			return rank[res[i].Confidence] < rank[res[j].Confidence]
		}
		if len(res[i].Funcs) != len(res[j].Funcs) {
			return len(res[i].Funcs) > len(res[j].Funcs)
		}
		return res[i].Date > res[j].Date
	})
	if len(res) > r.MaxSuspects {
		res = res[:r.MaxSuspects]
	}
	return res, nil
}

// confidenceOf: 同じ関数を触ったチケットの直しは high・同じ関数だけなら medium・同じファイルだけなら low。
func confidenceOf(s Suspect) string {
	switch {
	case len(s.Funcs) > 0 && s.TicketFix:
		return "high"
	case len(s.Funcs) > 0:
		return "medium"
	default:
		return "low"
	}
}

// printSuspects は人向けの候補の表。
func printSuspects(b *strings.Builder, ss []Suspect) {
	if len(ss) == 0 {
		fmt.Fprintln(b, "  候補なし（同じファイルを触ったコミットが期間内に無い）→ --regressed-by none か unknown")
		return
	}
	for _, s := range ss {
		mark := ""
		if s.TicketFix {
			mark = "・チケットの直し"
		}
		where := strings.Join(s.Funcs, " ")
		if where == "" {
			where = strings.Join(s.Files, " ") + "（ファイルだけ）"
		}
		fmt.Fprintf(b, "  %-6s %s %s %s%s\n         %s\n", s.Confidence, short(s.Commit), s.Date[:10], clip(s.Subject, 60), mark, where)
	}
}
