// Package headlessjar は、bin/headless-run が作るゲームの jar（build/headless/headless.jar）の場所を読む 1 か所。
//
// macOS と Linux では headless.jar がそのまま jar。Windows の headless-run は、開いている jar を差し替えられないので
// 指紋の入った名前（headless-<指紋>.jar）で置き、headless.jar にはその名前だけを書いた小さなファイルを置く（plans/windows.md の 12 節 K2）。
// jar を名前で直に読む所（dist・jarshare・resident）はここを通して、どちらの形でも本物の jar を読む。
package headlessjar

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
)

// Rel はゲームの根から見た今の名前。
var Rel = filepath.Join("build", "headless", "headless.jar")

// maxPointerSize は指す先を書いたファイルとして読む大きさの上限（jar を丸ごと読まないため）。
const maxPointerSize = 512

// zipMagic は jar（zip）の頭の 4 バイト。
var zipMagic = []byte("PK\x03\x04")

// Path はゲームの根 root の、今の名前が指す jar のパス。
func Path(root string) string { return Resolve(filepath.Join(root, Rel)) }

// Resolve は今の名前 path が指す jar のパス。path が jar そのもの・読めない・指す先が無い時は path を返す。
func Resolve(path string) string {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxPointerSize {
		return path
	}
	b, err := os.ReadFile(path)
	if err != nil || bytes.HasPrefix(b, zipMagic) {
		return path
	}
	name := strings.TrimSpace(string(b))
	// WhyNot: 書かれた字をパスとしてそのまま使わない — 同じフォルダの jar の名前だけを指す決まりにしておけば、
	// 壊れた・別の版の headless-run が書いた字で build/headless の外を読みに行かない。
	if name == "" || strings.ContainsAny(name, `/\`) || !strings.HasSuffix(name, ".jar") {
		return path
	}
	target := filepath.Join(filepath.Dir(path), name)
	if t, err := os.Stat(target); err != nil || !t.Mode().IsRegular() {
		return path
	}
	return target
}
