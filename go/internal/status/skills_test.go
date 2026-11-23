package status

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// followLatestGame は style-interview を engine 0.110.0 から写したと書いた、コミット済みのゲームを置く。
func followLatestGame(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	rules, err := os.ReadFile(filepath.Join(repoRoot(t), "bin", "lint-rules", "sync-agents.json"))
	if err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(root, "bin", "lint-rules", "sync-agents.json"), string(rules))
	write(t, filepath.Join(root, ".agents-pack.json"),
		`{"version": 1, "dirs": {}, "followLatest": {"style-interview": "0.110.0", "pixel-art": "0.109.0"}}`)
	write(t, filepath.Join(root, ".claude", "skills", "style-interview", "SKILL.md"), "前\n")
	for _, args := range [][]string{
		{"init", "-q"}, {"add", "-A"},
		{"-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "x"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	return root
}

func TestFollowLatestSkillsChangedButNotCommittedIsReported(t *testing.T) {
	root := followLatestGame(t)
	write(t, filepath.Join(root, ".claude", "skills", "style-interview", "SKILL.md"), "後\n")
	if !has(build(t, root), "skills   スキルを engine 0.110.0 の物に新しくしました（コミット待ち）") {
		t.Errorf("コミット待ちの行がありません")
	}
}

func TestFollowLatestSkillsCommittedIsQuiet(t *testing.T) {
	root := followLatestGame(t)
	for _, line := range build(t, root) {
		if strings.HasPrefix(line, "skills ") {
			t.Errorf("コミット済みなのに出ています: %s", line)
		}
	}
}

func TestOtherSkillsChangedIsNotReportedAsFollowLatest(t *testing.T) {
	root := followLatestGame(t)
	write(t, filepath.Join(root, ".claude", "skills", "flix-docs", "SKILL.md"), "足した\n")
	for _, line := range build(t, root) {
		if strings.HasPrefix(line, "skills ") {
			t.Errorf("版に依るスキルの差で出ています: %s", line)
		}
	}
}
