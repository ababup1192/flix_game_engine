package hooks

import (
	"strings"
	"testing"
)

func TestFlixWorkPassesOnWindows(t *testing.T) {
	old := hostOS
	hostOS = "windows"
	t.Cleanup(func() { hostOS = old })
	var errOut strings.Builder
	// 規約の無い根は Windows 以外なら 2 で止まる（TestFlixWorkAbortsWithoutRules）。
	code := RunFlixWork(&errOut, t.TempDir(), payloadOf(t, map[string]any{"session_id": "S1"}))
	if code != 0 || errOut.Len() != 0 {
		t.Errorf("Windows で検査に入った: code=%d %q", code, errOut.String())
	}
}
