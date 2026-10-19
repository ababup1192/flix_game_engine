package compare

// SPIKE: 基準の側の描き出しを取っておく。
//
// 基準のコミット・基準のエンジン・描く口（make の口の並び）が同じなら、描き出しは同じになる
// （ゲームの描き出しは決まった dt で回し、乱数も種から導く）。そこで、基準を描いて拾った物
// （動画・絵・音の表・音）を ~/.flix_ge_studio/compare-cache/<鍵>/ に写しておき、次からは
// 基準の worktree も描き出しも飛ばして、写しを基準として比べる。
//
// 取っておかない時: 基準の描き出しに失敗した口があった（ffmpeg が無い・止めた など、
// 機械の都合で落ちた結果を次へ持ち越さない）。FGE_COMPARE_NO_CACHE=1 で使わない。

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/videos"
)

// baseCacheDir は基準の写しの置き場（鍵ごと）。使わない時は空。
func baseCacheDir(o Options, sha string) string {
	if os.Getenv("FGE_COMPARE_NO_CACHE") == "1" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	engine := o.BaseEngine
	if engine == "" {
		engine = currentEngine(o.Game)
	}
	var steps []string
	for _, s := range renderSteps(o) {
		steps = append(steps, strings.Join(s[1:], " "))
	}
	key := strings.Join([]string{filepath.Base(o.Game), sha, engine, strings.Join(steps, "|")}, "\n")
	sum := sha256.Sum256([]byte(key))
	return filepath.Join(home, ".flix_ge_studio", "compare-cache", sha[:min(10, len(sha))]+"-"+hex.EncodeToString(sum[:])[:12])
}

// loadBaseCache は写しがあれば、それを基準の side として返す。
func loadBaseCache(o Options, dir string) (*side, bool) {
	if dir == "" || !isFile(filepath.Join(dir, "done")) {
		return nil, false
	}
	s := &side{dir: dir, images: map[string]string{}, sounds: map[string]string{}, videos: map[string]string{}}
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
	tmp := dir + ".part"
	os.RemoveAll(tmp)
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
			return err
		}
	}
	if err := os.WriteFile(filepath.Join(tmp, "done"), []byte(fmt.Sprintf("%d files\n", len(paths))), 0o644); err != nil {
		return err
	}
	os.RemoveAll(dir)
	return os.Rename(tmp, dir)
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
