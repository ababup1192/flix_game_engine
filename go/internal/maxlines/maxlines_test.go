package maxlines

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

func run(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		t.Fatal(err)
	}
	return code, out.String() + errOut.String()
}

func lines(n int) string { return strings.Repeat("x\n", n) }

// 上限を超えた engine の .flix は止まり、上限ちょうどの物と prefixes の外の物は止まらない。
func TestOverLimitFiresInsideEngineOnly(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"engine_world/src/Big.flix":  lines(1201),
		"engine_world/src/Edge.flix": lines(1200),
		"templates/x/src/Big.flix":   lines(5000),
	})
	code, msg := run(t, root, "engine_world/src/Big.flix", "engine_world/src/Edge.flix", "templates/x/src/Big.flix")
	if code != 1 || !strings.Contains(msg, "engine_world/src/Big.flix は 1201 行") || strings.Count(msg, "!! ") != 1 {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// 除外に載せたファイルは超えていても通る。
func TestExemptFilePasses(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"engine/src/Big.flix":                 lines(1300),
		"bin/lint-rules/max-lines.local.json": `{"exempt": {"engine/src/Big.flix::max-lines": "分けるまで"}}`,
	})
	withExemptLines(t, root, `{"engine/src/Big.flix::max-lines": 1300}`)
	code, msg := run(t, root, "engine/src/Big.flix")
	if code != 0 {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// --all は上限以下に戻ったファイルの除外を「消して」と言って止まる。
func TestAllReportsStaleExempt(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"engine/src/Small.flix":               lines(10),
		"bin/lint-rules/max-lines.local.json": `{"exempt": {"engine/src/Small.flix::max-lines": "分けるまで"}}`,
	})
	lintconf.GitInit(t, root)
	code, msg := run(t, root, "--all")
	if code != 1 || !strings.Contains(msg, "engine/src/Small.flix::max-lines は") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// 最後の行に改行が無くても 1 行と数える。
func TestCountLinesWithoutTrailingNewline(t *testing.T) {
	if got := CountLines([]byte("a\nb")); got != 2 {
		t.Fatalf("got %d", got)
	}
}

// withExemptLines は規約ファイルへ exemptLines を足す。
func withExemptLines(t *testing.T, root, lines string) {
	t.Helper()
	p := filepath.Join(root, "bin/lint-rules/max-lines.json")
	body, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		t.Fatal(err)
	}
	var l map[string]any
	if err := json.Unmarshal([]byte(lines), &l); err != nil {
		t.Fatal(err)
	}
	m["exemptLines"] = l
	out, _ := json.Marshal(m)
	if err := os.WriteFile(p, out, 0o644); err != nil {
		t.Fatal(err)
	}
}

// 除外に載せた時の行数より伸びたファイルは、除外でも止まる。
func TestExemptFileFiresWhenGrownPastRecordedLines(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"engine/src/Big.flix":                 lines(1301),
		"bin/lint-rules/max-lines.local.json": `{"exempt": {"engine/src/Big.flix::max-lines": "分けるまで"}}`,
	})
	withExemptLines(t, root, `{"engine/src/Big.flix::max-lines": 1300}`)
	code, msg := run(t, root, "engine/src/Big.flix")
	if code != 1 || !strings.Contains(msg, "1301 行。除外に載せた時の 1300 行より伸びた") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// 除外に載っていても、載せた時の行数が無ければ止まる。
func TestExemptFileWithoutRecordedLinesFires(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"engine/src/Big.flix":                 lines(1300),
		"bin/lint-rules/max-lines.local.json": `{"exempt": {"engine/src/Big.flix::max-lines": "分けるまで"}}`,
	})
	code, msg := run(t, root, "engine/src/Big.flix")
	if code != 1 || !strings.Contains(msg, "載せた時の行数がありません") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}
