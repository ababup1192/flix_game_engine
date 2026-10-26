package refactorhost

// エンジンが配る物と flixlint の道具が合っているか（配る refactor.json の型紙・hooks.json の flixlint の版）と、
// doc-refs の規約で拾った文書の名指し。

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/ababup1192/flixlint/go/refactor"
)

// WhyNot: refactor は make check と同じ常駐の shim で索引を作る。hooks.json の版を上げ忘れると、配った先では
// 素の bin/fge refactor が「索引の形の版が古い」で止まる（0.57.0 は MinFlixlint 0.8.6 に対して 0.8.5 のまま配った）。
// リリースの前の go test で止める。
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
	if !atLeast(pin, refactor.MinFlixlintParam) {
		t.Fatalf("hooks.json の checkd.server.flixlintVersion は %q。refactor は flixlint %s 以上が要る（flixlintVersion と shimSha256 を上げる）", pin, refactor.MinFlixlintParam)
	}
}

func atLeast(have, want string) bool {
	h, w := strings.Split(have, "."), strings.Split(want, ".")
	for i := range w {
		if i >= len(h) {
			return false
		}
		a, _ := strconv.Atoi(h[i])
		b, _ := strconv.Atoi(w[i])
		if a != b {
			return a > b
		}
	}
	return true
}

func TestShippedRewritesParse(t *testing.T) {
	cfg, err := refactor.LoadConfig(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	for name, rules := range cfg.Rewrites {
		for _, r := range rules {
			if _, err := refactor.ParseTmpl(r.From); err != nil {
				t.Errorf("refactor.json の rewrites.%s の型紙 %q が読めない: %v", name, r.From, err)
			}
		}
	}
	if len(cfg.Rewrites["option-none-compare"]) == 0 || len(cfg.Rewrites["match-some-wild"]) == 0 {
		t.Fatalf("配る refactor.json に option-none-compare・match-some-wild の組が無い")
	}
}

// doc-refs の規約で数えるのは ` ` の中の名前で、予定の印（（予定））と地の文は数えない。
func TestDocMentionsFollowDocRefsRules(t *testing.T) {
	root := t.TempDir()
	rules, err := os.ReadFile(filepath.Join("..", "..", "..", "bin", "lint-rules", "doc-refs.json"))
	if err != nil {
		t.Fatal(err)
	}
	write := func(p, body string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(filepath.Join(root, p)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, p), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("bin/lint-rules/doc-refs.json", string(rules))
	write("NOTES.md", "# 記録\n\n`A.lonely` は呼ばれない。lonely と A.lonely は地の文。\n`A.lonely`（予定）\n")
	docs, at, ok := DocMentions(root, "")
	if !ok || at != root {
		t.Fatalf("規約を読めていない（ok=%v at=%q）", ok, at)
	}
	var got []string
	for _, d := range docs {
		got = append(got, d.File+":"+strconv.Itoa(d.Line)+" "+d.Key)
	}
	if strings.Join(got, "・") != "NOTES.md:3 A.lonely" {
		t.Errorf("拾った名指し %v（NOTES.md:3 A.lonely だけのはず）", got)
	}
}
