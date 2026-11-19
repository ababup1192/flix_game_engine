package testselect

// 答え合わせ（plans/test-selection.md の 6 節・12.8）の数え方。木を作る・make を流すのは main 側（cmd_testselect_replay.go）。

import (
	"regexp"
	"sort"
	"strings"
)

var (
	testLine     = regexp.MustCompile(`(?m)^\[test\] (PASS|FAIL) (\S+)\s*$`)
	checkPkgsRed = regexp.MustCompile(`(?m)^\[check-pkgs\] 赤:(.*)$`)
)

// ParseTestLines は make test（JOBS が 2 以上）の「[test] PASS|FAIL <フォルダ>」をパッケージ id → 緑か にする。
func ParseTestLines(out string) map[string]bool {
	res := map[string]bool{}
	for _, m := range testLine.FindAllStringSubmatch(out, -1) {
		res[PkgOfTestDir(m[2])] = m[1] == "PASS"
	}
	return res
}

// PkgOfTestDir は make test が出すフォルダ（.layers/<層>・templates/<名前>・bench/<名前>・engine）をパッケージ id にする。
func PkgOfTestDir(dir string) string {
	dir = strings.TrimSuffix(dir, "/")
	for _, p := range []string{".layers/", "templates/", "bench/"} {
		if rest, ok := strings.CutPrefix(dir, p); ok {
			return rest
		}
	}
	return dir
}

// ParseCheckPkgsRed は make check-pkgs の「[check-pkgs] 赤: <フォルダ…>」のフォルダ。
func ParseCheckPkgsRed(out string) []string {
	var dirs []string
	for _, m := range checkPkgsRed.FindAllStringSubmatch(out, -1) {
		dirs = append(dirs, strings.Fields(m[1])...)
	}
	return dirs
}

// IsRevertSource は red（6.1 の 2: src を戻す）で C^ に戻すファイルか（テストでない .flix）。
func IsRevertSource(p string) bool {
	if !strings.HasSuffix(p, ".flix") {
		return false
	}
	for _, part := range strings.Split(p, "/") {
		if part == "test" || part == "sample-test" {
			return false
		}
	}
	return true
}

// JudgeInput は 1 本のコミットの全量と選んだ物の結果（パッケージ id の集まり）。
type JudgeInput struct {
	// FullTestFail・FullCheckFail は全量で 2 回とも赤だった物（test を持つ・check だけの物）。
	FullTestFail, FullCheckFail map[string]bool
	// SelectedTest・SelectedCheck は選んだ make test の PKGS と make check-pkgs の DIRS のパッケージ。
	SelectedTest, SelectedCheck map[string]bool
	// SelectedRed は選んだ物を流して赤だったパッケージ（test・check-pkgs）。TypeRed は選んだ型検査の門（check・sync-engine-full）の赤が覆うパッケージ。
	SelectedRed, TypeRed map[string]bool
	// AllTest・AllCheck は全量で流すパッケージ（倒れたかを決める）。
	AllTest, AllCheck map[string]bool
}

// Verdict は 6.2 の数え方の答え。
type Verdict struct {
	// Missed は拾い漏れ（全量で赤・選んだ物で流さず型検査でも赤にならない）。
	Missed []string `json:"missed"`
	// BySelect は選んで流して拾った物、ByType は選んだ型検査で拾った物。
	BySelect []string `json:"bySelect"`
	ByType   []string `json:"byType"`
	// Mismatch は選んで流したのに全量と答えが違った物（木の作り・cwd・build/ の残りを疑う）。
	Mismatch []string `json:"mismatch"`
	// FellBack は選んだ物が全量と同じ（安全側に倒れた）。
	FellBack bool `json:"fellBack"`
}

// Judge は全量と選んだ物を突き合わせる。
func Judge(in JudgeInput) Verdict {
	var v Verdict
	for _, id := range sortedKeys(in.FullTestFail) {
		switch {
		case in.SelectedTest[id] && in.SelectedRed[id]:
			v.BySelect = append(v.BySelect, id)
		case in.SelectedTest[id]:
			v.Mismatch = append(v.Mismatch, id)
		case in.TypeRed[id] || (in.SelectedCheck[id] && in.SelectedRed[id]):
			v.ByType = append(v.ByType, id)
		default:
			v.Missed = append(v.Missed, id)
		}
	}
	for _, id := range sortedKeys(in.FullCheckFail) {
		switch {
		case in.TypeRed[id] || ((in.SelectedCheck[id] || in.SelectedTest[id]) && in.SelectedRed[id]):
			v.ByType = append(v.ByType, id)
		case in.SelectedCheck[id] || in.SelectedTest[id]:
			v.Mismatch = append(v.Mismatch, id)
		default:
			v.Missed = append(v.Missed, id)
		}
	}
	for _, id := range sortedKeys(in.SelectedRed) {
		if !in.FullTestFail[id] && !in.FullCheckFail[id] {
			v.Mismatch = append(v.Mismatch, id)
		}
	}
	sort.Strings(v.Mismatch)
	v.FellBack = covers(in.SelectedTest, in.AllTest) && covers(in.SelectedCheck, in.AllCheck)
	return v
}

func covers(have, want map[string]bool) bool {
	for id := range want {
		if !have[id] {
			return false
		}
	}
	return true
}
