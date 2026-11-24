package fgeinstall

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/fgehome"
)

func writeUnder(t *testing.T, root, rel, body string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// placeSkillsEngine は style-interview を版によらないスキル、flix-docs を版に依るスキルとする engine を置く。
func placeSkillsEngine(t *testing.T, version, body string) {
	t.Helper()
	placeEngine(t, version, false)
	dir := fgehome.EngineDir(version)
	rules, err := os.ReadFile(filepath.Join("..", "..", "..", "bin", "lint-rules", "sync-agents.json"))
	if err != nil {
		t.Fatal(err)
	}
	writeUnder(t, dir, "bin/lint-rules/sync-agents.json", string(rules))
	writeUnder(t, dir, "agents-pack/manifest.json", `{"copy": [], "copyIfAbsent": [],
	  "copyDirs": [{"src": "agents-pack/skills", "dst": ".claude/skills"},
	               {"src": "agents-pack/skills", "dst": ".agents/skills"}],
	  "followLatest": {"skills": ["style-interview"], "commands": []}}`)
	writeUnder(t, dir, "agents-pack/skills/style-interview/SKILL.md", body)
	writeUnder(t, dir, "agents-pack/skills/flix-docs/SKILL.md", body)
}

// placeSkillsGame は engine 0.108.0 の物を配ったゲームを置く。
func placeSkillsGame(t *testing.T) string {
	t.Helper()
	game := t.TempDir()
	for _, d := range []string{".claude/skills", ".agents/skills"} {
		writeUnder(t, game, d+"/style-interview/SKILL.md", "古い\n")
		writeUnder(t, game, d+"/flix-docs/SKILL.md", "古い\n")
	}
	return game
}

func skillsWorkspace(t *testing.T) (string, string) {
	t.Helper()
	a, b := placeSkillsGame(t), placeSkillsGame(t)
	if err := fgehome.WriteWorkspace(fgehome.Workspace{Games: []fgehome.Game{{Name: "a", Dir: a}, {Name: "b", Dir: b}}}); err != nil {
		t.Fatal(err)
	}
	return a, b
}

func readUnder(t *testing.T, root, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestRefreshFollowLatestSkillsCopiesTheNewestEngineSkillToEveryGame(t *testing.T) {
	_ = testEnv(t, newFakeNet(t), "linux")
	placeSkillsEngine(t, "0.108.0", "古い\n")
	placeSkillsEngine(t, "0.110.0", "新しい\n")
	a, b := skillsWorkspace(t)
	if _, _, err := RefreshFollowLatestSkills(); err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, g := range []string{a, b} {
		for _, d := range []string{".claude/skills", ".agents/skills"} {
			got = append(got, readUnder(t, g, d+"/style-interview/SKILL.md"))
		}
	}
	if strings.Join(got, "") != strings.Repeat("新しい\n", 4) {
		t.Errorf("写った物 = %q", got)
	}
}

func TestRefreshFollowLatestSkillsLeavesVersionBoundSkillsAlone(t *testing.T) {
	_ = testEnv(t, newFakeNet(t), "linux")
	placeSkillsEngine(t, "0.110.0", "新しい\n")
	a, _ := skillsWorkspace(t)
	if _, _, err := RefreshFollowLatestSkills(); err != nil {
		t.Fatal(err)
	}
	if got := readUnder(t, a, ".claude/skills/flix-docs/SKILL.md"); got != "古い\n" {
		t.Errorf("版に依るスキルまで替わった: %q", got)
	}
}

func TestRefreshFollowLatestSkillsReportsTheGamesAndVersion(t *testing.T) {
	_ = testEnv(t, newFakeNet(t), "linux")
	placeSkillsEngine(t, "0.110.0", "新しい\n")
	skillsWorkspace(t)
	version, res, err := RefreshFollowLatestSkills()
	if err != nil || version != "0.110.0" || len(res) != 2 || res[0].Skills[0] != "style-interview" {
		t.Errorf("version=%s res=%+v err=%v", version, res, err)
	}
}

func TestRefreshFollowLatestSkillsIsQuietTheSecondTime(t *testing.T) {
	_ = testEnv(t, newFakeNet(t), "linux")
	placeSkillsEngine(t, "0.110.0", "新しい\n")
	skillsWorkspace(t)
	if _, _, err := RefreshFollowLatestSkills(); err != nil {
		t.Fatal(err)
	}
	_, res, err := RefreshFollowLatestSkills()
	if err != nil || len(res) != 0 {
		t.Errorf("res=%+v err=%v", res, err)
	}
}

func TestRefreshFollowLatestSkillsSkipsAnEngineWithoutFollowLatest(t *testing.T) {
	_ = testEnv(t, newFakeNet(t), "linux")
	placeEngine(t, "0.108.0", false)
	a, _ := skillsWorkspace(t)
	_, res, err := RefreshFollowLatestSkills()
	if got := readUnder(t, a, ".claude/skills/style-interview/SKILL.md"); got != "古い\n" || len(res) != 0 || err != nil {
		t.Errorf("got=%q res=%+v err=%v", got, res, err)
	}
}
