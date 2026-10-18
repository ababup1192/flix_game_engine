// Package tickets は F8 の注釈チケット（debug/annotations/<id>/）を閉じる・前の直しの候補を出す・数える。
//
//	fge tickets close <id|フォルダ> --fix <コミット> --regressed-by <コミット|ticket:<id>|none|unknown> [--by ai --confidence high|medium|low] [--why 1 行]
//	fge tickets suspects <id|フォルダ> [--fix <コミット>] [--json]
//	fge tickets stats [--since 2026-10-01] [--until 2026-10-31] [--by week|day|month] [--json]
//
// 閉じた記録は bin/lint-rules/tickets.json の ledger（git に入る JSONL）へ 1 行足す。
// WhyNot: close.json だけにしないのは、debug/ が git に入らず、数える元がマシンごとにばらけるため。
package tickets

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

// Name は規約ファイルの名前 (bin/lint-rules/<Name>.json)。
const Name = "tickets"

// Rules は規約データ。
type Rules struct {
	Note             string            `json:"note"`
	TicketsDir       string            `json:"ticketsDir"`
	ArchiveDir       string            `json:"archiveDir"`
	Ledger           string            `json:"ledger"`
	WindowDays       int               `json:"windowDays"`
	MaxSuspects      int               `json:"maxSuspects"`
	HubCommits       int               `json:"hubCommits"`
	TicketFixPattern string            `json:"ticketFixPattern"`
	FuncPatterns     map[string]string `json:"funcPatterns"`
	SceneKeys        []string          `json:"sceneKeys"`
	SkipPrefixes     []string          `json:"skipPrefixes"`
	FilledMin        float64           `json:"filledMin"`
	RegressedMax     float64           `json:"regressedMax"`
	CauseMax         float64           `json:"causeMax"`
	Hints            map[string]string `json:"hints"`

	funcRe    map[string]*regexp.Regexp
	ticketFix *regexp.Regexp
}

// LoadRules は規約を読む。
func LoadRules(root string) (*Rules, error) {
	var r Rules
	if _, err := lintconf.Load(root, Name, &r); err != nil {
		return nil, err
	}
	if r.TicketsDir == "" || r.ArchiveDir == "" || r.Ledger == "" || r.WindowDays <= 0 || r.MaxSuspects <= 0 || r.HubCommits <= 0 {
		return nil, fmt.Errorf("tickets.json には ticketsDir・archiveDir・ledger・windowDays・maxSuspects・hubCommits が要ります")
	}
	for _, c := range codes {
		if strings.TrimSpace(r.Hints[c.Name]) == "" {
			return nil, fmt.Errorf("tickets.json の hints に %s が要ります", c.Name)
		}
	}
	r.funcRe = map[string]*regexp.Regexp{}
	for ext, pat := range r.FuncPatterns {
		re, err := regexp.Compile(pat)
		if err != nil {
			return nil, fmt.Errorf("tickets.json の funcPatterns[%s] が壊れています: %v", ext, err)
		}
		r.funcRe[ext] = re
	}
	var err error
	if r.ticketFix, err = regexp.Compile(r.TicketFixPattern); err != nil {
		return nil, fmt.Errorf("tickets.json の ticketFixPattern が壊れています: %v", err)
	}
	return &r, nil
}

// Kind は regressedBy の種類。
type Kind string

const (
	KindCommit  Kind = "commit"  // 前の直しのコミットが生んだ
	KindTicket  Kind = "ticket"  // 前のチケットの直しが生んだ（コミットが分からない時）
	KindNone    Kind = "none"    // 前の直しとは関係ない（元からあった・新しく作った所）
	KindUnknown Kind = "unknown" // まだ決めていない・分からない
)

// RegressedBy は「このチケットはどの前の直しで生まれたか」。
type RegressedBy struct {
	Kind       Kind   `json:"kind"`
	Ref        string `json:"ref,omitempty"`        // コミットの sha（全桁）か チケットの id
	Subject    string `json:"subject,omitempty"`    // コミットの 1 行目（読む人のため）
	By         string `json:"by"`                   // human か ai
	Confidence string `json:"confidence,omitempty"` // ai の時: high・medium・low
	Why        string `json:"why,omitempty"`
}

// Record は ledger の 1 行（閉じたチケット 1 件）。
type Record struct {
	Ticket      string      `json:"ticket"`  // フォルダ名（作った時刻_題_f<frame>）
	Created     string      `json:"created"` // チケットを切った時刻（RFC 3339）
	Closed      string      `json:"closed"`
	Frame       int64       `json:"frame,omitempty"`
	Scene       string      `json:"scene,omitempty"`
	Comment     string      `json:"comment,omitempty"` // README のコメントの 1 行目
	Fix         []string    `json:"fix"`               // 直したコミット（全桁）
	RegressedBy RegressedBy `json:"regressedBy"`
	Local       bool        `json:"local"` // false はフォルダの無いまま（git の履歴から）書いた物
}

// IsRegression は前の直しが生んだと決まった物か。
func (r Record) IsRegression() bool {
	return r.RegressedBy.Kind == KindCommit || r.RegressedBy.Kind == KindTicket
}

// LoadLedger は ledger を読む。無ければ空。
func LoadLedger(root string, r *Rules) ([]Record, error) {
	f, err := os.Open(filepath.Join(root, r.Ledger))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []Record
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var rec Record
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			return nil, fmt.Errorf("%s:%d が JSON として壊れています: %v", r.Ledger, n, err)
		}
		out = append(out, rec)
	}
	return out, sc.Err()
}

// SaveLedger は ledger を作った時刻の順に書き直す。
func SaveLedger(root string, r *Rules, recs []Record) error {
	sort.SliceStable(recs, func(i, j int) bool {
		if recs[i].Created != recs[j].Created {
			return recs[i].Created < recs[j].Created
		}
		return recs[i].Ticket < recs[j].Ticket
	})
	var b strings.Builder
	for _, rec := range recs {
		line, err := json.Marshal(rec)
		if err != nil {
			return err
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	p := filepath.Join(root, r.Ledger)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	return os.WriteFile(p, []byte(b.String()), 0o644)
}

var idRe = regexp.MustCompile(`^(\d{8}-\d{6})_.*_f(\d+)$`)

// Ticket は 1 枚のチケットの読める所。
type Ticket struct {
	ID      string
	Dir     string // 根からの相対（無い時は ""）
	Created time.Time
	Frame   int64
	Scene   string
	Comment string
}

// FindTicket は id・id の頭・フォルダのパスからチケットを探す（開いている物 → archive の順）。
func FindTicket(root string, r *Rules, arg string) (Ticket, error) {
	arg = strings.TrimSuffix(filepath.ToSlash(arg), "/")
	var hits []string
	if st, err := os.Stat(filepath.Join(root, arg)); err == nil && st.IsDir() {
		hits = []string{arg}
	} else {
		for _, dir := range []string{r.TicketsDir, r.ArchiveDir} {
			ents, _ := os.ReadDir(filepath.Join(root, dir))
			for _, e := range ents {
				if e.IsDir() && strings.HasPrefix(e.Name(), arg) && idRe.MatchString(e.Name()) {
					hits = append(hits, dir+"/"+e.Name())
				}
			}
		}
	}
	switch len(hits) {
	case 0:
		return Ticket{}, fmt.Errorf("チケット %q が %s にも %s にもありません", arg, r.TicketsDir, r.ArchiveDir)
	case 1:
	default:
		return Ticket{}, fmt.Errorf("チケット %q に当たる物が %d 件あります（id をもう少し長く）: %s", arg, len(hits), strings.Join(hits, " "))
	}
	t, err := ParseID(filepath.Base(hits[0]))
	if err != nil {
		return Ticket{}, err
	}
	t.Dir = hits[0]
	t.Scene = readScene(filepath.Join(root, t.Dir), r.SceneKeys)
	t.Comment = readComment(filepath.Join(root, t.Dir, "README.md"))
	return t, nil
}

// ParseID はフォルダ名から作った時刻と frame を読む。
func ParseID(id string) (Ticket, error) {
	m := idRe.FindStringSubmatch(id)
	if m == nil {
		return Ticket{}, fmt.Errorf("チケットの id %q が「YYYYMMDD-HHMMSS_題_f<frame>」の形ではありません", id)
	}
	at, err := time.ParseInLocation("20060102-150405", m[1], time.Local)
	if err != nil {
		return Ticket{}, err
	}
	frame, _ := strconv.ParseInt(m[2], 10, 64)
	return Ticket{ID: id, Created: at, Frame: frame}, nil
}

// readScene は world.json の phase か、README の「- 場面: …」の行から場面を読む。
func readScene(dir string, keys []string) string {
	if body, err := os.ReadFile(filepath.Join(dir, "world.json")); err == nil {
		var w map[string]any
		if json.Unmarshal(body, &w) == nil {
			for _, k := range keys {
				if s, ok := w[k].(string); ok && s != "" {
					return s
				}
			}
		}
	}
	body, err := os.ReadFile(filepath.Join(dir, "README.md"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "-"))
		for _, k := range keys {
			for _, sep := range []string{":", "：", "|"} {
				if strings.HasPrefix(line, k+sep) || strings.HasPrefix(line, k+" "+sep) {
					return strings.TrimSpace(line[strings.Index(line, sep)+len(sep):])
				}
			}
		}
	}
	return ""
}

// readComment は README の「## コメント」の下の最初の行。
func readComment(readme string) string {
	body, err := os.ReadFile(readme)
	if err != nil {
		return ""
	}
	in := false
	for _, line := range strings.Split(string(body), "\n") {
		s := strings.TrimSpace(line)
		if strings.HasPrefix(s, "## ") {
			in = strings.Contains(s, "コメント")
			continue
		}
		if in && s != "" {
			return s
		}
	}
	return ""
}

// git は根で git を走らせ、標準出力を返す。
func git(root string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return "", fmt.Errorf("git %s: %s", strings.Join(args, " "), strings.TrimSpace(string(ee.Stderr)))
		}
		return "", err
	}
	return string(out), nil
}

// resolveCommit は短い sha や HEAD を全桁と 1 行目にする。
func resolveCommit(root, ref string) (sha, subject string, err error) {
	out, err := git(root, "log", "-1", "--format=%H%x09%s", ref+"^{commit}", "--")
	if err != nil {
		return "", "", fmt.Errorf("コミット %q が見つかりません", ref)
	}
	parts := strings.SplitN(strings.TrimSpace(out), "\t", 2)
	if len(parts) < 2 {
		return parts[0], "", nil
	}
	return parts[0], parts[1], nil
}

func short(sha string) string {
	if len(sha) > 8 {
		return sha[:8]
	}
	return sha
}

// clip は件名を人向けの表に収まる字数で切る。
func clip(s string, n int) string {
	rs := []rune(s)
	if len(rs) <= n {
		return s
	}
	return string(rs[:n]) + "…"
}
