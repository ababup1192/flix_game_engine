package hooks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNameOfPatternPicksTheNameToLookUp(t *testing.T) {
	cases := map[string]string{
		`enterFight`:                 "enterFight",
		`WorldFight.enterFight`:      "WorldFight.enterFight",
		`\bEntry\b`:                  "Entry",
		`Entry.Entry`:                "Entry.Entry",
		`pub def step`:               "step",
		`^\s*\(pub \)\?def armFight`: "armFight",
		`World\.step\|stepSystems`:   "World.step",
	}
	for pat, want := range cases {
		if got := nameOfPattern(pat); got != want {
			t.Errorf("%q: %q を引くはず（%q）", pat, want, got)
		}
	}
}

func TestAgentTranscriptPointsAtTheSubagentsOwnRecord(t *testing.T) {
	p := Payload{"transcript_path": "/x/proj/s1.jsonl", "agent_id": "a9"}
	if got := agentTranscript(p); got != "/x/proj/s1/subagents/agent-a9.jsonl" {
		t.Errorf("サブエージェントは親の記録の隣の subagents/agent-<id>.jsonl を読むはず: %s", got)
	}
}

// firstFixture は flix.toml と、当たりを 1 行返す偽の bin/fge を持つゲームと、空の記録を作る。
func firstFixture(t *testing.T) (game, transcript string) {
	t.Helper()
	game = t.TempDir()
	if err := os.MkdirAll(filepath.Join(game, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(game, "flix.toml"), nil, 0o644)
	os.WriteFile(filepath.Join(game, "bin", "fge"), []byte("#!/bin/sh\necho \"usages $3\"\necho \"  src/World.flix:12:3  World.go  呼び出し\"\n"), 0o755)
	transcript = filepath.Join(t.TempDir(), "s1.jsonl")
	os.WriteFile(transcript, []byte(`{"type":"user"}`+"\n"), 0o644)
	return game, transcript
}

func firstOnce(t *testing.T, game, transcript string) (deny bool, reason string) {
	t.Helper()
	root := nudgeRoot(t)
	in, _ := json.Marshal(map[string]any{"session_id": "s1", "transcript_path": transcript, "cwd": game,
		"tool_name": "Bash", "tool_input": map[string]any{"command": "grep -rn enterFight " + game}})
	var out strings.Builder
	RunSearchFirst(&out, root, "", strings.NewReader(string(in)))
	if out.Len() == 0 {
		return false, ""
	}
	var js struct {
		H struct {
			Decision string `json:"permissionDecision"`
			Reason   string `json:"permissionDecisionReason"`
		} `json:"hookSpecificOutput"`
	}
	json.Unmarshal([]byte(out.String()), &js)
	return js.H.Decision == "deny", js.H.Reason
}

func TestSearchFirstStopsTheFirstNameGrepWithTheIndexAnswer(t *testing.T) {
	game, transcript := firstFixture(t)
	deny, reason := firstOnce(t, game, transcript)
	if !deny || !strings.Contains(reason, searchFirstMark) || !strings.Contains(reason, "src/World.flix:12") {
		t.Errorf("最初の 1 回は grep を止めて、索引の答えを理由で返すはず: %v %s", deny, reason)
	}
}

func TestSearchFirstLetsTheGrepThroughOnceTheRecordHasTheMark(t *testing.T) {
	game, transcript := firstFixture(t)
	os.WriteFile(transcript, []byte(`{"type":"user","content":"`+searchFirstMark+` …"}`+"\n"), 0o644)
	if deny, _ := firstOnce(t, game, transcript); deny {
		t.Errorf("記録に印があれば（もう 1 回止めた）grep を通すはず")
	}
}

func TestSearchFirstLetsTheGrepThroughWhenTheRecordCannotBeRead(t *testing.T) {
	game, _ := firstFixture(t)
	if deny, _ := firstOnce(t, game, filepath.Join(game, "無い記録.jsonl")); deny {
		t.Errorf("記録が読めなければ、1 回目かを見分けられないので grep を通すはず")
	}
}
