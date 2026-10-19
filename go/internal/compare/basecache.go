package compare

// 基準の側の描き出しを取っておく。
//
// 基準のコミット・基準のエンジン・描く口が同じなら描き出しは同じになる（ゲームの描き出しは
// 決まった dt で回し、乱数も種から導く）。そこで基準を描いて拾った物（動画・絵・音の表・音）を
// ~/.flix_ge_studio/compare-cache/<鍵>/ に写しておき、次からは基準の worktree も描き出しも飛ばして、
// 写しを基準として比べる。鍵の考え方はエンジンの DrawHash と同じ: 絵に効く入力を 1 つでも
// 決められなければ取っておかない・使わない（偽の緑より、描き直す方を選ぶ）。
//
// 鍵に入れる物: ゲームの名前・基準のコミット・描く口・基準側のエンジンの fpkg の中身・
// lib/external と lib/cache の名前と大きさ・java と ffmpeg の版・描き出しが読む環境変数の値。
// 取っておかない時: 基準の描き出しに失敗した口があった（機械の都合で落ちた結果を持ち越さない）。
// FGE_COMPARE_NO_CACHE=1 で使わない。

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/useengine"
	"github.com/ababup1192/flix_game_engine/go/internal/videos"
)

// baseCacheDir は基準の写しの置き場（鍵ごと）。使わない時・鍵を決められない時は空。
func baseCacheDir(o Options, sha, engineDir string) string {
	if os.Getenv("FGE_COMPARE_NO_CACHE") == "1" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	key := baseCacheKey(o, sha, engineDir)
	if key == "" {
		return ""
	}
	return filepath.Join(home, ".flix_ge_studio", "compare-cache", sha[:min(10, len(sha))]+"-"+key[:16])
}

// baseCacheKey は基準の描き出しに効く入力を畳んだ SHA-256。決められない物があれば空。
func baseCacheKey(o Options, sha, engineDir string) string {
	fpkg, err := useengine.FindFpkg(engineDir)
	if err != nil {
		return ""
	}
	engineSum, err := hashFile(fpkg)
	if err != nil {
		return ""
	}
	var steps []string
	for _, s := range renderSteps(o) {
		steps = append(steps, strings.Join(s[1:], " "))
	}
	parts := []string{
		"fge-compare-base/1",
		filepath.Base(o.Game), sha, strings.Join(steps, "|"),
		"engine=" + engineSum,
		"lib=" + libListing(o.Game),
		"java=" + toolVersion(javaCmd(engineDir), "-version"),
		"tools=" + engineToolsSum(engineDir),
	}
	if len(o.Videos) > 0 {
		ff := findFFmpeg()
		if ff == "" {
			return ""
		}
		parts = append(parts, "ffmpeg="+toolVersion(ff, "-version"))
	}
	parts = append(parts, envUsed(o.Game, sha, engineDir)...)
	sum := sha256.Sum256([]byte(strings.Join(parts, "\n")))
	return hex.EncodeToString(sum[:])
}

// libListing は基準へ写す lib/external と lib/cache の、名前・大きさ・更新時刻の並び。
func libListing(game string) string {
	var lines []string
	for _, sub := range []string{"external", "cache"} {
		root := filepath.Join(game, "lib", sub)
		filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
			if err != nil || info.IsDir() {
				return nil
			}
			rel, _ := filepath.Rel(game, p)
			lines = append(lines, fmt.Sprintf("%s:%d:%d", rel, info.Size(), info.ModTime().UnixNano()))
			return nil
		})
	}
	sort.Strings(lines)
	return strings.Join(lines, ",")
}

// toolVersion は道具の版の 1 行目（java は stderr に出す）。
func toolVersion(tool string, args ...string) string {
	out, err := exec.Command(tool, args...).CombinedOutput()
	if err != nil {
		return "none"
	}
	first, _, _ := strings.Cut(string(out), "\n")
	return strings.TrimSpace(first)
}

// envRefRe は環境変数を読む書き方: make の $(X)・シェルの ${X} と ${X:-既定}・Flix の getenv("X") / envOr("X")。
var envRefRe = regexp.MustCompile(envRefPattern)

const envRefPattern = `\$[({]([A-Z][A-Z0-9_]*)[)}:-]|getenv\("([A-Z][A-Z0-9_]*)"|envOr\("([A-Z][A-Z0-9_]*)"`

// javaCmd は描き出しが使う java（headless-run と同じ順: $JAVA → PATH の java → エンジンの devbox）。
func javaCmd(engineDir string) string {
	if j := os.Getenv("JAVA"); j != "" {
		return j
	}
	if p, err := exec.LookPath("java"); err == nil {
		return p
	}
	return filepath.Join(engineDir, ".devbox", "nix", "profile", "default", "bin", "java")
}

// engineToolsSum は描き出しの手順を持つエンジンの道具（mk・headless-run・fge-go）の中身の SHA-256。
func engineToolsSum(engineDir string) string {
	files, _ := filepath.Glob(filepath.Join(engineDir, "mk", "*.mk"))
	files = append(files, filepath.Join(engineDir, "bin", "headless-run"), filepath.Join(engineDir, "bin", "fge-go"))
	sort.Strings(files)
	h := sha256.New()
	for _, f := range files {
		sum, err := hashFile(f)
		if err != nil {
			sum = "missing"
		}
		fmt.Fprintf(h, "%s=%s\n", filepath.Base(f), sum)
	}
	return hex.EncodeToString(h.Sum(nil))
}

// 描き出しの絵に効かない、機械や呼び方ごとに違う変数。
var envIgnored = map[string]bool{
	"PATH": true, "PWD": true, "HOME": true, "SHELL": true, "USER": true, "TERM": true, "TMPDIR": true,
	"MAKEFLAGS": true, "MAKELEVEL": true, "MFLAGS": true, "CURDIR": true, "MAKE": true,
	"FGE_RENDER_CACHE": true, "FGE_COMPARE_NO_CACHE": true,
}

// envUsed は、基準のゲーム（Makefile・mk・src）とエンジンの mk・bin が読む環境変数のうち、
// 今の環境で値がある物を "名前=値" で並べる（FPS=30 make compare と既定の描き出しを混ぜない）。
func envUsed(game, sha, engineDir string) []string {
	names := map[string]bool{}
	add := func(text string) {
		for _, m := range envRefRe.FindAllStringSubmatch(text, -1) {
			for _, g := range m[1:] {
				if g != "" && !envIgnored[g] {
					names[g] = true
				}
			}
		}
	}
	if out, err := exec.Command("git", "-C", game, "grep", "-h", "-o", "-E", envRefPattern, sha, "--",
		"Makefile", "*.mk", "src", "bin").Output(); err == nil {
		add(string(out))
	}
	for _, pat := range []string{"mk/*.mk", "bin/headless-run"} {
		files, _ := filepath.Glob(filepath.Join(engineDir, pat))
		for _, f := range files {
			if data, err := os.ReadFile(f); err == nil {
				add(string(data))
			}
		}
	}
	for _, pkg := range []string{"engine", "engine_world", "engine_tools", "render_gl"} {
		filepath.Walk(filepath.Join(engineDir, pkg, "src"), func(p string, info os.FileInfo, err error) error {
			if err == nil && !info.IsDir() && strings.HasSuffix(p, ".flix") {
				if data, err := os.ReadFile(p); err == nil {
					add(string(data))
				}
			}
			return nil
		})
	}
	var out []string
	for n := range names {
		if v, ok := os.LookupEnv(n); ok {
			out = append(out, n+"="+v)
		}
	}
	sort.Strings(out)
	return out
}

// loadBaseCache は写しがあれば、それを基準の side として返す。
func loadBaseCache(o Options, dir string) (*side, bool) {
	if dir == "" || !isFile(filepath.Join(dir, "done")) {
		return nil, false
	}
	s := &side{dir: dir, images: map[string]string{}, sounds: map[string]string{}, videos: map[string]string{}}
	now := time.Now()
	os.Chtimes(dir, now, now)
	collectCached(o, s)
	return s, true
}

// collectCached は写しの中を、collectSide が拾うのと同じ名前の付け方で拾う（描き出しはしない）。
func collectCached(o Options, s *side) {
	if len(o.Videos) > 0 {
		collect(s.videos, filepath.Join(s.dir, o.VideoDir), ".mp4", time.Time{}, true)
		return
	}
	if len(o.Shots) > 0 {
		for _, shot := range o.Shots {
			if p := filepath.Join(s.dir, "debug", shot+".png"); isFile(p) {
				s.images[shot+".png"] = p
			}
		}
	} else {
		collect(s.images, filepath.Join(s.dir, "gallery"), ".png", time.Time{}, false)
	}
	for _, sheet := range []string{"sounds.png", "music.png"} {
		if p := filepath.Join(s.dir, "debug", sheet); isFile(p) {
			s.images["音の表/"+sheet] = p
		}
	}
	for _, sub := range []string{"assets/sfx", "assets/music", "assets/bgm"} {
		collect(s.sounds, filepath.Join(s.dir, sub), ".wav", time.Time{}, false)
	}
	for name, p := range s.sounds {
		delete(s.sounds, name)
		rel, _ := filepath.Rel(s.dir, p)
		s.sounds[rel] = p
	}
}

// saveBaseCache は描き出した基準の拾った物を、worktree の中と同じ相対の場所へ写す。
// 動画は sfx.txt も要る（音の差を名前で言うため）ので、mp4 の隣の連番のフォルダから sfx.txt だけ写す。
func saveBaseCache(o Options, dir string, s *side) error {
	if dir == "" || len(s.failed) > 0 {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return err
	}
	// WhyNot: 一時の置き場を固定の名前にしない — 並んだ 2 本の compare が相手の書きかけを消し合い、
	// 一部しか無い写しに done が付きうる。
	tmp, err := os.MkdirTemp(filepath.Dir(dir), filepath.Base(dir)+".part-")
	if err != nil {
		return err
	}
	var paths []string
	for _, m := range []map[string]string{s.images, s.sounds, s.videos} {
		for _, p := range m {
			paths = append(paths, p)
			if strings.HasSuffix(p, ".mp4") {
				if sfx := videos.SfxBesideMp4(p); sfx != "" {
					paths = append(paths, sfx)
				}
			}
		}
	}
	for _, p := range paths {
		rel, err := filepath.Rel(s.dir, p)
		if err != nil || strings.HasPrefix(rel, "..") {
			continue
		}
		if err := copyFile(p, filepath.Join(tmp, rel)); err != nil {
			os.RemoveAll(tmp)
			return err
		}
	}
	if err := os.WriteFile(filepath.Join(tmp, "done"), []byte(fmt.Sprintf("%d files\n", len(paths))), 0o644); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	// 古い写しは別名へ退けてから消す（読んでいる最中の相手からは、前の写しか新しい写しの一方だけが見える）。
	trash := tmp + ".old"
	if os.Rename(dir, trash) == nil {
		defer os.RemoveAll(trash)
	}
	if err := os.Rename(tmp, dir); err != nil {
		os.RemoveAll(tmp)
		return err
	}
	pruneBaseCache(filepath.Dir(dir), baseCacheKeep)
	return nil
}

// baseCacheKeep は残す写しの数（基準 1 つで動画数本ぶん。古い基準から消す）。
const baseCacheKeep = 20

// pruneBaseCache は写しの置き場を、新しい方から keep 個だけ残す。
func pruneBaseCache(root string, keep int) {
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	type dated struct {
		path string
		when time.Time
	}
	var dirs []dated
	for _, e := range entries {
		if info, err := e.Info(); err == nil && e.IsDir() && !strings.Contains(e.Name(), ".part-") {
			dirs = append(dirs, dated{filepath.Join(root, e.Name()), info.ModTime()})
		}
	}
	sort.Slice(dirs, func(i, j int) bool { return dirs[i].when.After(dirs[j].when) })
	for i := keep; i < len(dirs); i++ {
		os.RemoveAll(dirs[i].path)
	}
}

func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
