package forbid

import (
	"os"
	"os/exec"
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

// skipDirs はパスのどの段のフォルダでも外す（ゲームの test/ もテンプレの test/ も）。
func TestSkipDirsMatchesAnySegment(t *testing.T) {
	rule := Rule{ID: "x", Suffixes: []string{".flix"}, SkipDirs: []string{"test"}}
	got := []bool{rule.Applies("test/A.flix"), rule.Applies("templates/p/test/A.flix"), rule.Applies("templates/p/src/A.flix"), rule.Applies("src/latest/A.flix")}
	want := []bool{false, false, true, true}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
}

// whenProject の規則は、そのファイルのプロジェクト（いちばん近い flix.toml）が正規表現に当たるときだけ鳴る。
// 同じリポの別のプロジェクトで当たっても、こちらは黙る。コメントの中の言及は数えない。
func TestWhenProjectGatesByNearestProject(t *testing.T) {
	rules := `{"rules":[{"id":"old","suffixes":[".flix"],"pattern":"\\bTimeline\\.soundsSince\\b","whenProject":"\\bApp\\.addClock\\b","hint":"Timeline.soundsOnClock"}]}`
	root := writeRepo(t, rules, "", map[string]string{
		"templates/a/flix.toml":       "",
		"templates/a/src/Main.flix":   "    app |> App.addClock(spec)\n",
		"templates/a/src/Sounds.flix": "    Timeline.soundsSince(at, b, a, tl)\n",
		"templates/b/flix.toml":       "",
		"templates/b/src/Main.flix":   "    // App.addClock はまだ使わない\n",
		"templates/b/src/Sounds.flix": "    Timeline.soundsSince(at, b, a, tl)\n",
	})
	code, msg := run(t, root, "templates/a/src/Sounds.flix", "templates/b/src/Sounds.flix")
	if code != 1 || !strings.Contains(msg, "templates/a/src/Sounds.flix:1 [old]") || strings.Contains(msg, "templates/b/") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// 根のプロジェクトは、flix.toml を持つ下のプロジェクトの中身を数えない。flix.toml が無ければリポ全体が 1 つ。
func TestWhenProjectSkipsNestedProjects(t *testing.T) {
	rules := `{"rules":[{"id":"old","suffixes":[".flix"],"pattern":"\\bTimeline\\.soundsSince\\b","whenProject":"\\bApp\\.addClock\\b","hint":"Timeline.soundsOnClock"}]}`
	root := writeRepo(t, rules, "", map[string]string{
		"flix.toml":                 "",
		"src/Sounds.flix":           "    Timeline.soundsSince(at, b, a, tl)\n",
		"templates/a/flix.toml":     "",
		"templates/a/src/Main.flix": "    app |> App.addClock(spec)\n",
	})
	if code, msg := run(t, root, "src/Sounds.flix"); code != 0 {
		t.Fatalf("nested project must not count: %s", msg)
	}
	flat := writeRepo(t, rules, "", map[string]string{
		"src/Sounds.flix": "    Timeline.soundsSince(at, b, a, tl)\n",
		"other/Main.flix": "    app |> App.addClock(spec)\n",
	})
	if code, msg := run(t, flat, "src/Sounds.flix"); code != 1 {
		t.Fatalf("without flix.toml the whole repo is one project: %s", msg)
	}
}

// notice の規則は当たりを出すが止めない（終わりの値は 0）。数が多ければ 3 行だけ並べて残りを数で出す。
func TestNoticeRuleReportsWithoutFailing(t *testing.T) {
	rules := `{"rules":[{"id":"old-num","suffixes":[".flix"],"notice":true,"pattern":"\\bVec2\\.sqrt\\(","hint":"Num.sqrt"}]}`
	root := writeRepo(t, rules, "", map[string]string{
		"src/A.flix": "a = Vec2.sqrt(1.0)\nb = Vec2.sqrt(2.0)\nc = Vec2.sqrt(3.0)\nd = Vec2.sqrt(4.0)\n",
	})
	code, msg := run(t, root, "src/A.flix")
	if code != 0 || !strings.Contains(msg, "src/A.flix:1 [old-num]") || strings.Contains(msg, "src/A.flix:4") ||
		!strings.Contains(msg, "ほか 1 か所") || !strings.Contains(msg, "知らせ（止めない）4 か所。代わりに: Num.sqrt") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// 配られた forbid.json の除外は、そのファイルがこのリポジトリに無ければ裁かない。ある物とゲームの除外は裁く。
func TestEngineExemptForAbsentFileIsNotStale(t *testing.T) {
	engine := `{"rules":[{"id":"bands","suffixes":[".flix"],"pattern":"\\bDepth\\.Bands\\b","hint":"ZStack.of に積む"}],
	  "exempt":{"engine/src/Old.flix::bands":"engine の物","src/Here.flix::bands":"もう直した"}}`
	root := writeRepo(t, engine, `{"exempt":{"src/Gone.flix::bands":"消えた"}}`, map[string]string{
		"src/Here.flix": "let a = 1;\n",
	})
	if err := exec.Command("git", "-C", root, "init", "-q").Run(); err != nil {
		t.Fatal(err)
	}
	code, msg := run(t, root, "--all")
	if code != 1 || strings.Contains(msg, "engine/src/Old.flix") ||
		!strings.Contains(msg, "src/Here.flix::bands は") || !strings.Contains(msg, "src/Gone.flix::bands は") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// frame-diagnostics-in-system（engine の本物の規則）: frame・viewCtx・c の #diagnostics は止め、View の ctx#diagnostics は止めない。
func TestFrameDiagnosticsRuleStopsFrameButNotViewCtx(t *testing.T) {
	rules, err := LoadRules(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	var rule *Rule
	for i := range rules.List {
		if rules.List[i].ID == "frame-diagnostics-in-system" {
			rule = &rules.List[i]
		}
	}
	if rule == nil {
		t.Fatal("frame-diagnostics-in-system が無い")
	}
	only := &Rules{List: []Rule{*rule}}
	src := "    let w1 = World.withDiagnostics(frame#diagnostics, w)\n" +
		"    let lines = ctx#diagnostics |> Option.map(FrameDiagnostics.summaryLines)\n" +
		"    let d = viewCtx#diagnostics\n" +
		"    f(ctx#diagnostics)\n" +
		"    let e = c#diagnostics\n"
	hits := only.TextHits("src/Update.flix", src)
	lines := []int{}
	for _, h := range hits {
		lines = append(lines, h.Line)
	}
	if len(lines) != 3 || lines[0] != 1 || lines[1] != 3 || lines[2] != 5 {
		t.Fatalf("1・3・5 行目だけ当たるはず: %+v", hits)
	}
}
