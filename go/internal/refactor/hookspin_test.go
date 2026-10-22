package refactor

// エンジンが配る hooks.json の check の常駐（checkd.server）の flixlint の版が、この道具の MinFlixlint に届いているか。
//
// WhyNot: refactor は make check と同じ常駐の shim で索引を作る。hooks.json の版を上げ忘れると、配った先では
// 素の bin/fge refactor が「索引の形の版が古い」で止まる（0.57.0 は MinFlixlint 0.8.6 に対して 0.8.5 のまま配った）。
// リリースの前の go test で止める。

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestHooksPinReachesMinFlixlint(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "bin", "lint-rules", "hooks.json"))
	if err != nil {
		t.Fatalf("hooks.json を読めません: %v", err)
	}
	var hooks struct {
		Checkd struct {
			Server struct {
				FlixlintVersion string `json:"flixlintVersion"`
			} `json:"server"`
		} `json:"checkd"`
	}
	if err := json.Unmarshal(raw, &hooks); err != nil {
		t.Fatalf("hooks.json の形: %v", err)
	}
	pin := hooks.Checkd.Server.FlixlintVersion
	if !versionAtLeast("flixlint "+pin, MinFlixlintParam) {
		t.Fatalf("hooks.json の checkd.server.flixlintVersion は %q。refactor は flixlint %s 以上が要る（flixlintVersion と shimSha256 を上げる）", pin, MinFlixlintParam)
	}
}
