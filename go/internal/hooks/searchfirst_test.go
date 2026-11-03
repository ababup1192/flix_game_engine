package hooks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

func TestNameSearchOfCatchesTheFormsThatSlippedThrough(t *testing.T) {
	game, _ := firstFixture(t)
	hit := []string{
		`grep -n "getBean\|allocBytes" engine/src/AllocMeter.flix`,
		`grep -n "step" engine/src/World.flix`,
		`grep -n '\bstepSystems\b' src/World.flix`,
		`rg -n "Platform|getBean" engine/src/Game.flix`,
	}
	for _, c := range hit {
		p := Payload{"cwd": game, "tool_input": map[string]any{"command": c}}
		if _, _, ok := nameSearchOf(p, ".flix"); !ok {
			t.Errorf("名前の検索として拾うはず: %s", c)
		}
	}
	pass := []string{
		`grep -n "Game Over" src/World.flix`,
		`grep -n "import java.lang.Math" src/World.flix`,
		`grep -rn "java.nio.file" src/`,
		`grep -rn "step" src/`,
		`grep -n "match" src/World.flix`,
		`grep -n "TODO" src/World.flix`,
		`grep -n "fail" .test-logs/check.log`,
		`grep -n "step" docs/clock.md`,
		`grep -n "TODO\|Panic" src/World.flix`,
		`grep -n "select" src/World.flix`,
	}
	for _, c := range pass {
		p := Payload{"cwd": game, "tool_input": map[string]any{"command": c}}
		if _, _, ok := nameSearchOf(p, ".flix"); ok {
			t.Errorf("文字列・import・ログ・文書の検索は拾わないはず: %s", c)
		}
	}
}

// outlineFixture は outline --json を返す偽の bin/fge を持つゲーム。
func outlineFixture(t *testing.T, script string) (game, transcript string) {
	t.Helper()
	game, transcript = firstFixture(t)
	os.MkdirAll(filepath.Join(game, "src"), 0o755)
	os.WriteFile(filepath.Join(game, "src", "World.flix"), nil, 0o644)
	os.WriteFile(filepath.Join(game, "bin", "fge"), []byte(script), 0o755)
	return game, transcript
}

const outlineScript = "#!/bin/sh\n" + `echo '{"op":"outline","found":[{"file":"src/World.flix","line":3,"kind":"def","sym":"World.init"},{"file":"src/World.flix","line":120,"kind":"def","sym":"World.step"},{"file":"src/World.flix","line":150,"kind":"enum","sym":"World.Phase"},{"file":"src/World.flix","line":151,"kind":"case","sym":"World.Phase.A"},{"file":"src/World.flix","line":200,"kind":"def","sym":"World.draw"}]}'` + "\n"

func runFirst(t *testing.T, game, transcript, cmd string) (deny bool, reason string) {
	t.Helper()
	in, _ := json.Marshal(map[string]any{"session_id": "s1", "transcript_path": transcript, "cwd": game,
		"tool_name": "Bash", "tool_input": map[string]any{"command": cmd}})
	var out strings.Builder
	RunSearchFirst(&out, nudgeRoot(t), "", strings.NewReader(string(in)))
	var js struct {
		H struct {
			Decision string `json:"permissionDecision"`
			Reason   string `json:"permissionDecisionReason"`
		} `json:"hookSpecificOutput"`
	}
	json.Unmarshal([]byte(out.String()), &js)
	return js.H.Decision == "deny", js.H.Reason
}

func TestSearchFirstAnswersASedLineReadWithTheDeclarationsInRange(t *testing.T) {
	game, transcript := outlineFixture(t, outlineScript)
	deny, reason := runFirst(t, game, transcript, "sed -n 125,180p src/World.flix")
	if !deny || !strings.Contains(reason, "show World.step") || !strings.Contains(reason, "show World.Phase") ||
		strings.Contains(reason, "World.init") || strings.Contains(reason, "World.draw") || strings.Contains(reason, "Phase.A") {
		t.Errorf("範囲にかかる宣言（頭を含む物と中で始まる物）と show を返して止めるはず: %v %s", deny, reason)
	}
}

func TestSearchFirstLetsASedLineReadThroughTheSecondTime(t *testing.T) {
	game, transcript := outlineFixture(t, outlineScript)
	os.WriteFile(transcript, []byte(`{"content":"`+lineReadMark+`"}`+"\n"), 0o644)
	if deny, _ := runFirst(t, game, transcript, "sed -n 125,180p src/World.flix"); deny {
		t.Error("2 回目は通すはず")
	}
}

func TestSearchFirstLeavesSedOnOtherFilesAlone(t *testing.T) {
	game, transcript := outlineFixture(t, outlineScript)
	for _, c := range []string{"sed -n 1,40p docs/clock.md", "sed -i 's/a/b/' src/World.flix", "sed -n '/def/p' src/World.flix"} {
		if deny, _ := runFirst(t, game, transcript, c); deny {
			t.Errorf("止めないはず: %s", c)
		}
	}
}

func TestSearchFirstStopsWithTheCommandWhenTheIndexIsLate(t *testing.T) {
	game, transcript := outlineFixture(t, "#!/bin/sh\n(sleep 5; echo late) &\nsleep 5\n")
	old := searchFirstLimit
	searchFirstLimit = 200 * time.Millisecond
	defer func() { searchFirstLimit = old }()
	start := time.Now()
	deny, reason := runFirst(t, game, transcript, "grep -rn enterFight "+game)
	if took := time.Since(start); took > 3*time.Second {
		t.Errorf("子が管を持っていても待ち続けないはず: %s", took)
	}
	if !deny || !strings.Contains(reason, "bin/fge refactor usages enterFight") {
		t.Errorf("索引が間に合わない時は、打つコマンドを返して止めるはず: %v %s", deny, reason)
	}
}

func TestSearchFirstLetsALowerWordThroughWhenTheIndexIsLate(t *testing.T) {
	game, transcript := outlineFixture(t, "#!/bin/sh\nsleep 5\n")
	old := searchFirstLimit
	searchFirstLimit = 200 * time.Millisecond
	defer func() { searchFirstLimit = old }()
	for _, c := range []string{`grep -n "failed" src/World.flix`, `grep -n "Player.png" src/World.flix`} {
		if deny, _ := runFirst(t, game, transcript, c); deny {
			t.Errorf("答えを見ずに名前と決められない字は通すはず: %s", c)
		}
	}
}

func TestSearchFirstLateStopDoesNotUseUpTheFirstStop(t *testing.T) {
	game, transcript := firstFixture(t)
	os.WriteFile(transcript, []byte(`{"content":"`+lateMark+`"}`+"\n"), 0o644)
	if deny, reason := firstOnce(t, game, transcript); !deny || !strings.Contains(reason, searchFirstMark) {
		t.Errorf("索引待ちで止めた後でも、答えのある最初の grep は止めるはず: %v %s", deny, reason)
	}
}
