// Package fpkgstore は engine の束の置き場（content-addressed store・bin/fpkg-store.sh が書く）を読む側と、
// ゲームの packages.lock の engine の節をそろえる所。
//
// 置き場は <engine>/build/fpkg-store/<名前>-<版>-<ハッシュ 16 字>/ の不変のフォルダで、current/<名前> が今の物を指す。
// 書くのは bin/fpkg-store.sh だけ（make sync-engine-full・sync-engine-full-web）。ここは読むだけ。
package fpkgstore

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// 置き場に入れる名前。
const (
	EngineFull    = "engine_full"
	EngineFullWeb = "engine_full_web"
)

// Dir は engine の置き場のフォルダ。
func Dir(engine string) string {
	return filepath.Join(engine, "build", "fpkg-store")
}

// Current は current/<名前> の指すエントリの絶対パス。無ければ ok=false。
//
// WhyNot: 呼ぶ側に symlink のまま渡さない — 読み始めた後で sync が current を次のエントリへ向けると、
// 同じ書き出しの中で前半と後半が別の束を読む。最初に 1 回だけ辿って、そのエントリを最後まで使う。
func Current(engine, name string) (string, bool) {
	dir, err := filepath.EvalSymlinks(filepath.Join(Dir(engine), "current", name))
	if err != nil {
		return "", false
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return "", false
	}
	return dir, true
}

// IsInStore は path（symlink なら辿った先）が engine の置き場の中か。
func IsInStore(engine, path string) bool {
	real, err := filepath.EvalSymlinks(path)
	if err != nil {
		return false
	}
	store, err := filepath.EvalSymlinks(Dir(engine))
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(store, real)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// Sha256File はファイルの中身の SHA-256（16 進）。
func Sha256File(path string) (string, error) {
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

var (
	lockKeyRe = regexp.MustCompile(`^(\s*(toml|fpkg)\s*=\s*)"sha256:[0-9a-f]*"`)
	lockSumRe = regexp.MustCompile(`^\s*(toml|fpkg)\s*=\s*"sha256:([0-9a-f]*)"`)
)

// EngineLockHeader は packages.lock の engine の節の見出し。
func EngineLockHeader(version string) string {
	return `[packages."github:ababup1192/flix_game_engine"."` + version + `"]`
}

// WithEngineLock は lock の engine の版 version の節の toml・fpkg の sha を差し替える。節が無ければ found=false（そのまま返す）。
//
// WhyNot: 節が無い時に足さない — flix が版を解決する時に自分で足す。足す形を真似ると flix の版が上がった時に食い違う。
func WithEngineLock(lock, version, tomlSum, fpkgSum string) (string, bool) {
	header := EngineLockHeader(version)
	lines := strings.Split(lock, "\n")
	in, found := false, false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") {
			in = trimmed == header
			found = found || in
			continue
		}
		if !in {
			continue
		}
		if m := lockKeyRe.FindStringSubmatch(line); m != nil {
			sum := fpkgSum
			if m[2] == "toml" {
				sum = tomlSum
			}
			lines[i] = lockKeyRe.ReplaceAllString(line, `${1}"sha256:`+sum+`"`)
		}
	}
	return strings.Join(lines, "\n"), found
}

// EngineLockSums は lock の engine の版 version の節にある toml・fpkg の sha。節が無ければ ok=false。
func EngineLockSums(lock, version string) (tomlSum, fpkgSum string, ok bool) {
	header := EngineLockHeader(version)
	in := false
	for _, line := range strings.Split(lock, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") {
			in = trimmed == header
			ok = ok || in
			continue
		}
		if !in {
			continue
		}
		if m := lockSumRe.FindStringSubmatch(line); m != nil {
			if m[1] == "toml" {
				tomlSum = m[2]
			} else {
				fpkgSum = m[2]
			}
		}
	}
	return tomlSum, fpkgSum, ok
}

// WriteFileAtomic は一時の名前に書いてから rename で置く（mode は perm）。
//
// WhyNot: os.WriteFile で上書きしない — 切り詰めてから書くので、同じファイルを読んでいる flix に半分の束が見え、
// 置き場の読むだけ（0444）のファイルを写した物なら書けずに落ちる。
func WriteFileAtomic(path string, body []byte, perm os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := tmp.Write(body); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Chmod(name, perm); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}
