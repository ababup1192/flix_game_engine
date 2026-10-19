package resident

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// ManifestFile は jar を作った時の中身の指紋を置く所（ゲームの根からの相対）。
var ManifestFile = filepath.Join("build", "headless", "jar.manifest")

// maxLinkDepth は lib の中で symlink を辿る深さの上限（輪になった symlink で止まらないため）。
const maxLinkDepth = 32

// BuildManifest は jar の中身を決める物（src・flix.toml・lib・java の旗）の指紋を 64 字で返す。
//
// WhyNot: 更新時刻を使わないのは、checkd が macOS の見回りの遅れで書き換え前のソースを
// 検査して緑を返したのと同じく、時刻は中身が変わった証にならないため。
func BuildManifest(root, java, opts string) (string, error) {
	h := sha256.New()
	for _, part := range []string{"src", "flix.toml", "lib"} {
		files, err := listFiles(root, part)
		if err != nil {
			return "", err
		}
		for _, rel := range files {
			sum, err := fileSHA(filepath.Join(root, filepath.FromSlash(rel)))
			if err != nil {
				return "", err
			}
			fmt.Fprintf(h, "%s\x00%s\n", rel, sum)
		}
	}
	fmt.Fprintf(h, "java=%s\nopts=%s\n", java, opts)
	return hex.EncodeToString(h.Sum(nil)), nil
}

// listFiles は root/part の下の全ファイルを、根からの相対パス（/ 区切り）の字の順で返す。
// part が無ければ空。symlink は先を辿る。
func listFiles(root, part string) ([]string, error) {
	var out []string
	var walk func(abs, rel string, depth int) error
	walk = func(abs, rel string, depth int) error {
		info, err := os.Stat(abs)
		if err != nil {
			if os.IsNotExist(err) && rel == part {
				return nil
			}
			return err
		}
		if !info.IsDir() {
			out = append(out, rel)
			return nil
		}
		if depth > maxLinkDepth {
			return fmt.Errorf("%s: フォルダが深すぎる（symlink の輪？）", rel)
		}
		entries, err := os.ReadDir(abs)
		if err != nil {
			return err
		}
		for _, e := range entries {
			if err := walk(filepath.Join(abs, e.Name()), rel+"/"+e.Name(), depth+1); err != nil {
				return err
			}
		}
		return nil
	}
	if err := walk(filepath.Join(root, part), part, 0); err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}

func fileSHA(path string) (string, error) {
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

// ReadManifest は jar.manifest の 1 行目（無ければ空）。
func ReadManifest(root string) string {
	raw, err := os.ReadFile(filepath.Join(root, ManifestFile))
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(raw), "\n")
	return strings.TrimSpace(line)
}
