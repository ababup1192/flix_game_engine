package syncagents

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// followFixture は alpha を版によらないスキル、beta を版に依るスキルとする配り元を作る。
func followFixture(t *testing.T, alphaBody string) string {
	t.Helper()
	root := fixture(t)
	write(t, root, "agents-pack/skills/alpha/SKILL.md", alphaBody, 0o644)
	write(t, root, "agents-pack/manifest.json", `{
	  "copy": [], "copyIfAbsent": [],
	  "copyDirs": [{"src": "agents-pack/skills", "dst": ".claude/skills"},
	               {"src": "agents-pack/skills", "dst": ".agents/skills"}],
	  "followLatest": {"skills": ["alpha"], "commands": ["make status", "bin/fge px"]}
	}`, 0o644)
	return root
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestSyncSkipsFollowLatestSkillWhenSourceIsOlderThanRecorded(t *testing.T) {
	game := t.TempDir()
	run(t, followFixture(t, "---\ndescription: 新しい\n---\n"), "--game", game, "--version", "0.110.0")
	run(t, followFixture(t, "---\ndescription: 古い\n---\n"), "--game", game, "--version", "0.108.0")
	if got := readFile(t, filepath.Join(game, ".claude/skills/alpha/SKILL.md")); !strings.Contains(got, "新しい") {
		t.Errorf("古い版の物で戻った: %q", got)
	}
}

func TestSyncReplacesFollowLatestSkillWhenSourceIsNewerThanRecorded(t *testing.T) {
	game := t.TempDir()
	run(t, followFixture(t, "---\ndescription: 古い\n---\n"), "--game", game, "--version", "0.108.0")
	run(t, followFixture(t, "---\ndescription: 新しい\n---\n"), "--game", game, "--version", "0.110.0")
	if got := readFile(t, filepath.Join(game, ".agents/skills/alpha/SKILL.md")); !strings.Contains(got, "新しい") {
		t.Errorf("新しい版の物に替わっていない: %q", got)
	}
}

func TestSyncRecordsTheVersionItCopiedFollowLatestSkillsFrom(t *testing.T) {
	game := t.TempDir()
	run(t, followFixture(t, "---\ndescription: x\n---\n"), "--game", game, "--version", "0.108.0")
	if got := ReadFollowLatestVersions(repoRoot(), game); got["alpha"] != "0.108.0" || len(got) != 1 {
		t.Errorf("followLatest = %v", got)
	}
}

func TestSyncStillCopiesVersionBoundSkillsFromAnOlderSource(t *testing.T) {
	game := t.TempDir()
	run(t, followFixture(t, "---\ndescription: x\n---\n"), "--game", game, "--version", "0.110.0")
	old := followFixture(t, "---\ndescription: x\n---\n")
	write(t, old, "agents-pack/skills/beta/SKILL.md", "---\ndescription: 版に依る\n---\n", 0o644)
	run(t, old, "--game", game, "--version", "0.108.0")
	if got := readFile(t, filepath.Join(game, ".claude/skills/beta/SKILL.md")); !strings.Contains(got, "版に依る") {
		t.Errorf("版に依るスキルが写っていない: %q", got)
	}
}

func TestSyncDoesNotPruneHeldBackFollowLatestFiles(t *testing.T) {
	game := t.TempDir()
	newer := followFixture(t, "---\ndescription: x\n---\n")
	write(t, newer, "agents-pack/skills/alpha/extra.md", "足した\n", 0o644)
	run(t, newer, "--game", game, "--version", "0.110.0")
	run(t, followFixture(t, "---\ndescription: x\n---\n"), "--game", game, "--version", "0.108.0")
	if _, err := os.Stat(filepath.Join(game, ".claude/skills/alpha/extra.md")); err != nil {
		t.Errorf("新しい版で写した物が消えた: %v", err)
	}
}

func TestRefreshCopiesFollowLatestSkillIntoBothSkillDirs(t *testing.T) {
	game := t.TempDir()
	run(t, followFixture(t, "---\ndescription: 古い\n---\n"), "--game", game, "--version", "0.108.0")
	done, err := RefreshFollowLatest(followFixture(t, "---\ndescription: 新しい\n---\n"), game, "0.110.0")
	if err != nil || len(done) != 1 {
		t.Fatalf("done=%v err=%v", done, err)
	}
	a := readFile(t, filepath.Join(game, ".claude/skills/alpha/SKILL.md"))
	b := readFile(t, filepath.Join(game, ".agents/skills/alpha/SKILL.md"))
	if !strings.Contains(a, "新しい") || !strings.Contains(b, "新しい") {
		t.Errorf(".claude=%q .agents=%q", a, b)
	}
}

func TestRefreshLeavesVersionBoundSkillsAlone(t *testing.T) {
	game := t.TempDir()
	run(t, followFixture(t, "---\ndescription: x\n---\n"), "--game", game, "--version", "0.108.0")
	newer := followFixture(t, "---\ndescription: x\n---\n")
	write(t, newer, "agents-pack/skills/beta/SKILL.md", "---\ndescription: 新しい版に依る\n---\n", 0o644)
	if _, err := RefreshFollowLatest(newer, game, "0.110.0"); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, filepath.Join(game, ".claude/skills/beta/SKILL.md")); strings.Contains(got, "新しい版に依る") {
		t.Errorf("版に依るスキルまで替わった: %q", got)
	}
}

func TestRefreshPrunesFilesTheNewerSkillDropped(t *testing.T) {
	game := t.TempDir()
	older := followFixture(t, "---\ndescription: x\n---\n")
	write(t, older, "agents-pack/skills/alpha/gone.md", "消える\n", 0o644)
	run(t, older, "--game", game, "--version", "0.108.0")
	if _, err := RefreshFollowLatest(followFixture(t, "---\ndescription: x\n---\n"), game, "0.110.0"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(game, ".claude/skills/alpha/gone.md")); !os.IsNotExist(err) {
		t.Errorf("新しい版に無い物が残った: %v", err)
	}
}

func TestRefreshDoesNothingWhenRecordedVersionIsTheSame(t *testing.T) {
	game := t.TempDir()
	root := followFixture(t, "---\ndescription: x\n---\n")
	run(t, root, "--game", game, "--version", "0.110.0")
	done, err := RefreshFollowLatest(root, game, "0.110.0")
	if err != nil || len(done) != 0 {
		t.Errorf("done=%v err=%v", done, err)
	}
}

func TestRefreshSkipsAFolderWithoutSkillDirs(t *testing.T) {
	game := t.TempDir()
	done, err := RefreshFollowLatest(followFixture(t, "---\ndescription: x\n---\n"), game, "0.110.0")
	_, statErr := os.Stat(filepath.Join(game, ".claude"))
	if err != nil || len(done) != 0 || !os.IsNotExist(statErr) {
		t.Errorf("done=%v err=%v stat=%v", done, err, statErr)
	}
}

func TestCheckFollowLatestStopsOnACommandMissingFromTheList(t *testing.T) {
	root := followFixture(t, "---\ndescription: x\n---\n`make render-all` で見る\n")
	_, errOut, code := run(t, root, "--check-follow-latest")
	if code != 1 || !strings.Contains(errOut, "make render-all") {
		t.Errorf("code=%d err=%q", code, errOut)
	}
}

func TestCheckFollowLatestPassesWhenEveryCommandIsListed(t *testing.T) {
	root := followFixture(t, "---\ndescription: x\n---\nmake status と `bin/fge px pal` を使う\n")
	_, errOut, code := run(t, root, "--check-follow-latest")
	if code != 0 || errOut != "" {
		t.Errorf("code=%d err=%q", code, errOut)
	}
}

func TestCheckFollowLatestIgnoresVersionBoundSkills(t *testing.T) {
	root := followFixture(t, "---\ndescription: x\n---\n")
	write(t, root, "agents-pack/skills/beta/SKILL.md", "---\ndescription: x\n---\nmake brand-new\n", 0o644)
	_, _, code := run(t, root, "--check-follow-latest")
	if code != 0 {
		t.Errorf("code=%d", code)
	}
}

func TestShortCheckOptionStillMeansCheckManifest(t *testing.T) {
	_, errOut, code := run(t, fixture(t), "--check")
	if code != 1 || !strings.Contains(errOut, "nope") {
		t.Errorf("code=%d err=%q", code, errOut)
	}
}

func TestRepoFollowLatestSkillsUseOnlyListedCommands(t *testing.T) {
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, repoRoot(), []string{"--check-follow-latest"})
	if err != nil || code != 0 {
		t.Errorf("code=%d err=%v %s", code, err, errOut.String())
	}
}
