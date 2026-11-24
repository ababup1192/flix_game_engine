package proposal

// 何を守るか: ダッシュボードの「送る」頁が、今の返事の選択で開き、選べる節が無くても送る帯を出すこと。
// post の素材を写す時に、書いた人のキーの順を崩さずにパスだけを書き換えること。

import (
	"strings"
	"testing"
)

const choiceManifest = `{"title": "t", "sections": [{"id": "A", "options": [
  {"id": "A1", "rec": true, "media": ["a1.png"]}, {"id": "A2", "media": [{"src": "a2.png", "caption": "c"}]}]}]}`

func mustParse(t *testing.T, data string) *Manifest {
	t.Helper()
	m, errs := ParseManifest("post.json", []byte(data))
	if len(errs) > 0 {
		t.Fatal(errs)
	}
	return m
}

func TestSendPageOpensWithReplyPicks(t *testing.T) {
	html, _ := Page(mustParse(t, choiceManifest), t.TempDir(), PageOptions{Send: true, Picks: map[string]string{"A": "A2"}})
	if !strings.Contains(html, `value="A2" checked`) || strings.Contains(html, `value="A1" checked`) {
		t.Fatalf("返事の A2 で開かない:\n%s", html)
	}
}

func TestSendPageShowsBarWithoutChoices(t *testing.T) {
	html, _ := Page(mustParse(t, `{"title": "見るだけ", "sections": [{"title": "x"}]}`), t.TempDir(), PageOptions{Send: true, SendURL: "/r"})
	if !strings.Contains(html, `data-send="/r"`) || !strings.Contains(html, "<textarea") {
		t.Fatalf("選べる節の無い頁に送る帯が無い:\n%s", html)
	}
}

func TestStaticPageHasNoSendBar(t *testing.T) {
	html, _ := Page(mustParse(t, choiceManifest), t.TempDir(), PageOptions{})
	if strings.Contains(html, "<textarea") {
		t.Fatal("静的な頁に送る帯が出た")
	}
}

func TestRewriteMediaKeepsKeyOrder(t *testing.T) {
	m := mustParse(t, choiceManifest)
	m.RewriteMedia(map[string]string{"a1.png": "x1.png", "a2.png": "x2.png"})
	got := strings.Join(strings.Fields(string(m.JSON())), "")
	want := `{"title":"t","sections":[{"id":"A","options":[{"id":"A1","rec":true,"media":["x1.png"]},{"id":"A2","media":[{"src":"x2.png","caption":"c"}]}]}]}`
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestSetAppendsNewKeyAtEnd(t *testing.T) {
	m := mustParse(t, `{"title": "t"}`)
	if err := m.Set("origin", map[string]string{"branch": "b"}); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(strings.Fields(string(m.JSON())), ""); got != `{"title":"t","origin":{"branch":"b"}}` {
		t.Fatal(got)
	}
}
