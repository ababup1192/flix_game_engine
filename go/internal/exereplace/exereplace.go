// Package exereplace は実行ファイル（bin/fge-go・fge-go.exe）を置き換える。決まりの本文は plans/windows.md の 11 節。
//
// macOS と Linux は別名に書いてから rename する。Windows は走っている exe を上書きも削除もできないが名前は替えられるので、
// 今の物を <名前>.old に退けてから新しい物を置き、.old は次に起動した時に RemoveOld が消す。
package exereplace

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// OldSuffix は Windows で退けた exe に付ける名前の後ろ。
const OldSuffix = ".old"

// Copy は src の中身を dest に置く（実行ビット付き）。goos は runtime.GOOS（テストは "windows" を渡す）。
func Copy(src, dest, goos string) error {
	body, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return Write(dest, body, goos)
}

// Write は body を dest に置く（実行ビット付き）。
//
// WhyNot: dest を開いて上書きしない — macOS は同じ inode の中身が書き換わると覚えていた署名の検証結果を捨て、
// 次の実行を SIGKILL する。Windows では走っている exe を開いて書けない。
func Write(dest string, body []byte, goos string) error {
	dir := filepath.Dir(dest)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(dest)+".new-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	_, werr := tmp.Write(body)
	if cerr := tmp.Close(); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Chmod(tmpName, 0o755)
	}
	if werr != nil {
		os.Remove(tmpName)
		return werr
	}
	if goos == "windows" {
		if err := moveAside(dest); err != nil {
			os.Remove(tmpName)
			return err
		}
	}
	if err := os.Rename(tmpName, dest); err != nil {
		os.Remove(tmpName)
		return err
	}
	return nil
}

// moveAside は dest を dest.old に退ける（dest が無ければ何もしない）。
//
// WhyNot: 前の .old が消せない時（その exe がまだ走っている）に止めない — 退ける先が埋まっているだけなので、
// 番号を付けた別の名前に退ける。RemoveOld がまとめて消す。
func moveAside(dest string) error {
	if _, err := os.Lstat(dest); os.IsNotExist(err) {
		return nil
	}
	old := dest + OldSuffix
	_ = os.Remove(old)
	if err := os.Rename(dest, old); err == nil {
		return nil
	}
	for i := 1; i < 10; i++ {
		alt := fmt.Sprintf("%s%s%d", dest, OldSuffix, i)
		_ = os.Remove(alt)
		if err := os.Rename(dest, alt); err == nil {
			return nil
		}
	}
	return fmt.Errorf("%s を %s へ退けられません（その fge が走っていないか確かめてください）", dest, old)
}

// RemoveOld は exe の隣の退けた物（<exe>.old・<exe>.old1…）を消す。Windows でだけ働く（他の OS は退けないので何も無い）。
// 消せない物（まだ走っている）は次の起動に回す。
func RemoveOld(exe, goos string) {
	if goos != "windows" || exe == "" {
		return
	}
	dir, base := filepath.Dir(exe), filepath.Base(exe)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if isOldName(e.Name(), base) {
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
}

// isOldName は name が base を退けた名前（base.old か base.old<数字>）か。
func isOldName(name, base string) bool {
	rest, ok := strings.CutPrefix(name, base+OldSuffix)
	if !ok {
		return false
	}
	for _, c := range rest {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}
