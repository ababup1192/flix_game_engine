// Package jarshare は、同じ機械の作業場どうしで、同じ鍵の headless.jar を分け合う（docs/design/prebuilt-jar.md の段 1）。
//
//	fge jar key     --dispatcher F --flix-jar J --revision N [--dir .]   鍵（64 字）を出す
//	fge jar fetch   --dispatcher F --flix-jar J --revision N [--dir .]   置き場の jar を確かめてから build/headless へ写す（無ければ 1）
//	fge jar publish --dispatcher F --flix-jar J --revision N [--dir .]   build/headless の jar を置き場へ置く
//	fge jar prune                                                       置き場の古い物を消す（最後に使ってから 14 日・全部で 2 GB）
//
// 置き場は ~/.cache/flix-headless-jar/<鍵>/（FGE_JAR_CACHE で変える・off で使わない）。中身は headless.jar・source（作った時の
// 元の指紋）・FgeHeadlessMain.flix・sha256（jar の中身の SHA-256）・used（最後に使った時刻を更新時刻で持つ空のファイル）。
package jarshare

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/resident"
)

// Format は鍵の頭の字。鍵の作り方（何を混ぜるか）を変えたら 1 上げる。古い鍵の jar は誰からも引かれなくなり、prune で消える。
const Format = "fge-headless-jar/1"

// CacheEnv は置き場を変える環境変数（off か 0 で使わない）。
const CacheEnv = "FGE_JAR_CACHE"

// MaxAge と MaxBytes は置き場に残す量（依頼主の決定 2026-10-20: 14 日・2 GB）。
const (
	MaxAge   = 14 * 24 * time.Hour
	MaxBytes = int64(2) << 30
)

// 置き場の 1 本の中のファイルの名前。
const (
	jarName        = "headless.jar"
	manifestName   = "jar.manifest" // ゲームの根の build/headless に書く物
	sourceName     = "source"
	dispatcherName = "FgeHeadlessMain.flix"
	shaName        = "sha256"
	usedName       = "used"
)

// Inputs は鍵に混ぜる物。指紋（jar.manifest）に出ないのに jar の中身を変える物を足す。
type Inputs struct {
	Source     string // jar を作った元の指紋（resident.BuildSourceManifest: src・flix.toml・packages.lock）
	Dispatcher string // 入口の束（FgeHeadlessMain.flix）の中身
	FlixJarSHA string // jar を作るコンパイラ（flix.jar）の中身の SHA-256
	Revision   string // bin/headless-run の作り方の版（入口の拾い方・dispatcher の書き方）
}

// Key は鍵（64 字の 16 進）。どれかが空なら空（分け合わない）。
func Key(in Inputs) string {
	if in.Source == "" || in.Dispatcher == "" || in.FlixJarSHA == "" || in.Revision == "" {
		return ""
	}
	text := strings.Join([]string{
		Format,
		"source=" + in.Source,
		"dispatcher=" + sha256Hex([]byte(in.Dispatcher)),
		"flix=" + in.FlixJarSHA,
		"headless-run=" + in.Revision,
	}, "\n")
	return sha256Hex([]byte(text))
}

// CacheRoot は置き場の根。使わない時は空。
func CacheRoot(env func(string) string) string {
	switch v := env(CacheEnv); v {
	case "off", "0":
		return ""
	case "":
		home := env("HOME")
		if home == "" {
			return ""
		}
		return filepath.Join(home, ".cache", "flix-headless-jar")
	default:
		return v
	}
}

// headlessDir はゲームの根の build/headless。
func headlessDir(root string) string { return filepath.Join(root, "build", "headless") }

// dispatcherPath はゲームの根の、jar を作る写しの入口の束。
func dispatcherPath(root string) string {
	return filepath.Join(headlessDir(root), "proj", filepath.FromSlash(resident.DispatcherFile))
}

// Fetch は鍵の jar を確かめてから、root の build/headless へ写す。写せたら nil。jarManifest は root の今の指紋（BuildManifest）で、
// build/headless/jar.manifest に書く（空なら書かない）。
// 確かめるのは 3 つ: jar の中身の SHA-256 が sha256 と同じ・置いた時の元の指紋が今と同じ・置いた時の入口の束が今の物と同じ。
// どれかが違えば、その 1 本を置き場から消して error を返す（呼ぶ側は今どおり作る）。
//
// WhyNot: 作り手の jar.manifest を写さない — 作り手の指紋は lib の中身まで見ているので、lib をまだ落としていない作業場では
// 次の回も「古い」と見えて取り直し続ける。jar は同じ src・flix.toml・packages.lock から作った物なので、今の指紋を書いてよい。
func Fetch(cache, key string, in Inputs, root, jarManifest string) error {
	if cache == "" || key == "" {
		return errors.New("置き場か鍵が無い")
	}
	dir := filepath.Join(cache, key)
	if _, err := os.Stat(dir); err != nil {
		return err
	}
	if why := verify(dir, in); why != "" {
		discard(dir)
		return errors.New(why)
	}
	out := headlessDir(root)
	if err := os.MkdirAll(filepath.Dir(dispatcherPath(root)), 0o755); err != nil {
		return err
	}
	for _, f := range []struct{ from, to string }{
		{filepath.Join(dir, jarName), filepath.Join(out, jarName)},
		{filepath.Join(dir, dispatcherName), dispatcherPath(root)},
	} {
		if err := copyAtomic(f.from, f.to); err != nil {
			return err
		}
	}
	// WhyNot: jar.manifest を最後に書く — 途中で落ちた時に「指紋は合うのに jar が古い」形を残さない
	// （headless-run は jar.manifest が今の指紋と同じなら作り直さない）。
	if jarManifest != "" {
		if err := writeAtomic(filepath.Join(out, manifestName), jarManifest+"\n"); err != nil {
			return err
		}
	}
	touch(filepath.Join(dir, usedName))
	return nil
}

// verify は置き場の 1 本が今の入力と合うか。合わなければ訳（空なら合う）。
func verify(dir string, in Inputs) string {
	jarSHA, err := fileSHA(filepath.Join(dir, jarName))
	if err != nil {
		return "jar を読めない"
	}
	if want := strings.TrimSpace(readText(filepath.Join(dir, shaName))); want == "" || want != jarSHA {
		return "jar の SHA-256 が違う"
	}
	if strings.TrimSpace(readText(filepath.Join(dir, sourceName))) != in.Source {
		return "置いた時の元の指紋が今と違う"
	}
	if readText(filepath.Join(dir, dispatcherName)) != in.Dispatcher {
		return "置いた時の入口の束が今と違う"
	}
	return ""
}

// Publish は root の build/headless の jar を、鍵の 1 本として置き場へ置く。もう同じ鍵があれば何もしない。
// in.Source は jar を作った写し（build/headless/proj）から取った元の指紋を渡す（作っている間に root の src が保存されても、
// 作った jar の元と鍵がずれない）。
// 一時のフォルダに全部書いてから rename するので、同時に 2 本が同じ鍵を置こうとしても、置き場には揃った 1 本だけが残る。
func Publish(cache, key string, in Inputs, root string) error {
	if cache == "" || key == "" {
		return errors.New("置き場か鍵が無い")
	}
	final := filepath.Join(cache, key)
	if _, err := os.Stat(final); err == nil {
		touch(filepath.Join(final, usedName))
		return nil
	}
	return storeEntry(cache, key, in, filepath.Join(headlessDir(root), jarName))
}

// storeEntry は jarPath の jar を、鍵の 1 本として置き場へ置く（Publish と段 2 から落とした物が使う）。もう同じ鍵があれば何もしない。
func storeEntry(cache, key string, in Inputs, jarPath string) error {
	final := filepath.Join(cache, key)
	if _, err := os.Stat(final); err == nil {
		return nil
	}
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(cache, ".tmp-"+key[:12]+"-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	jarSHA, err := copyAndHash(jarPath, filepath.Join(tmp, jarName))
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(tmp, sourceName), []byte(in.Source+"\n"), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(tmp, dispatcherName), []byte(in.Dispatcher), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(tmp, usedName), nil, 0o644); err != nil {
		return err
	}
	// WhyNot: sha256 を最後に書く — rename の前に落ちても置き場には出ないが、念のため「sha256 がある＝揃っている」にしておく。
	if err := os.WriteFile(filepath.Join(tmp, shaName), []byte(jarSHA+"\n"), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, final); err != nil {
		if _, statErr := os.Stat(final); statErr == nil {
			return nil // 同じ鍵を相手が先に置いた
		}
		return err
	}
	return nil
}

// Entry は置き場の 1 本（Prune が並べる）。
type Entry struct {
	Key   string
	Used  time.Time
	Bytes int64
}

// PlanPrune は消す鍵を決める（純粋）。最後に使ってから maxAge より古い物と、新しい順に足して maxBytes を超えた分。
func PlanPrune(entries []Entry, now time.Time, maxAge time.Duration, maxBytes int64) []string {
	sorted := append([]Entry(nil), entries...)
	sort.Slice(sorted, func(i, j int) bool {
		if !sorted[i].Used.Equal(sorted[j].Used) {
			return sorted[i].Used.After(sorted[j].Used)
		}
		return sorted[i].Key < sorted[j].Key
	})
	var drop []string
	var kept int64
	for _, e := range sorted {
		if now.Sub(e.Used) > maxAge || kept+e.Bytes > maxBytes {
			drop = append(drop, e.Key)
			continue
		}
		kept += e.Bytes
	}
	return drop
}

// Prune は置き場の古い物を消し、消した数を返す。途中の一時のフォルダ（.tmp-*）は 1 時間より古い物だけ消す。
func Prune(cache string, now time.Time) (int, error) {
	if cache == "" {
		return 0, nil
	}
	items, err := os.ReadDir(cache)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	var entries []Entry
	removed := 0
	for _, it := range items {
		path := filepath.Join(cache, it.Name())
		if strings.HasPrefix(it.Name(), ".") {
			if info, err := it.Info(); err == nil && now.Sub(info.ModTime()) > time.Hour {
				_ = os.RemoveAll(path)
			}
			continue
		}
		if !it.IsDir() {
			continue
		}
		used := now.Add(-MaxAge - time.Hour) // used が無い 1 本は古い物として扱う
		if info, err := os.Stat(filepath.Join(path, usedName)); err == nil {
			used = info.ModTime()
		}
		entries = append(entries, Entry{Key: it.Name(), Used: used, Bytes: dirBytes(path)})
	}
	for _, key := range PlanPrune(entries, now, MaxAge, MaxBytes) {
		discard(filepath.Join(cache, key))
		removed++
	}
	return removed, nil
}

// discard は置き場の 1 本を消す。先に別名へ rename するので、消している途中の 1 本を誰かが Fetch で読むことはない。
func discard(dir string) {
	trash := filepath.Join(filepath.Dir(dir), ".trash-"+filepath.Base(dir)+"-"+randomSuffix())
	if err := os.Rename(dir, trash); err != nil {
		return
	}
	_ = os.RemoveAll(trash)
}

// FileSHA はファイルの中身の SHA-256（flix.jar の鍵に使う）。
func FileSHA(path string) (string, error) { return fileSHA(path) }

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

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func readText(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

func touch(path string) {
	now := time.Now()
	if err := os.Chtimes(path, now, now); err != nil {
		_ = os.WriteFile(path, nil, 0o644)
	}
}

// writeAtomic は text を path の隣の一時のファイルへ書いてから rename する。
func writeAtomic(path, text string) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(text); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// copyAtomic は from を to の隣の一時のファイルへ写してから rename する。
func copyAtomic(from, to string) error {
	_, err := copyAndHash(from, to)
	return err
}

// copyAndHash は from を to へ一時のファイル経由で写し、写した中身の SHA-256 を返す。
func copyAndHash(from, to string) (string, error) {
	src, err := os.Open(from)
	if err != nil {
		return "", err
	}
	defer src.Close()
	tmp, err := os.CreateTemp(filepath.Dir(to), "."+filepath.Base(to)+".tmp-")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, h), src); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(tmp.Name(), to); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func dirBytes(dir string) int64 {
	var total int64
	_ = filepath.Walk(dir, func(_ string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total
}

func randomSuffix() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
