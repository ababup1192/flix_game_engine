package fontbake

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// inputsRevision は InputsKey の組み方の版。材料を変えたら 1 上げる（前の fonts.json を新しいと見ない）。
const inputsRevision = 1

type projectFont struct {
	Name     string          `json:"name"`
	Path     string          `json:"path"`
	FontSize json.RawMessage `json:"fontSize"`
}

// InputsKey は生成した物が古いかを決める指紋: jar の指紋（engine・flix.toml・lib）・字の選び方（--glyphs）・
// 集めた字の集合・project.json の fonts（name・path・fontSize）とフォントのファイルの中身。
// WhyNot: project.json を丸ごと混ぜない — 窓の大きさや音を足すたびに、字に関係なく数十秒の作り直しになる。
func InputsKey(game, jarKey, glyphs, charset string) (string, error) {
	data, err := os.ReadFile(filepath.Join(game, "project.json"))
	if err != nil {
		return "", err
	}
	var p struct {
		Fonts []projectFont `json:"fonts"`
	}
	if err := json.Unmarshal(data, &p); err != nil {
		return "", fmt.Errorf("project.json が読めない: %w", err)
	}
	h := sha256.New()
	fmt.Fprintf(h, "rev=%d\njar=%s\nglyphs=%s\ncharset=%s\n", inputsRevision, jarKey, glyphs, charset)
	for _, f := range p.Fonts {
		path := f.Path
		if !filepath.IsAbs(path) {
			path = filepath.Join(game, path)
		}
		sum, err := fileSum(path)
		if err != nil {
			return "", fmt.Errorf("フォント %s が読めない: %w", f.Name, err)
		}
		fmt.Fprintf(h, "font=%s\t%s\t%s\t%s\n", f.Name, f.Path, string(f.FontSize), sum)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func fileSum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// IsFresh は outDir の fonts.json が inputs と同じ指紋を持ち、載っているアトラスが全部あるか。
// 字の漏れがあった回の fonts.json は指紋を持たないので、ここで新しいとは見ない。
func IsFresh(outDir, inputs string) bool {
	m, ok := readManifest(outDir)
	return ok && m.Inputs != "" && m.Inputs == inputs
}

// PackFiles は配る物に詰めるファイル（outDir からの名前）: fonts.json と、載っているアトラスとその .key。
// 1 本も載っていないか、揃っていなければ nil。
// WhyNot: フォルダを丸ごと詰めない — 書きかけで落ちた回の *.tmp（1 本 16MB 級）まで入る。
func PackFiles(outDir string) []string {
	m, ok := readManifest(outDir)
	if !ok || len(m.Fonts) == 0 {
		return nil
	}
	files := []string{"fonts.json"}
	for _, f := range m.Fonts {
		files = append(files, f.File, f.File+".key")
	}
	return files
}

type manifest struct {
	Inputs string `json:"inputs"`
	Fonts  []struct {
		File string `json:"file"`
	} `json:"fonts"`
}

// readManifest は fonts.json を読み、載っているアトラスとその .key が全部ある時だけ ok。
// .key が無い（.key を書かない古い engine で生成した）物は、デスクトップの起動が読まないので揃っていないと見る。
func readManifest(outDir string) (manifest, bool) {
	var m manifest
	data, err := os.ReadFile(filepath.Join(outDir, "fonts.json"))
	if err != nil || json.Unmarshal(data, &m) != nil {
		return m, false
	}
	for _, f := range m.Fonts {
		if !isRegular(filepath.Join(outDir, f.File)) || !isRegular(filepath.Join(outDir, f.File+".key")) {
			return m, false
		}
	}
	return m, true
}

func isRegular(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}
