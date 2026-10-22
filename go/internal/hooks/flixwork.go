package hooks

// hook-flix-work — 作業の区切り（Stop / SubagentStop）で Flix を型検査する。
//
// このセッションが触った .flix を持つパッケージだけを集めて check の常駐（flixlint。bin/fge checkd）で
// 検査し、NG が出れば exit 2 で Claude に差し戻す。「緑と自己申告したが
// 実は赤」を防ぐのが検査を残す理由。
//
// WhyNot: 保存のたび（PostToolUse）に走らせないのは、サブエージェントを並列に
// 走らせると保存が秒間何度も届き、常駐 (JVM) が増殖して機械が重くなるため。
// 編集の途中の型エラーまで拾ってノイズになる問題もある。

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/explainerror"
)

// RunFlixWork は差し戻しが要るかを見る。返すのは 0 か 2 だけ。
func RunFlixWork(errOut io.Writer, root string, in io.Reader) int {
	t0 := time.Now()
	payload, _ := ReadPayload(in)
	// WhyNot: 直前の Stop hook のブロックで継続ターンに入っているときに引くのは、
	// 直せない種類の赤（他セッションが編集中等）で永久に止まれなくなるため。
	if payload.Bool("stop_hook_active") {
		return 0
	}
	r, err := LoadRules(root)
	if err != nil {
		fmt.Fprintf(errOut, "# hook-flix-work: %v\n", err)
		return 2
	}
	rules, err := explainerror.LoadRules(root)
	if err != nil {
		fmt.Fprintf(errOut, "# hook-flix-work: %v\n", err)
		return 2
	}
	session := payload.SessionID()
	if root == "" || !isDir(filepath.Join(root, ".git")) {
		return 0
	}
	files := changedFlixFiles(r, root)
	if len(files) == 0 {
		return 0
	}

	var failures []string
	groups := groupByPkg(r, files)
	for _, pkg := range sortedKeys(groups) {
		pkgFiles := groups[pkg]
		if !touchedBySession(r, pkg, session) {
			continue // 他セッションが編集中のパッケージ。検査すらしない
		}
		sig, proseOnly, ok := pkgDiffSignature(r, root, pkgFiles)
		if !ok {
			continue // 差分が読めない → 無理に検査しない
		}
		if sig == readStopState(r, pkg) {
			continue // 前回検査した時点から変わっていない
		}
		if proseOnly {
			writeStopState(r, pkg, sig)
			continue // コメント・空行だけの差分は型検査の対象にならない
		}
		code, out, ok := checkPkg(r, root, pkg)
		if !ok {
			continue // 常駐が温まっていない。起動だけ予約し、次の区切りで効く
		}
		if code < 0 {
			continue // 常駐が「素の CLI で確かめて」と言っている。ここでは待たない
		}
		writeStopState(r, pkg, sig) // 検査は実施した (緑・赤いずれも記録)
		if code == 0 {
			continue
		}
		block := explainerror.FirstErrorBlock(rules, out,
			*r.Checkd.ErrorBlockMaxLines, *r.Checkd.TailLinesWhenNoBlock)
		msg := fmt.Sprintf("# hook-flix-work: %s で型検査 NG\n%s", filepath.Base(pkg), block)
		if tip := explainerror.Prescribe(rules, block); tip != "" {
			msg += "\n" + fmt.Sprintf(rules.TipFormat, tip)
		}
		failures = append(failures, msg)
	}
	if len(failures) == 0 {
		return 0
	}
	fmt.Fprintf(errOut, "%s\n\n(計 %.1fs)\n",
		strings.Join(failures, "\n\n"), time.Since(t0).Seconds())
	return 2
}

// checkPkg は check の常駐（flixlint）が居る時だけ `fge checkd <pkg>` を流して (終了コード, 出力) を返す。居なければ
// 起動予約をして ok=false（温まっていない常駐を作業の区切りで待たない）。時間切れも ok=false。
func checkPkg(r *Rules, root, pkg string) (int, string, bool) {
	if !DaemonAlive(r, pkg) {
		ReserveDaemon(r, root, pkg)
		return 0, "", false
	}
	self, err := os.Executable()
	if err != nil {
		return 0, "", false
	}
	cmd := exec.Command(self, "checkd", pkg)
	cmd.Dir = pkg
	var out strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		return 0, "", false
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
		return cmd.ProcessState.ExitCode(), out.String(), true
	case <-time.After(seconds(*r.Checkd.CheckTimeoutSec)):
		_ = cmd.Process.Kill()
		<-done
		return 0, "", false
	}
}

// git は git を走らせて標準出力を返す。失敗は ok=false（例外にしない）。
// WhyNot: 終了コード 1 を失敗にしないのは、git diff が差分ありで 1 を返すため。
func git(r *Rules, root string, args ...string) (string, bool) {
	cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
	var out strings.Builder
	cmd.Stdout = &out
	done := make(chan error, 1)
	if err := cmd.Start(); err != nil {
		return "", false
	}
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			if code := cmd.ProcessState.ExitCode(); code != 1 {
				return "", false
			}
		}
	case <-time.After(seconds(*r.Checkd.GitTimeoutSec)):
		_ = cmd.Process.Kill()
		return "", false
	}
	return out.String(), true
}

// changedFlixFiles は作業ツリーで変わっている .flix の絶対パス（追跡分 + 未追跡分）。
func changedFlixFiles(r *Rules, root string) []string {
	seen := map[string]bool{}
	for _, args := range [][]string{
		{"diff", "--name-only", "HEAD", "--", "*.flix"},
		{"ls-files", "--others", "--exclude-standard", "--", "*.flix"},
	} {
		if out, ok := git(r, root, args...); ok {
			for _, rel := range strings.Split(out, "\n") {
				if rel != "" {
					seen[filepath.Join(root, rel)] = true
				}
			}
		}
	}
	return sortedSet(seen)
}

func groupByPkg(r *Rules, files []string) map[string][]string {
	groups := map[string][]string{}
	for _, f := range files {
		if pkg := FindPkg(r, f); pkg != "" {
			groups[pkg] = append(groups[pkg], f)
		}
	}
	return groups
}

// touchedBySession はこのセッションが hook-flix-touch で印を付けたパッケージか。
// WhyNot: session_id が取れないときに「分からない」ではなく「触っていない」に
// 倒すのは、他人の赤で止める方が自分の赤を見逃すより害が大きいため。
func touchedBySession(r *Rules, pkg, session string) bool {
	if session == "" {
		return false
	}
	return isFile(filepath.Join(StateDir(r, pkg), "touched-"+SessionHash(r, session)))
}

// pkgDiffSignature は (署名, 差分がコメント・空行だけか, 読めたか) を返す。
// 署名は「今のパッケージの状態」を表す文字列で、前回と同じなら検査を省ける。
func pkgDiffSignature(r *Rules, root string, files []string) (string, bool, bool) {
	rels := make([]string, 0, len(files))
	for _, f := range files {
		rel, err := filepath.Rel(root, f)
		if err != nil {
			return "", false, false
		}
		rels = append(rels, rel)
	}
	diffText, ok := git(r, root, append([]string{"diff", "-U0", "HEAD", "--"}, rels...)...)
	if !ok {
		return "", false, false
	}

	prose := true
	for _, line := range strings.Split(diffText, "\n") {
		if strings.HasPrefix(line, "+++") || strings.HasPrefix(line, "---") ||
			hasAnyPrefix(line, r.Checkd.CommentOnlyPrefixes) {
			continue
		}
		if strings.HasPrefix(line, "+") || strings.HasPrefix(line, "-") {
			if !isProse(r, line[1:]) {
				prose = false
			}
		}
	}

	h := sha1.New()
	h.Write([]byte(diffText))
	// WhyNot: git diff だけを署名にしないのは、未追跡の新規ファイルを見ないため。
	untrackedOut, ok := git(r, root, append([]string{"ls-files", "--others", "--exclude-standard", "--"}, rels...)...)
	untracked := map[string]bool{}
	if ok {
		for _, rel := range strings.Split(untrackedOut, "\n") {
			if rel != "" {
				untracked[rel] = true
			}
		}
	}
	for _, rel := range sortedSet(untracked) {
		body, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			prose = false
			continue
		}
		h.Write([]byte{0})
		h.Write([]byte(rel))
		h.Write([]byte{0})
		h.Write(body)
		for _, line := range strings.Split(string(body), "\n") {
			if !isProse(r, line) {
				prose = false
			}
		}
	}
	return hex.EncodeToString(h.Sum(nil)), prose, true
}

// isProse はコメント行または空行か（jargon の判定基準と同じ）。
func isProse(r *Rules, text string) bool {
	t := strings.TrimSpace(text)
	return t == "" || strings.HasPrefix(t, *r.Checkd.CommentMark)
}

func hasAnyPrefix(s string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

func stopStatePath(r *Rules, pkg string) string {
	return filepath.Join(StateDir(r, pkg), "stop-hash")
}

func readStopState(r *Rules, pkg string) string {
	raw, err := os.ReadFile(stopStatePath(r, pkg))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

func writeStopState(r *Rules, pkg, sig string) {
	if err := os.MkdirAll(StateDir(r, pkg), 0o755); err != nil {
		return
	}
	_ = os.WriteFile(stopStatePath(r, pkg), []byte(sig), 0o644)
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func sortedSet(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedKeys(m map[string][]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
