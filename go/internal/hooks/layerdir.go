package hooks

import (
	"io/fs"
	"os"
	"path/filepath"
)

// layerBasePkg は層が土台にするパッケージ。層の検査用フォルダは src/<layerBasePkg> にこの src を並べる。
const layerBasePkg = "engine"

// layerRoot は `make sync-layers` が層の検査用フォルダを置く所。
const layerRoot = ".layers"

// CheckDir は pkg を型検査するフォルダを返す。engine の層なら .layers/<名前> で、それ以外は pkg のまま。
// WhyNot: 層を元のフォルダで検査しない — 土台の engine の src が無いので、どの層も「名前が無い」で必ず赤くなり、本物の赤が埋もれる。
func CheckDir(root, pkg string) string {
	real, err := filepath.EvalSymlinks(root)
	if err != nil || filepath.Dir(pkg) != real {
		return pkg
	}
	name := filepath.Base(pkg)
	layer := filepath.Join(real, layerRoot, name)
	if !isFile(filepath.Join(layer, "flix.toml")) {
		return pkg
	}
	refreshLayerLinks(real, name, layer)
	return layer
}

// refreshLayerLinks は `make sync-layers` のリンクの並びへ、足された物を足し、消された物を外す。
// WhyNot: 丸ごと作り直さない — 別の担当が同じフォルダで検査している最中にソースが消え、偽の赤になる。
func refreshLayerLinks(root, name, layer string) {
	parts := [][2]string{
		{filepath.Join(root, layerBasePkg, "src"), filepath.Join(layer, "src", layerBasePkg)},
		{filepath.Join(root, name, "src"), filepath.Join(layer, "src", name)},
		{filepath.Join(root, name, "test"), filepath.Join(layer, "test")},
	}
	for _, part := range parts {
		addMissingLinks(part[0], part[1])
	}
	removeDanglingLinks(filepath.Join(layer, "src"))
	removeDanglingLinks(filepath.Join(layer, "test"))
}

func addMissingLinks(from, to string) {
	_ = filepath.WalkDir(from, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(from, path)
		if err != nil {
			return nil
		}
		link := filepath.Join(to, rel)
		if _, err := os.Lstat(link); err == nil {
			return nil
		}
		if os.MkdirAll(filepath.Dir(link), 0o755) == nil {
			_ = os.Symlink(path, link)
		}
		return nil
	})
}

func removeDanglingLinks(dir string) {
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.Type()&fs.ModeSymlink == 0 {
			return nil
		}
		if _, err := os.Stat(path); err != nil {
			_ = os.Remove(path)
		}
		return nil
	})
}
