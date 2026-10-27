package tickets

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

const ticketID = "20261018-120000_game_f100"

// localAt は機械のタイムゾーンの壁時計 wall を RFC3339 にする。
// WhyNot: 時差を書かない。チケットの ID の時刻も週の区切りも機械のタイムゾーンで読まれるので、+09:00 と書くと
// ほかのタイムゾーンの機械でチケットの前後や週がずれる。
func localAt(t *testing.T, wall string) string {
	t.Helper()
	at, err := time.ParseInLocation("2006-01-02T15:04:05", wall, time.Local)
	if err != nil {
		t.Fatal(err)
	}
	return at.Format(time.RFC3339)
}

// commitAt は時刻（機械のタイムゾーンの壁時計）を決めてコミットし、sha を返す。
func commitAt(t *testing.T, root, wall, msg string, files map[string]string) string {
	t.Helper()
	when := localAt(t, wall)
	for rel, body := range files {
		if err := os.WriteFile(filepath.Join(root, rel), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run := func(args ...string) string {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		cmd.Env = append(os.Environ(), "GIT_AUTHOR_DATE="+when, "GIT_COMMITTER_DATE="+when,
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	run("add", "-A")
	run("commit", "-q", "--no-verify", "-m", msg)
	return run("rev-parse", "HEAD")
}

func view(a, b string) string {
	return "mod View {\n    pub def draw(): Int32 =\n        " + a + "\n\n    pub def other(): Int32 =\n        " + b + "\n}\n"
}

// 同じ関数を触ったチケットの直し・同じファイルの別の関数・チケットの後のコミットを置いたリポ。
type history struct {
	root                            string
	causer, sameFile, after, fixSha string
}

func buildHistory(t *testing.T) history {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"src/View.flix": view("1", "1"),
		"debug/annotations/" + ticketID + "/README.md": "# 注釈\n\n- 場面: Fight\n\n## コメント\n\n枠が変\n",
	})
	lintconf.GitInit(t, root)
	h := history{root: root}
	commitAt(t, root, "2026-10-01T10:00:00", "init", nil)
	h.causer = commitAt(t, root, "2026-10-16T10:00:00", "draw の枠を直す（F8 のチケット）", map[string]string{"src/View.flix": view("2", "1")})
	h.sameFile = commitAt(t, root, "2026-10-17T10:00:00", "other を足す", map[string]string{"src/View.flix": view("2", "2")})
	h.after = commitAt(t, root, "2026-10-18T13:00:00", "チケットの後の draw", map[string]string{"src/View.flix": view("3", "2")})
	h.fixSha = commitAt(t, root, "2026-10-18T14:00:00", "draw の枠を戻す", map[string]string{"src/View.flix": view("4", "2")})
	return h
}

func runCmd(t *testing.T, root string, args ...string) (int, string, string) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		return 2, out.String(), err.Error()
	}
	return code, out.String(), errOut.String()
}

// 候補は「同じ関数を触ったチケットの直し」が high で先頭、同じファイルだけは low、チケットの後のコミットは出ない。
func TestSuspectsRankSameFunctionTicketFixFirst(t *testing.T) {
	h := buildHistory(t)
	r, err := LoadRules(h.root)
	if err != nil {
		t.Fatal(err)
	}
	tk, err := FindTicket(h.root, r, ticketID)
	if err != nil {
		t.Fatal(err)
	}
	ss, err := r.Suspects(h.root, h.fixSha, tk.Created)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, s := range ss {
		got = append(got, short(s.Commit)+":"+s.Confidence)
	}
	want := []string{short(h.causer) + ":high", short(h.sameFile) + ":low"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("候補 %v（%v のはず）", got, want)
	}
}

// close はフォルダを archive/ へ移し、 ledger に 1 行・close.json を置き、2 度目は --amend が無ければ止める。
func TestCloseMovesToArchiveAndRefusesSecondClose(t *testing.T) {
	h := buildHistory(t)
	code, _, msg := runCmd(t, h.root, "close", ticketID, "--fix", h.fixSha, "--regressed-by", short(h.causer))
	if code != 0 {
		t.Fatalf("close が %d: %s", code, msg)
	}
	r, _ := LoadRules(h.root)
	recs, _ := LoadLedger(h.root, r)
	_, statErr := os.Stat(filepath.Join(h.root, r.ArchiveDir, ticketID, "close.json"))
	again, _, _ := runCmd(t, h.root, "close", ticketID, "--fix", h.fixSha, "--regressed-by", "none")
	got := []any{len(recs), recs[0].RegressedBy.Kind, recs[0].RegressedBy.Ref, recs[0].Scene, statErr == nil, again}
	want := []any{1, KindCommit, h.causer, "Fight", true, 2}
	if b1, b2 := mustJSON(got), mustJSON(want); b1 != b2 {
		t.Errorf("got %s want %s", b1, b2)
	}
}

// AI が推した値は confidence が無ければ止め、--regressed-by を省くと候補を出して 1 で止まる。
func TestCloseNeedsConfidenceForAIAndShowsSuspectsWithoutRegressedBy(t *testing.T) {
	h := buildHistory(t)
	noConf, _, _ := runCmd(t, h.root, "close", ticketID, "--fix", h.fixSha, "--regressed-by", "none", "--by", "ai")
	ask, _, list := runCmd(t, h.root, "close", ticketID, "--fix", h.fixSha)
	got := []any{noConf, ask, strings.Contains(list, short(h.causer))}
	if b1, b2 := mustJSON(got), mustJSON([]any{2, 1, true}); b1 != b2 {
		t.Errorf("got %s want %s", b1, b2)
	}
}

// stats の割合: 埋まり = unknown でない数 / 閉じた数、生んだ割合 = 前の直し / 埋まった数。2 件生んだ直しは cause に出る。
func TestStatsRatiosAndCause(t *testing.T) {
	r := &Rules{Ledger: "l", FilledMin: 0.9, RegressedMax: 0.1, CauseMax: 1, Hints: map[string]string{}}
	rec := func(wall string, k Kind, ref string) Record {
		created := localAt(t, wall)
		return Record{Ticket: created, Created: created, RegressedBy: RegressedBy{Kind: k, Ref: ref}}
	}
	recs := []Record{
		rec("2026-10-13T10:00:00", KindCommit, "aaaa"),
		rec("2026-10-14T10:00:00", KindCommit, "aaaa"),
		rec("2026-10-19T10:00:00", KindNone, ""),
		rec("2026-10-19T11:00:00", KindUnknown, ""),
	}
	rep, err := r.BuildReport(recs, "", "", "week", 0)
	if err != nil {
		t.Fatal(err)
	}
	var codes []string
	for _, res := range rep.Results {
		codes = append(codes, res.Code+"="+res.Status.String())
	}
	got := []any{len(rep.Periods), rep.Total.FilledR, rep.Total.RegressR, len(rep.Causes[0].Tickets), codes}
	want := []any{2, 0.75, 0.667, 2, []string{"tickets.filled=fail", "tickets.regressed=fail", "tickets.cause=fail"}}
	if b1, b2 := mustJSON(got), mustJSON(want); b1 != b2 {
		t.Errorf("got %s want %s", b1, b2)
	}
}

func mustJSON(v any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}
