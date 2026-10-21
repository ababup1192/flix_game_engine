package docrefs

import (
	"os/exec"
	"strings"
	"testing"
)

// .flix のコメントは ` ` の中と、地の文の Mod.name・パス・path:行 の形の語だけを拾う。字の中の // ・消し線・予定の印・
// ただの語は拾わない。
func TestScanFlixCommentsReadsOnlyNameAndPathShapes(t *testing.T) {
	text := "/// 入口は `World.moveTo`・View.frame を読む（src/World.flix:3）。\n" +
		"    let s = \"// not World.fake\";   // 地の文の World.ghost と、ただの語 hello\n" +
		"// 消した ~~World.gone~~ と予定の `World.later`（予定）\n" +
		"def plain(): Int32 = 1\n"
	ext := map[string]bool{"flix": true, "md": true}
	var got []string
	for _, r := range ScanFlixComments(text, ext, []string{"（予定）"}) {
		s := r.Text
		if r.Planned {
			s += "（予定）"
		}
		got = append(got, s)
	}
	want := "World.moveTo View.frame src/World.flix:3 World.ghost World.later（予定）"
	if strings.Join(got, " ") != want {
		t.Errorf("got %q\nwant %q", strings.Join(got, " "), want)
	}
}

// 全部を見る時、.flix のコメントの物は上限のファイル（lint/limits/doc-refs-flix.json）と比べる: 超えれば並べて止め、
// 同じなら並べず、減っていれば上限を下げるよう言って止める（md の物はいつも並べる）。
func TestFlixCommentHitsAreRatchetedByTheLimitFile(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "src/Extra.flix", "/// 消えた `World.ghost` を指す。\ndef extra(): Int32 = 1\n")
	has := func(got []string) bool {
		for _, g := range got {
			if strings.HasPrefix(g, "src/Extra.flix:1 World.ghost") {
				return true
			}
		}
		return false
	}
	if got := hitsOf(t, root); !has(got) {
		t.Errorf("上限 0 で .flix の物を並べていない: %v", got)
	}
	write(t, root, "lint/limits/doc-refs-flix.json", "{\"limit\": 1}\n")
	if got := hitsOf(t, root); has(got) || len(got) != 7 {
		t.Errorf("上限と同じなら md の 7 件だけ: %v", got)
	}
	write(t, root, "lint/limits/doc-refs-flix.json", "{\"limit\": 3}\n")
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, nil)
	if err != nil || code != 1 || !strings.Contains(errOut.String(), "lint/limits/doc-refs-flix.json の limit を 1 に下げる") {
		t.Errorf("減った時に下げるよう言っていない: code %d err %v\n%s", code, err, errOut.String())
	}
}

// 名指しの .flix（コミットの時の触ったファイル）は、HEAD の中身のコメントより増えた物だけで止める。
func TestNamedFlixStopsOnlyOnHitsAddedSinceHead(t *testing.T) {
	root := gameRepo(t)
	write(t, root, "src/Extra.flix", "/// 消えた `World.ghost` を指す。\ndef extra(): Int32 = 1\n")
	for _, args := range [][]string{{"init", "-q"}, {"add", "."}, {"-c", "user.email=t@example.test", "-c", "user.name=t", "commit", "-q", "-m", "fixture"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = root
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Skipf("git が使えない: %v %s", err, out)
		}
	}
	if got := hitsOf(t, root, "src/Extra.flix"); len(got) != 0 {
		t.Errorf("HEAD からある物だけなら止めない: %v", got)
	}
	write(t, root, "src/Extra.flix", "/// 消えた `World.ghost` を指す。\n/// 新しく `World.phantom` も。\ndef extra(): Int32 = 1\n")
	if got := hitsOf(t, root, "src/Extra.flix"); strings.Join(got, "\n") != "src/Extra.flix:2 World.phantom doc-refs.name" {
		t.Errorf("増えた 1 件だけ: %v", got)
	}
}
