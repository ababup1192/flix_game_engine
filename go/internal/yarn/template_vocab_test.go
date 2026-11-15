package yarn

import (
	"os"
	"path/filepath"
	"testing"
)

// soundNovelRoot はリポジトリの templates/sound-novel-starter（このパッケージから数えた場所）。
func soundNovelRoot(t *testing.T) string {
	t.Helper()
	root := filepath.Join("..", "..", "..", "templates", "sound-novel-starter")
	if _, err := os.Stat(filepath.Join(root, "assets", "talk", "vocab.json")); err != nil {
		t.Skipf("テンプレートが無い: %v", err)
	}
	return root
}

// 作例の vocab.json と novel.cast.json で、fx の on= の照らしに toma の口（toma.mouth）が拾われる。
func TestTemplateFxOnPicksTheCastMouth(t *testing.T) {
	v, _ := loadV2(t, soundNovelRoot(t))
	spec := v.Specs["fx"]
	if spec == nil {
		t.Fatal("fx の表が無い")
	}
	for _, p := range spec.Params {
		if p.Name == "on" && p.refNames["toma.mouth"] {
			return
		}
	}
	t.Errorf("fx の on に toma.mouth が無い")
}
