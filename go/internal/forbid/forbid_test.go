package forbid

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func writeRepo(t *testing.T, engine, local string, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	must := func(rel, body string) {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	must(RulesPath, engine)
	if local != "" {
		must(LocalPath, local)
	}
	for rel, body := range files {
		must(rel, body)
	}
	return root
}

const engineRules = `{"rules":[{"id":"bands","suffixes":[".flix"],"pattern":"\\bDepth\\.Bands\\b","hint":"ZStack.of に積む"}]}`

func run(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		t.Fatal(err)
	}
	return code, out.String() + errOut.String()
}

// コードの行は止め、代わりの物を出す。コメントと文字列の中は止めない。
func TestCodeLineFiresWithHintCommentQuiet(t *testing.T) {
	root := writeRepo(t, engineRules, "", map[string]string{
		"src/View.flix": "    let b = Depth.Bands.of(x);\n    // Depth.Bands は使わない\n    let s = \"Depth.Bands\";",
	})
	code, msg := run(t, root, "src/View.flix")
	if code != 1 || !strings.Contains(msg, "src/View.flix:1 [bands]") || strings.Contains(msg, ":2 ") || !strings.Contains(msg, "代わりに: ZStack.of に積む") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// ゲームの規則は basenames と unlessLine で絞れ、除外で黙る。古い除外は --all で鳴る。
func TestLocalRuleUnlessLineAndExempt(t *testing.T) {
	local := `{"rules":[{"id":"mix","basenames":["Makefile"],"pattern":"mix-video-sfx","unlessLine":"\\$\\(3\\)","hint":"$(call video,…)"}],
	  "exempt":{"Makefile::mix":"移すまで","gone.flix::mix":"古い"}}`
	root := writeRepo(t, engineRules, local, map[string]string{
		"Makefile": "\tpython3 bin/mix-video-sfx.py $(3)\n\tpython3 bin/mix-video-sfx.py debug/video/feed 30\n",
	})
	if code, msg := run(t, root, "Makefile"); code != 0 {
		t.Fatalf("exempt should silence: %s", msg)
	}
	local2 := strings.Replace(local, `"Makefile::mix":"移すまで",`, "", 1)
	root2 := writeRepo(t, engineRules, local2, map[string]string{
		"Makefile": "\tpython3 bin/mix-video-sfx.py $(3)\n\tpython3 bin/mix-video-sfx.py debug/video/feed 30\n",
	})
	code, msg := run(t, root2, "Makefile")
	if code != 1 || !strings.Contains(msg, "Makefile:2 [mix]") || strings.Contains(msg, "Makefile:1 ") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// hint の無い規則は読み込みで止める (止めるだけで代わりを言わない規則を置かない)。
func TestRuleWithoutHintIsAnError(t *testing.T) {
	root := writeRepo(t, `{"rules":[{"id":"x","pattern":"a","hint":" "}]}`, "", nil)
	if _, err := LoadRules(root); err == nil {
		t.Fatal("want error")
	}
}

// rawLine の規則は .flix の文字列の中身も見る（View に直に書いた文言を止める）。コメントは見ない。
func TestRawLineSeesStringContents(t *testing.T) {
	r := &Rules{List: []Rule{{ID: "lit", Suffixes: []string{"View.flix"}, Pattern: `\btext\s*=\s*"(?:\$\{[^}]*\}|[^"$])*?[A-Za-z]{2,}`, RawLine: true, Hint: "h"}}}
	r.List[0].re = regexp.MustCompile(r.List[0].Pattern)
	src := "  TextDraw.centered({ text = \"Press any key\", size = 8.0 })\n" +
		"  { text = doc#press }\n" +
		"  { text = \"${doc#a} 1\" }\n" +
		"  { text = \"HP ${hp}\" }\n" +
		"  /// 例: text = \"Press\"\n" +
		"  { size = 8.0 } // text = \"Press\"\n"
	hits := r.TextHits("src/TitleView.flix", src)
	if len(hits) != 2 || hits[0].Line != 1 || hits[1].Line != 4 {
		t.Errorf("1 行目と 4 行目だけ当たるはず: %+v", hits)
	}
}
