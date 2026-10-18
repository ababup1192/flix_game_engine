package tickets

// fge tickets の口: close・suspects・stats。

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

const usage = `使い方:
  fge tickets close <id|フォルダ> --fix <コミット>[,<コミット>] --regressed-by <コミット|ticket:<id>|none|unknown>
                    [--by ai --confidence high|medium|low] [--why "1 行"] [--amend] [--created 2026-10-18T15:32:00 --comment "1 行"]
      閉じた記録を ledger へ足し、フォルダを archive/ へ移して close.json を置く。--regressed-by を省くと候補を出して止まる。
      --amend は ledger にある記録を書き直す（後から regressedBy を付ける）。--created・--comment はフォルダの無いチケット（git の履歴から）用。
  fge tickets suspects <id|フォルダ> [--fix <コミット>] [--created …] [--json]
      直したコミットが触った関数を、チケットを切る前の windowDays 日に触ったコミット（regressedBy の候補）
  fge tickets stats [--since 2026-10-01] [--until 2026-10-31] [--by week|day|month] [--json]
      期間ごとの件数・regressedBy の埋まった割合・前の直しが生んだ割合・多く生んだ直し（checkres の形）`

// Run は fge tickets の本体。
func Run(out, errOut *strings.Builder, root string, args []string) (int, error) {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		fmt.Fprintln(out, usage)
		return 0, nil
	}
	r, err := LoadRules(root)
	if err != nil {
		return 2, err
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "close":
		return r.runClose(out, errOut, root, rest)
	case "suspects":
		return r.runSuspects(out, errOut, root, rest)
	case "stats":
		return r.runStats(out, root, rest)
	}
	fmt.Fprintln(errOut, usage)
	return 2, nil
}

// splitArgs は位置引数とフラグを分ける（flag はフラグの後の位置引数で止まるため）。
func splitArgs(fs *flag.FlagSet, args []string) ([]string, error) {
	var pos, flags []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if !strings.HasPrefix(a, "--") {
			pos = append(pos, a)
			continue
		}
		flags = append(flags, a)
		name := strings.TrimLeft(strings.SplitN(a, "=", 2)[0], "-")
		if f := fs.Lookup(name); f != nil && !strings.Contains(a, "=") {
			if bf, ok := f.Value.(interface{ IsBoolFlag() bool }); !ok || !bf.IsBoolFlag() {
				if i+1 < len(args) {
					flags = append(flags, args[i+1])
					i++
				}
			}
		}
	}
	return pos, fs.Parse(flags)
}

func newFlags(name string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return fs
}

// ticketOf は位置引数のチケットを探す。フォルダが無く --created があれば、id をそのまま使う。
func (r *Rules) ticketOf(root, arg, created string) (Ticket, error) {
	t, err := FindTicket(root, r, arg)
	if err == nil {
		return t, nil
	}
	if created == "" {
		return Ticket{}, err
	}
	at, perr := time.ParseInLocation("2006-01-02T15:04:05", created, time.Local)
	if perr != nil {
		if at, perr = time.Parse(time.RFC3339, created); perr != nil {
			return Ticket{}, fmt.Errorf("--created %q は 2006-01-02T15:04:05 の形で書きます", created)
		}
	}
	if strings.ContainsAny(arg, " /\t") {
		return Ticket{}, fmt.Errorf("フォルダの無いチケットの id %q に空白や / は使えません", arg)
	}
	if p, perr := ParseID(arg); perr == nil {
		t = p
	}
	t.ID, t.Created = arg, at
	return t, nil
}

var shaLike = regexp.MustCompile(`^[0-9a-f]{7,40}$`)

// parseRegressedBy は --regressed-by の値を読む。
func parseRegressedBy(root, v, by, confidence, why string) (RegressedBy, error) {
	rb := RegressedBy{By: by, Confidence: confidence, Why: why}
	if by != "human" && by != "ai" {
		return rb, fmt.Errorf("--by は human か ai です")
	}
	if by == "ai" && confidence == "" {
		return rb, fmt.Errorf("--by ai の時は --confidence high|medium|low を付けます（決めた人と推した物を数で分けるため）")
	}
	if confidence != "" && confidence != "high" && confidence != "medium" && confidence != "low" {
		return rb, fmt.Errorf("--confidence は high・medium・low のどれかです")
	}
	switch {
	case v == "none" || v == "unknown":
		rb.Kind = Kind(v)
	case strings.HasPrefix(v, "ticket:"):
		rb.Kind, rb.Ref = KindTicket, strings.TrimPrefix(v, "ticket:")
		if rb.Ref == "" {
			return rb, fmt.Errorf("ticket: の後にチケットの id を書きます")
		}
	default:
		sha, subject, err := resolveCommit(root, v)
		if err != nil {
			return rb, fmt.Errorf("--regressed-by %q: %v（コミット・ticket:<id>・none・unknown のどれか）", v, err)
		}
		if !shaLike.MatchString(v) && v != "HEAD" && !strings.HasPrefix(v, "HEAD") {
			return rb, fmt.Errorf("--regressed-by %q は枝の名前に見えます。コミットの sha で書きます", v)
		}
		rb.Kind, rb.Ref, rb.Subject = KindCommit, sha, subject
	}
	return rb, nil
}

func (r *Rules) runClose(out, errOut *strings.Builder, root string, args []string) (int, error) {
	fs := newFlags("close")
	fix := fs.String("fix", "", "")
	reg := fs.String("regressed-by", "", "")
	by := fs.String("by", "human", "")
	conf := fs.String("confidence", "", "")
	why := fs.String("why", "", "")
	created := fs.String("created", "", "")
	comment := fs.String("comment", "", "")
	amend := fs.Bool("amend", false, "")
	pos, err := splitArgs(fs, args)
	if err != nil || len(pos) != 1 {
		fmt.Fprintln(errOut, usage)
		return 2, err
	}
	recs, err := LoadLedger(root, r)
	if err != nil {
		return 2, err
	}
	if *created == "" {
		for _, rec := range recs {
			if rec.Ticket == pos[0] && !rec.Local {
				*created = rec.Created
			}
		}
	}
	t, err := r.ticketOf(root, pos[0], *created)
	if err != nil {
		return 2, err
	}
	at := -1
	for i, rec := range recs {
		if rec.Ticket == t.ID {
			at = i
		}
	}
	if at >= 0 && !*amend {
		return 2, fmt.Errorf("%s はもう ledger にあります（書き直すなら --amend）", t.ID)
	}
	var fixes []string
	if *fix == "" && at >= 0 {
		fixes = recs[at].Fix
	}
	for _, f := range strings.Split(*fix, ",") {
		if f = strings.TrimSpace(f); f == "" {
			continue
		}
		sha, _, err := resolveCommit(root, f)
		if err != nil {
			return 2, err
		}
		fixes = append(fixes, sha)
	}
	if len(fixes) == 0 {
		return 2, fmt.Errorf("--fix に直したコミットを書きます（直さずに閉じる時も、閉じた判断のコミット）")
	}
	if *reg == "" {
		fmt.Fprintf(errOut, "%s: --regressed-by がありません。候補（決めるのは閉じる人）:\n", t.ID)
		ss, err := r.Suspects(root, fixes[0], t.Created)
		if err != nil {
			return 2, err
		}
		printSuspects(errOut, ss)
		fmt.Fprintf(errOut, "→ bin/fge tickets close %s --fix %s --regressed-by <コミット|ticket:<id>|none|unknown>\n", pos[0], short(fixes[0]))
		return 1, nil
	}
	rb, err := parseRegressedBy(root, *reg, *by, *conf, *why)
	if err != nil {
		return 2, err
	}
	rec := Record{Ticket: t.ID, Created: t.Created.Format(time.RFC3339), Closed: time.Now().Format(time.RFC3339),
		Frame: t.Frame, Scene: t.Scene, Comment: t.Comment, Fix: fixes, RegressedBy: rb, Local: t.Dir != ""}
	if rec.Comment == "" {
		rec.Comment = *comment
	}
	// WhyNot: フォルダの無いチケットは後から履歴で書くので、今の時刻ではなく直したコミットの時刻を閉じた時刻にする。
	if !rec.Local {
		if out, err := git(root, "log", "-1", "--format=%cI", fixes[0]); err == nil {
			rec.Closed = strings.TrimSpace(out)
		}
	}
	if at >= 0 {
		old := recs[at]
		rec.Closed = old.Closed
		if !rec.Local {
			rec.Local, rec.Frame, rec.Scene = old.Local, old.Frame, old.Scene
			if rec.Comment == "" {
				rec.Comment = old.Comment
			}
		}
		recs[at] = rec
	} else {
		recs = append(recs, rec)
	}
	if t.Dir != "" && !strings.HasPrefix(t.Dir, r.ArchiveDir+"/") {
		dst := r.ArchiveDir + "/" + t.ID
		if err := os.MkdirAll(filepath.Join(root, r.ArchiveDir), 0o755); err != nil {
			return 2, err
		}
		if err := os.Rename(filepath.Join(root, t.Dir), filepath.Join(root, dst)); err != nil {
			return 2, err
		}
		t.Dir = dst
	}
	if t.Dir != "" {
		body, _ := json.MarshalIndent(rec, "", "  ")
		if err := os.WriteFile(filepath.Join(root, t.Dir, "close.json"), append(body, '\n'), 0o644); err != nil {
			return 2, err
		}
	}
	if err := SaveLedger(root, r, recs); err != nil {
		return 2, err
	}
	what := string(rb.Kind)
	if rb.Ref != "" {
		what += " " + short(rb.Ref) + " " + clip(rb.Subject, 48)
	}
	fmt.Fprintf(out, "[tickets close] %s・直し %s・regressedBy %s → %s", t.ID, short(fixes[0]), what, r.Ledger)
	if t.Dir != "" {
		fmt.Fprintf(out, "・%s", t.Dir)
	}
	fmt.Fprintln(out, "（ledger はコミットに含める）")
	return 0, nil
}

func (r *Rules) runSuspects(out, errOut *strings.Builder, root string, args []string) (int, error) {
	fs := newFlags("suspects")
	fix := fs.String("fix", "HEAD", "")
	created := fs.String("created", "", "")
	asJSON := fs.Bool("json", false, "")
	pos, err := splitArgs(fs, args)
	if err != nil || len(pos) != 1 {
		fmt.Fprintln(errOut, usage)
		return 2, err
	}
	t, err := r.ticketOf(root, pos[0], *created)
	if err != nil {
		return 2, err
	}
	sha, subject, err := resolveCommit(root, *fix)
	if err != nil {
		return 2, err
	}
	ss, err := r.Suspects(root, sha, t.Created)
	if err != nil {
		return 2, err
	}
	if *asJSON {
		if ss == nil {
			ss = []Suspect{}
		}
		out.Write(checkres.Compact(map[string]any{"ticket": t.ID, "created": t.Created.Format(time.RFC3339),
			"frame": t.Frame, "scene": t.Scene, "fix": sha, "windowDays": r.WindowDays, "suspects": ss}))
		return 0, nil
	}
	fmt.Fprintf(out, "[tickets suspects] %s（frame %d・場面 %s・%s）\n  直し %s %s・%d 日前から\n",
		t.ID, t.Frame, orDash(t.Scene), t.Created.Format("2006-01-02 15:04"), short(sha), subject, r.WindowDays)
	if t.Comment != "" {
		fmt.Fprintf(out, "  コメント: %s\n", t.Comment)
	}
	printSuspects(out, ss)
	return 0, nil
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func (r *Rules) runStats(out *strings.Builder, root string, args []string) (int, error) {
	fs := newFlags("stats")
	since := fs.String("since", "", "")
	until := fs.String("until", "", "")
	by := fs.String("by", "week", "")
	asJSON := fs.Bool("json", false, "")
	if _, err := splitArgs(fs, args); err != nil {
		return 2, err
	}
	if *by != "week" && *by != "day" && *by != "month" {
		return 2, fmt.Errorf("--by は week・day・month のどれかです")
	}
	recs, err := LoadLedger(root, r)
	if err != nil {
		return 2, err
	}
	open := 0
	ents, _ := os.ReadDir(filepath.Join(root, r.TicketsDir))
	for _, e := range ents {
		if e.IsDir() && idRe.MatchString(e.Name()) {
			open++
		}
	}
	rep, err := r.BuildReport(recs, *since, *until, *by, open)
	if err != nil {
		return 2, err
	}
	if *asJSON {
		out.Write(checkres.Compact(rep))
		return 0, nil
	}
	PrintReport(out, rep)
	return 0, nil
}
