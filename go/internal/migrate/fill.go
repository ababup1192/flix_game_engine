package migrate

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// runFill は鍵だけ撮った記録の欠けた PNG を埋める（新しい記録を基準に上げる前に流す。基準は全部の PNG を持つ約束）。
// 出所は、同じ親フォルダのほかの記録の同じ鍵のコマと render-cache。埋められないコマが残れば 1（shoot --full で撮り直す）。
func runFill(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintf(stderr, "migrate fill: 記録のフォルダを 1 つ渡す\n%s\n", usage)
		return 2
	}
	root := args[0]
	side, err := LoadSide(root)
	if err != nil {
		fmt.Fprintln(stderr, "migrate fill:", err)
		return 2
	}
	keys := newDrawKeys()
	byKey := map[string]string{}
	siblings, _ := os.ReadDir(filepath.Dir(filepath.Clean(root)))
	for _, e := range siblings {
		other := filepath.Join(filepath.Dir(filepath.Clean(root)), e.Name())
		if !e.IsDir() || filepath.Clean(other) == filepath.Clean(root) {
			continue
		}
		if s, err := LoadSide(other); err == nil {
			indexPNGs(keys, s, byKey)
		}
	}
	indexPNGs(keys, side, byKey)
	cache := cacheDirForCopy()
	filled, left := 0, 0
	for _, t := range append(allTapes(side), restoreTapes(side)...) {
		for _, f := range t.Frames {
			dst := filepath.Join(t.Dir, f.File)
			if fileExists(dst) {
				continue
			}
			k := keys.of(t.Dir, f.File)
			src := ""
			switch {
			case !validKey(k):
			case byKey[k] != "":
				src = byKey[k]
			case cache != "" && fileExists(cachedPNG(cache, k)):
				src = cachedPNG(cache, k)
			}
			if src == "" {
				left++
				if left <= 5 {
					fmt.Fprintf(stderr, "  埋められない: %s（鍵 %s）\n", dst, k)
				}
				continue
			}
			if err := copyFile(src, dst); err != nil {
				fmt.Fprintln(stderr, "migrate fill:", err)
				return 1
			}
			filled++
		}
	}
	fmt.Fprintf(stdout, "migrate fill: %s の PNG を %d 枚埋めた（埋められない %d 枚）\n", root, filled, left)
	if left > 0 {
		fmt.Fprintln(stderr, "migrate fill: 埋められないコマがある（render-cache から消えた）。基準にするなら migrate shoot --full で撮り直す")
		return 1
	}
	return 0
}

// indexPNGs は記録 s の PNG のあるコマを鍵で引けるようにする（先に入れた物が勝つ）。
func indexPNGs(keys *drawKeys, s *Side, byKey map[string]string) {
	for _, t := range append(allTapes(s), restoreTapes(s)...) {
		for _, f := range t.Frames {
			p := filepath.Join(t.Dir, f.File)
			if k := keys.of(t.Dir, f.File); validKey(k) && byKey[k] == "" && fileExists(p) {
				byKey[k] = p
			}
		}
	}
}

// restoreTapes は古いセーブの読み戻しのコマを、tape と同じ形（Dir と Frames）で並べる。
func restoreTapes(s *Side) []*Tape {
	var out []*Tape
	for _, name := range sortedKeys(s.Restores) {
		r := s.Restores[name]
		out = append(out, &Tape{Dir: r.Dir, Frames: r.Frames})
	}
	return out
}
