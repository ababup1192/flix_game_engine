// Package mvncache は Flix のパッケージの lib/cache（Maven の取り物の置き場）を、共有の置き場への symlink にする。
//
// Flix は置き場を <パッケージ>/lib/cache に決め打ちしていて、無ければ自分で作って Maven Central へ取りに行く。
// flix を起こす前に Link を通せば、新しいパッケージ・ゲーム・worktree でも共有の置き場を使う。
//
// 移し方の規則は bin/mvn-cache-share.sh と同じ（片方を直したらもう片方も直す）。同時に使っても壊れない根拠もそちら。
package mvncache

import (
	"bytes"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// Dir は共有の置き場のパス。MVN_CACHE があればそれ、無ければ <ユーザーの cache>/flix_game_engine/mvn-cache。
func Dir() (string, error) {
	if d := os.Getenv("MVN_CACHE"); d != "" {
		return d, nil
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "flix_game_engine", "mvn-cache"), nil
}

// Link は pkg/lib/cache を共有の置き場への symlink にする。何かした時だけ人へ見せる 1 行を返す（何もしなければ ""）。
//
// symlink なら何もしない（指す先も辿らない。毎回の代金を Lstat 1 回に収める）。無ければ張る。
// 実体のフォルダなら中身を置き場へ移してから張る（置き場に無い物は移し、同じ物は消し、違う物は lib/cache.unmerged に残す）。
//
// WhyNot: 失敗を返さない — symlink を張れない機械（開発者モードでない Windows など）でも、張らなければ Flix が
// 今まで通り lib/cache を作って取りに行くだけで、flix の呼び出しは通る。
func Link(pkg string) string {
	cache := filepath.Join(pkg, "lib", "cache")
	info, err := os.Lstat(cache)
	if err == nil && info.Mode()&fs.ModeSymlink != 0 {
		return ""
	}
	if _, terr := os.Stat(filepath.Join(pkg, "flix.toml")); terr != nil {
		return ""
	}
	if err != nil && !os.IsNotExist(err) {
		return ""
	}
	if err == nil && !info.IsDir() {
		return ""
	}
	dir, derr := Dir()
	if derr != nil || os.MkdirAll(dir, 0o755) != nil {
		return ""
	}
	shared, serr := filepath.EvalSymlinks(dir)
	if serr != nil {
		return ""
	}
	if err != nil {
		if os.MkdirAll(filepath.Dir(cache), 0o755) != nil || os.Symlink(shared, cache) != nil {
			return ""
		}
		return fmt.Sprintf("[mvn-cache] %s → %s を張った", cache, shared)
	}
	return mergeAndLink(cache, shared)
}

// mergeAndLink は実体のフォルダ cache の中身を shared へ移し、cache を shared への symlink にする。
func mergeAndLink(cache, shared string) string {
	// WhyNot: Windows では移さない — 使用中かを見る口（lsof）が無く、開いたファイルは動かせず途中で止まる。
	if runtime.GOOS == "windows" {
		return ""
	}
	unmerged := cache + ".unmerged"
	if exists(unmerged) {
		return fmt.Sprintf("[mvn-cache] %s を移さずに飛ばした（前の %s が残っている。中を見て片付けてから make mvn-cache-share）", cache, unmerged)
	}
	// WhyNot: 開いているプロセスがある間は動かさない — 取っている最中の .part とロックを置き場の外に置き去りにする。
	if out, _ := exec.Command("lsof", "+D", cache).Output(); bytes.Count(out, []byte("\n")) > 1 {
		return fmt.Sprintf("[mvn-cache] %s は使用中なので移さなかった（flix を止めてから make mvn-cache-share）", cache)
	}
	// WhyNot: 先に張れるかを試す — 中身を移した後で張れないと分かると、lib/cache が無いまま取り直しになる。
	probe := fmt.Sprintf("%s.link-%d", cache, os.Getpid())
	if os.Symlink(shared, probe) != nil {
		return ""
	}
	conflicts := 0
	var left []string
	_ = filepath.WalkDir(cache, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		name := d.Name()
		// WhyNot: .lock と .part は移さない — 使っていないことは lsof で確かめた後なので、どちらも落ちたプロセスの残り。
		if strings.HasSuffix(name, ".lock") || strings.HasSuffix(name, ".part") {
			return nil
		}
		rel, _ := filepath.Rel(cache, p)
		// WhyNot: lib/cache/cache/ の下は 1 階層上げる — 在る lib/cache へ cp -R で写すと 1 階層深く入り、coursier からは見えない。
		to := filepath.Join(shared, filepath.FromSlash(strings.TrimPrefix(filepath.ToSlash(rel), "cache/")))
		switch {
		case !exists(to):
			if moveFile(p, to) != nil {
				left = append(left, rel)
			}
		case sameContent(p, to):
			_ = os.Remove(p)
		default:
			conflicts++
			left = append(left, rel)
		}
		return nil
	})
	// WhyNot: 消すのは移せなかったファイルが無い時だけ — 残っているのは置き場と中身の違う物で、捨てると戻せない。
	if len(left) == 0 {
		if os.RemoveAll(cache) != nil || os.Rename(probe, cache) != nil {
			_ = os.Remove(probe)
			return ""
		}
		return fmt.Sprintf("[mvn-cache] %s の中身を %s へ移して symlink にした", cache, shared)
	}
	if os.Rename(cache, unmerged) != nil || os.Rename(probe, cache) != nil {
		_ = os.Remove(probe)
		return ""
	}
	return fmt.Sprintf("[mvn-cache] %s を symlink にした（置き場と中身の違う %d 件・移せなかった %d 件を %s に残した）",
		cache, conflicts, len(left)-conflicts, unmerged)
}

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// moveFile は rename し、別のディスクで rename できなければ写してから消す。
func moveFile(from, to string) error {
	if err := os.MkdirAll(filepath.Dir(to), 0o755); err != nil {
		return err
	}
	if os.Rename(from, to) == nil {
		return nil
	}
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := fmt.Sprintf("%s.mvncache-%d", to, os.Getpid())
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, to); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Remove(from)
}

func sameContent(a, b string) bool {
	ia, err := os.Stat(a)
	if err != nil {
		return false
	}
	ib, err := os.Stat(b)
	if err != nil || ia.Size() != ib.Size() {
		return false
	}
	ba, err := os.ReadFile(a)
	if err != nil {
		return false
	}
	bb, err := os.ReadFile(b)
	return err == nil && bytes.Equal(ba, bb)
}

// Off は pkg/lib/cache が共有の置き場を向いていない時に、その様子（「実体のフォルダ」「別の所を指す symlink」）を返す。
// 向いているか、まだ無ければ ""（無い物は次に flix を起こす時に張られる）。
func Off(pkg string) string {
	cache := filepath.Join(pkg, "lib", "cache")
	info, err := os.Lstat(cache)
	if err != nil {
		return ""
	}
	if info.Mode()&fs.ModeSymlink == 0 {
		if info.IsDir() {
			return "実体のフォルダ"
		}
		return ""
	}
	dir, err := Dir()
	if err != nil {
		return ""
	}
	target, err := os.Readlink(cache)
	if err != nil {
		return ""
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(cache), target)
	}
	if filepath.Clean(target) == filepath.Clean(dir) {
		return ""
	}
	want, err1 := filepath.EvalSymlinks(dir)
	got, err2 := filepath.EvalSymlinks(cache)
	if err1 == nil && err2 == nil && want == got {
		return ""
	}
	return "別の所を指す symlink"
}
