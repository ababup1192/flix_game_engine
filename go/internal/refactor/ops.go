package refactor

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/status"
)

// status は status の行の字（結末と diff・確かめの要約）。
func (o *Outcome) status() string {
	switch o.State {
	case StateDryRun:
		return fmt.Sprintf("dry-run（diff: %s・%d 行・%d ファイル）", rel(o.Diff), o.DiffLines, o.Files)
	case StateApplied:
		return fmt.Sprintf("applied（%s が %.0f s で通った・patch: %s）", o.Verify, o.VerifySecs, rel(o.Patch)) + o.dirtyNote()
	case StateReverted:
		s := fmt.Sprintf("reverted（%s が %.0f s で落ちたので patch を戻した・出力: %s）", o.Verify, o.VerifySecs, rel(o.VerifyLog))
		if o.FirstError != "" {
			s += "\n          最初の誤り: " + o.FirstError
		}
		if o.Reason != "" {
			s += "\n          戻し: " + o.Reason
		}
		return s + o.dirtyNote()
	case StateRevertFailed:
		s := fmt.Sprintf("revert-failed（%s が落ちたが、戻せないファイルが残った: %s）", o.Verify, strings.Join(o.Unrestored, "・"))
		if o.FirstError != "" {
			s += "\n          最初の誤り: " + o.FirstError
		}
		if o.Reason != "" {
			s += "\n          戻し: " + o.Reason
		}
		return s + o.dirtyNote()
	case StateRefused:
		return "refused（" + o.Reason + "）"
	case StateNothing:
		return "nothing（当てる所が無い）"
	}
	return o.State
}

func skipFlags(a args) string {
	var s []string
	for k := range a.skip {
		s = append(s, "--skip "+k)
	}
	return strings.Join(s, " ")
}

// nextOf は書き換える操作の next: dry-run なら --apply、戻したら直す所、断ったらその理由に合う手。
func nextOf(r *report, base string, a args, o *Outcome) {
	cmd := strings.TrimSpace(base + " " + skipFlags(a))
	switch o.State {
	case StateDryRun:
		r.Next, r.NextWhy = cmd+" --apply", "diff を読んでから"
	case StateRevertFailed:
		r.fixHint = "戻せなかったファイルを git diff で見て、" + rel(o.Patch) + " の分を手で戻す（git checkout -- <file> は書いた後の変更も消す）"
	case StateReverted:
		r.fixHint = "最初の誤りの所を --skip <file:line> で外すか、手で直してから --apply をやり直す"
		r.Next = cmd
		r.NextWhy = "--skip を足して dry-run から"
	case StateRefused:
		if strings.Contains(o.Reason, "索引が古い") {
			r.Next, r.NextWhy = "bin/fge refactor index --rebuild", "索引を作り直してからもう一度"
		} else {
			r.fixHint = "書き換える所の変更をコミットか stash してから --apply"
		}
	}
}

func expandReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	targets := matchTargets(idx.Rows)
	sym, err := Resolve(targets, a.target, map[string]bool{KindEnumDecl: true})
	if err != nil {
		return report{}, err
	}
	plan, err := PlanExpand(root, idx.Rows, sym, a.skip)
	if err != nil {
		return report{}, err
	}
	out := Change(root, plan.Edits, a.apply, cfg.Verify, o.Verify)
	r := report{Op: "expand-wildcard", Target: a.target, Sym: sym, code: CodeExpand, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = plan.Sites
	}
	sites := make([]Row, len(plan.Edits))
	for i, e := range plan.Edits {
		sites[i] = e.Site
		r.lines = append(r.lines, fmt.Sprintf("%-44s 書き出す  %s", e.Site.Where(), e.Site.Owner))
	}
	r.Sites = sites
	r.gotText = fmt.Sprintf("`_`・変数の腕を持つ match %d・書き出す %d・人へ回す %d", plan.Sites, len(plan.Edits), len(plan.Fix))
	r.wantText = fmt.Sprintf("%s への match に `case _` 0（書き出せない所は fix）", sym)
	for _, f := range plan.Fix {
		r.lines = append(r.lines, fmt.Sprintf("%-44s fix  %s（%s）", f.Where(), f.Why, f.Owner))
	}
	nextOf(&r, "bin/fge refactor expand-wildcard --enum "+a.target, a, &out)
	return r, nil
}

func deadReport(root string, idx *Index, a args, cfg Config, o Options) (report, error) {
	plan, err := PlanDead(root, idx.Rows, DeadQuery{WithTests: a.withTests, Only: a.only, TestDirs: cfg.TestDirs, Skip: a.skip, Engine: engineDir(root), Def: a.def, Library: IsLibrary(root, cfg)})
	if err != nil {
		return report{}, err
	}
	out := Change(root, plan.Edits, a.apply, cfg.VerifyTests, o.Verify)
	r := report{Op: "remove-dead", code: CodeRemoveDead, Outcome: &out, Fix: plan.Fix}
	r.got = len(plan.Fix)
	if out.State == StateReverted || out.State == StateRefused {
		r.got = plan.Sites
	}
	var sites []Fixed
	sites = append(append(sites, plan.Targets...), plan.Tests...)
	r.Sites = sites
	r.gotText = fmt.Sprintf("候補 %d（test-only %d・参照 0 %d）・消す def %d・一緒に消すテスト %d・人へ回す %d", plan.Sites, plan.TestOnly, plan.Sites-plan.TestOnly, len(plan.Targets), len(plan.Tests), len(plan.Fix))
	r.wantText = "テストからだけ・どこからも参照されない pub の def 0（決められない所は fix）"
	for _, t := range plan.Targets {
		r.lines = append(r.lines, fmt.Sprintf("%-44s 消す  %s（%s）", t.Where(), t.Sym, t.Why))
	}
	for _, t := range plan.Tests {
		r.lines = append(r.lines, fmt.Sprintf("%-44s 消す  %s（%s）", t.Where(), t.Sym, t.Why))
	}
	for _, f := range plan.Fix {
		r.lines = append(r.lines, fmt.Sprintf("%-44s fix   %s（%s）", f.Where(), f.Sym, f.Why))
	}
	base := "bin/fge refactor remove-dead"
	if a.withTests {
		base += " --with-tests"
	}
	if a.only != "" {
		base += " --only " + a.only
	}
	if a.def != "" {
		base += " --def " + a.def
	}
	nextOf(&r, base, a, &out)
	if out.State == StateDryRun && !a.withTests && len(plan.Targets) == 0 && len(plan.Fix) > 0 {
		r.Next, r.NextWhy = base+" --with-tests", "テストが参照する def はテストごと消す"
	}
	return r, nil
}

// engineDir は engine の根（mk/game.mk を持つ所）。見つからなければ ""。
func engineDir(root string) string {
	dir, _ := status.FindEngineDir(root, "mk/game.mk")
	return abs(root, dir)
}

// dirtyNote は確かめが残した変更（書く前に無かった git の変更）の 1 行。
func (o *Outcome) dirtyNote() string {
	if len(o.LeftDirty) == 0 {
		return ""
	}
	return "\n          確かめが残した変更（refactor は戻していない。生成物なら git checkout か消す）: " + strings.Join(o.LeftDirty, "・")
}

func rel(p string) string {
	if i := strings.Index(p, "build"+string(filepath.Separator)+"refactor"); i >= 0 {
		return p[i:]
	}
	return p
}
