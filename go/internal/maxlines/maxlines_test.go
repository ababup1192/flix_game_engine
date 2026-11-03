package maxlines

import (
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
