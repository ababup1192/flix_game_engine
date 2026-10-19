// Package compare は、基準の版（BASE）と今の作業場を同じやり方で描き出して並べる。
//
//	fge compare --base <ref> [--shots "a b"] [--videos "x-video y-video"] [--out debug/compare]
//	            [--base-engine <版 | パス>]   基準側のエンジン（既定は今の作業場と同じ）
//
// BASE を一時の worktree に出し（終わったら消す）、両方で描き出す（重い所は heavy の鍵の内側）。
// 比べるのは PNG・効果音と曲の WAV・音の表（gallery-sounds の sounds.png / music.png）・動画のコマと音
// （音は mp4 の音声の md5 を先に比べ、違えば連番の sfx.txt を名前つきで比べる: 「-hit@12 +hit@13」）。
// 出す物は --out の下に:
//
//	report.tsv           1 ファイル 1 行（same / diff / only-base / only-current）
//	pairs/<名前>.png      差のある絵: 基準 | 今 | 差の所（変わった画素を赤で）
//	videos/<名前>.mp4     差のある動画: 基準 | 今 を左右に並べた物
//	videos/<名前>.first.png  最初に差の出たコマの 基準 | 今 | 差の所
//	proposal.json        fge proposal の manifest と、それから組んだ index.html
package compare

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"github.com/ababup1192/flix_game_engine/go/internal/heavy"
	"github.com/ababup1192/flix_game_engine/go/internal/proposal"
	"github.com/ababup1192/flix_game_engine/go/internal/useengine"
	"github.com/ababup1192/flix_game_engine/go/internal/videos"
	"github.com/ababup1192/flix_game_engine/go/internal/wavfile"
)

// Options は fge compare の引数。
type Options struct {
	Base       string
	Shots      []string
	Videos     []string
	OutDir     string
	BaseEngine string
	Make       string
	Game       string
	VideoDir   string
	Out, Err   io.Writer
	HeavyOpts  heavy.Options
}

// Item は比べた 1 つ。
type Item struct {
	Kind   string `json:"kind"` // image / sound / video
	Name   string `json:"name"`
	State  string `json:"state"` // same / diff / only-base / only-current
	Detail string `json:"detail,omitempty"`
	Pair   string `json:"pair,omitempty"`
	Video  string `json:"video,omitempty"`
}

// side は片方の作業場で描き出した物（名前 → ファイル）。
type side struct {
	dir    string
	images map[string]string
	sounds map[string]string
	videos map[string]string
	failed []string
}

var interrupted atomic.Bool

// Run は fge compare の入口。
func Run(args []string, o Options) int {
	for i := 0; i < len(args); i++ {
		a := args[i]
		next := func() string {
			if i+1 < len(args) {
				i++
				return args[i]
			}
			return ""
		}
		switch a {
		case "--base":
			o.Base = next()
		case "--shots":
			o.Shots = strings.Fields(next())
		case "--videos":
			o.Videos = strings.Fields(next())
		case "--out":
			o.OutDir = next()
		case "--base-engine":
			o.BaseEngine = next()
		case "--json":
		default:
			fmt.Fprintf(os.Stderr, "compare: 知らない引数 %s\n", a)
			return 2
		}
	}
	if o.Out == nil {
		o.Out = os.Stdout
	}
	if o.Err == nil {
		o.Err = os.Stderr
	}
	if o.Base == "" {
		fmt.Fprintln(o.Err, "使い方: fge compare --base <ref> [--shots \"a b\"] [--videos \"x-video\"] [--out debug/compare] [--base-engine <版|パス>]")
		return 2
	}
	if o.Make == "" {
		o.Make = "make"
	}
	if o.Game == "" {
		o.Game, _ = os.Getwd()
	}
	if o.OutDir == "" {
		o.OutDir = filepath.Join("debug", "compare")
	}
	if !filepath.IsAbs(o.OutDir) {
		o.OutDir = filepath.Join(o.Game, o.OutDir)
	}
	if o.VideoDir == "" {
		o.VideoDir = filepath.Join("debug", "video")
	}

	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, heavy.InterruptSignals...)
	defer signal.Stop(sigs)
	go func() {
		for range sigs {
			interrupted.Store(true)
		}
	}()

	if err := run(o); err != nil {
		fmt.Fprintf(o.Err, "compare: %v\n", err)
		if interrupted.Load() {
			return 130
		}
		return 1
	}
	return 0
}

func run(o Options) error {
	sha, err := gitOut(o.Game, "rev-parse", "--verify", o.Base+"^{commit}")
	if err != nil {
		return fmt.Errorf("BASE=%s がコミットとして引けません", o.Base)
	}
	head, _ := gitOut(o.Game, "rev-parse", "--short", "HEAD")
	if _, err := os.Stat(filepath.Join(o.Game, "local.mk")); err != nil {
		return fmt.Errorf("今の作業場に local.mk がありません（先に fge use-engine <版>）")
	}

	tmp, err := os.MkdirTemp("", "fge-compare-")
	if err != nil {
		return err
	}
	wt := filepath.Join(tmp, "base")
	// WhyNot: 消すのを defer 1 つに任せるのは、描き出しの失敗・中断のどちらで抜けても
	// 一時の worktree が git の一覧に残らないようにするため。
	defer func() {
		exec.Command("git", "-C", o.Game, "worktree", "remove", "--force", wt).Run()
		os.RemoveAll(tmp)
		exec.Command("git", "-C", o.Game, "worktree", "prune").Run()
	}()
	cacheDir := baseCacheDir(o, sha)
	cached, hit := loadBaseCache(o, cacheDir)
	var baseEngine string
	if hit {
		baseEngine = shortPath(o.BaseEngine + currentEngineIfEmpty(o))
		fmt.Fprintf(o.Err, "[compare] 基準 %s (%s) は前に描いた写しを使います: %s\n", o.Base, sha[:min(10, len(sha))], cacheDir)
	} else {
		fmt.Fprintf(o.Err, "[compare] 基準 %s (%s) を %s に出しています\n", o.Base, sha[:min(10, len(sha))], wt)
		if out, err := exec.Command("git", "-C", o.Game, "worktree", "add", "--detach", wt, sha).CombinedOutput(); err != nil {
			return fmt.Errorf("基準の worktree を作れません: %s", strings.TrimSpace(string(out)))
		}
		if baseEngine, err = prepareBase(o, wt); err != nil {
			return err
		}
	}
	if interrupted.Load() {
		return fmt.Errorf("止められました")
	}

	// WhyNot: 書き出し先を debug/ の下に限るのは、作り直すときにまず消すので、
	// --out に . や .. を渡されると作業場ごと消えるため。
	if rel, err := filepath.Rel(filepath.Join(o.Game, "debug"), o.OutDir); err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return fmt.Errorf("--out は debug/ の下にしてください (%s)", o.OutDir)
	}
	if err := os.RemoveAll(o.OutDir); err != nil {
		return err
	}
	if err := os.MkdirAll(o.OutDir, 0o755); err != nil {
		return err
	}
	base, cur, err := renderBoth(o, wt, cached)
	if err != nil {
		return err
	}
	if !hit {
		if err := saveBaseCache(o, cacheDir, base); err != nil {
			fmt.Fprintf(o.Err, "[compare] 基準の写しを置けませんでした（比べは続けます）: %v\n", err)
		}
	}
	items := compareSides(o, base, cur)
	curEngine := shortPath(currentEngine(o.Game))
	meta := fmt.Sprintf("基準 %s (%s・エンジン %s) と 今 %s (エンジン %s)",
		o.Base, sha[:min(10, len(sha))], baseEngine, strings.TrimSpace(head), curEngine)
	if err := writeReport(o, items); err != nil {
		return err
	}
	if err := writeProposal(o, items, meta, base.failed, cur.failed); err != nil {
		return err
	}
	printSummary(o, items, base.failed, cur.failed)
	return nil
}

// prepareBase は基準の worktree に local.mk と lib を置く。返すのはエンジンの短い名前。
//
// 既定は今の作業場と同じエンジンで、比べるのはゲームの変更だけになる。
// エンジンの直しを比べたいときは --base-engine（make compare BASE_ENGINE=）で基準側を変える。
func prepareBase(o Options, wt string) (string, error) {
	for _, sub := range []string{"external", "cache"} {
		if src := filepath.Join(o.Game, "lib", sub); isDir(src) {
			if err := copyTree(src, filepath.Join(wt, "lib", sub)); err != nil {
				return "", err
			}
		}
	}
	uo := useengine.Options{Game: wt, Out: io.Discard, Err: o.Err, Make: o.Make, HeavyOpts: o.HeavyOpts}
	dir := currentEngine(o.Game)
	if o.BaseEngine != "" {
		var err error
		if dir, err = useengine.Resolve(o.BaseEngine, uo); err != nil {
			return "", err
		}
	}
	if dir == "" {
		return "", fmt.Errorf("今の作業場の local.mk に ENGINE がありません（先に fge use-engine <版>）")
	}
	if err := useengine.Use(dir, uo); err != nil {
		return "", err
	}
	return shortPath(dir), nil
}

// currentEngineIfEmpty は --base-engine が無い時だけ今の作業場のエンジン（写しの知らせの表示用）。
func currentEngineIfEmpty(o Options) string {
	if o.BaseEngine != "" {
		return ""
	}
	return currentEngine(o.Game)
}

func currentEngine(game string) string {
	data, err := os.ReadFile(filepath.Join(game, "local.mk"))
	if err != nil {
		return ""
	}
	return useengine.EngineOfLocalMk(string(data))
}

// ── 描き出す ─────────────────────────────────────────────

// renderBoth は基準側と今側を、heavy の鍵を 1 回だけ取って続けて描き出す。
//
// WhyNot: 側ごとに鍵を取り直さないのは、基準側を描き終えたところで列の後ろへ並び直し、
// 今側を描くまでにもう一度 10 分前後待っていたため（2026-10-16 の記録で 9 分・12 分）。
// 1 回にすると次の長い物の待ちはそのぶん延びるが、長い物どうしの順番は並んだ順のまま。
func renderBoth(o Options, wt string, cached *side) (*side, *side, error) {
	base := &side{dir: wt, images: map[string]string{}, sounds: map[string]string{}, videos: map[string]string{}}
	cur := &side{dir: o.Game, images: map[string]string{}, sounds: map[string]string{}, videos: map[string]string{}}
	steps := renderSteps(o)
	desc := fmt.Sprintf("compare: 基準と今の描き出し (%s)", strings.Join(steps[0][1:], " "))
	var baseStart, curStart time.Time
	type job struct {
		s     *side
		label string
		start *time.Time
	}
	jobs := []job{{base, "基準", &baseStart}, {cur, "今", &curStart}}
	if cached != nil {
		jobs = jobs[1:]
	}
	code := heavy.Hold(desc, o.Game, o.HeavyOpts, func(run heavy.Runner) int {
		for _, sd := range jobs {
			*sd.start = time.Now().Add(-2 * time.Second)
			for _, step := range steps {
				if interrupted.Load() {
					return 130
				}
				fmt.Fprintf(o.Err, "[compare] %s: %s\n", sd.label, strings.Join(step, " "))
				if c := run(sd.s.dir, step...); c != 0 {
					sd.s.failed = append(sd.s.failed, strings.Join(step[1:], " "))
					if c == 130 {
						interrupted.Store(true)
						return c
					}
				}
			}
		}
		return 0
	})
	if interrupted.Load() || code == 130 {
		interrupted.Store(true)
		return nil, nil, fmt.Errorf("止められました")
	}
	if code != 0 {
		return nil, nil, fmt.Errorf("描き出しで鍵を取れませんでした (終了コード %d)", code)
	}
	if cached != nil {
		base = cached
	} else {
		collectSide(o, base, baseStart)
	}
	collectSide(o, cur, curStart)
	return base, cur, nil
}

func renderSteps(o Options) [][]string {
	var steps [][]string
	switch {
	case len(o.Videos) > 0:
		for _, v := range o.Videos {
			steps = append(steps, []string{o.Make, v})
		}
	case len(o.Shots) > 0:
		steps = append(steps, []string{o.Make, "render", "SHOT=" + strings.Join(o.Shots, " ")})
	default:
		steps = append(steps, []string{o.Make, "render-all"})
	}
	return steps
}

// collectSide は描き出した後の絵・音・動画を拾う（鍵の外）。
func collectSide(o Options, s *side, start time.Time) {
	dir := s.dir
	if len(o.Videos) > 0 {
		collect(s.videos, filepath.Join(dir, o.VideoDir), ".mp4", start, true)
		return
	}
	if len(o.Shots) > 0 {
		for _, shot := range o.Shots {
			p := filepath.Join(dir, "debug", shot+".png")
			if info, err := os.Stat(p); err == nil && !info.ModTime().Before(start) {
				s.images[shot+".png"] = p
			}
		}
	} else {
		collect(s.images, filepath.Join(dir, "gallery"), ".png", start, false)
	}
	// 音の表は JVM を使わない軽い段なので鍵の外で流す。
	if wavs, _ := filepath.Glob(filepath.Join(dir, "assets", "sfx", "*.wav")); len(wavs) > 0 {
		gs := exec.Command(o.Make, "gallery-sounds")
		gs.Dir = dir
		if gs.Run() != nil {
			s.failed = append(s.failed, "gallery-sounds")
		}
	}
	for _, sheet := range []string{"sounds.png", "music.png"} {
		if p := filepath.Join(dir, "debug", sheet); isFile(p) {
			s.images["音の表/"+sheet] = p
		}
	}
	for _, sub := range []string{"assets/sfx", "assets/music", "assets/bgm"} {
		collect(s.sounds, filepath.Join(dir, sub), ".wav", time.Time{}, false)
	}
	for name, p := range s.sounds {
		delete(s.sounds, name)
		rel, _ := filepath.Rel(dir, p)
		s.sounds[rel] = p
	}
}

// collect は root の下で ext の物を集める。since より古い物は前の描き出しの残りなので外す。
func collect(into map[string]string, root, ext string, since time.Time, recursive bool) {
	filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			if p != root && !recursive {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(p, ext) || info.ModTime().Before(since) {
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		into[rel] = p
		return nil
	})
}

// ── 比べる ───────────────────────────────────────────────

func compareSides(o Options, base, cur *side) []Item {
	var items []Item
	items = append(items, compareKind(o, "image", base.images, cur.images)...)
	items = append(items, compareKind(o, "sound", base.sounds, cur.sounds)...)
	items = append(items, compareKind(o, "video", base.videos, cur.videos)...)
	return items
}

func compareKind(o Options, kind string, base, cur map[string]string) []Item {
	names := map[string]bool{}
	for n := range base {
		names[n] = true
	}
	for n := range cur {
		names[n] = true
	}
	sorted := make([]string, 0, len(names))
	for n := range names {
		sorted = append(sorted, n)
	}
	sort.Strings(sorted)
	var items []Item
	for _, n := range sorted {
		b, inBase := base[n]
		c, inCur := cur[n]
		it := Item{Kind: kind, Name: n}
		switch {
		case !inBase:
			it.State = "only-current"
		case !inCur:
			it.State = "only-base"
		case sameBytes(b, c):
			it.State = "same"
		default:
			it.State = "diff"
			switch kind {
			case "image":
				it.Detail, it.Pair = diffImage(o, n, b, c)
			case "video":
				it.Detail, it.Pair, it.Video = diffVideo(o, n, b, c)
			case "sound":
				it.Detail = diffSound(b, c)
			}
		}
		items = append(items, it)
	}
	return items
}

func sameBytes(a, b string) bool {
	ha, ea := hashFile(a)
	hb, eb := hashFile(b)
	return ea == nil && eb == nil && ha == hb
}

func hashFile(p string) (string, error) {
	f, err := os.Open(p)
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

func diffSize(a, b string) string {
	ia, _ := os.Stat(a)
	ib, _ := os.Stat(b)
	if ia == nil || ib == nil {
		return ""
	}
	return fmt.Sprintf("%d → %d バイト", ia.Size(), ib.Size())
}

// diffSound は WAV の形（チャンネル数・サンプルレート・長さ・左右のピーク）を 基準 → 今 で並べる。
// モノラル → ステレオの入れ替えや、片側だけ鳴らなくなった音がバイト数だけでは見分けられないため。
// 読めない WAV はバイト数だけ。
func diffSound(a, b string) string {
	da, errA := os.ReadFile(a)
	db, errB := os.ReadFile(b)
	if errA != nil || errB != nil {
		return diffSize(a, b)
	}
	sa, errA := wavfile.Summarize(da)
	sb, errB := wavfile.Summarize(db)
	if errA != nil || errB != nil {
		return diffSize(a, b)
	}
	return fmt.Sprintf("%s → %s（%s）", sa, sb, diffSize(a, b))
}

func safeName(name string) string {
	return strings.NewReplacer("/", "__", " ", "_").Replace(strings.TrimSuffix(name, filepath.Ext(name)))
}

// diffImage は 基準 | 今 | 差の所 の 1 枚を pairs/ に書き、差の画素数を返す。
func diffImage(o Options, name, basePath, curPath string) (string, string) {
	a, errA := readPNG(basePath)
	b, errB := readPNG(curPath)
	if errA != nil || errB != nil {
		return "PNG として読めません", ""
	}
	rel := filepath.Join("pairs", safeName(name)+".png")
	detail, err := writePair(filepath.Join(o.OutDir, rel), a, b)
	if err != nil {
		return err.Error(), ""
	}
	return detail, rel
}

func readPNG(p string) (image.Image, error) {
	f, err := os.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return png.Decode(f)
}

var diffMark = color.RGBA{255, 40, 90, 255}

// writePair は a | b | 差の所 を横に並べて書く。差の所は今の絵を暗くし、変わった画素だけを赤で塗る。
func writePair(path string, a, b image.Image) (string, error) {
	ra, rb := a.Bounds(), b.Bounds()
	w := max(ra.Dx(), rb.Dx())
	h := max(ra.Dy(), rb.Dy())
	const gap = 4
	out := image.NewRGBA(image.Rect(0, 0, w*3+gap*2, h))
	draw.Draw(out, out.Bounds(), &image.Uniform{color.RGBA{40, 40, 40, 255}}, image.Point{}, draw.Src)
	draw.Draw(out, image.Rect(0, 0, ra.Dx(), ra.Dy()), a, ra.Min, draw.Src)
	draw.Draw(out, image.Rect(w+gap, 0, w+gap+rb.Dx(), rb.Dy()), b, rb.Min, draw.Src)
	changed := 0
	minX, minY, maxX, maxY := w, h, -1, -1
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			ca, cb := pixelAt(a, x, y), pixelAt(b, x, y)
			var px color.RGBA
			if ca != cb {
				changed++
				px = diffMark
				minX, minY, maxX, maxY = min(minX, x), min(minY, y), max(maxX, x), max(maxY, y)
			} else {
				px = color.RGBA{cb.R / 4, cb.G / 4, cb.B / 4, 255}
			}
			out.SetRGBA(2*(w+gap)+x, y, px)
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return "", err
	}
	f, err := os.Create(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if err := png.Encode(f, out); err != nil {
		return "", err
	}
	detail := fmt.Sprintf("%d 画素 (%.2f%%)", changed, 100*float64(changed)/float64(w*h))
	if changed > 0 {
		detail += fmt.Sprintf("・x %d〜%d y %d〜%d", minX, maxX, minY, maxY)
	}
	if ra.Size() != rb.Size() {
		detail = fmt.Sprintf("大きさが違う %dx%d → %dx%d", ra.Dx(), ra.Dy(), rb.Dx(), rb.Dy())
	}
	return detail, nil
}

func pixelAt(img image.Image, x, y int) color.RGBA {
	r := img.Bounds()
	if x >= r.Dx() || y >= r.Dy() {
		return color.RGBA{}
	}
	return color.RGBAModel.Convert(img.At(r.Min.X+x, r.Min.Y+y)).(color.RGBA)
}

// ── 動画 ─────────────────────────────────────────────────

// findFFmpeg は PATH・FFMPEG・nix store の順に ffmpeg を探す。
func findFFmpeg() string {
	if v := os.Getenv("FFMPEG"); v != "" {
		return v
	}
	if p, err := exec.LookPath("ffmpeg"); err == nil {
		return p
	}
	matches, _ := filepath.Glob("/nix/store/*-ffmpeg-*-bin/bin/ffmpeg")
	sort.Strings(matches)
	if len(matches) > 0 {
		return matches[len(matches)-1]
	}
	return ""
}

// diffVideo はコマごとの md5 で差のあるコマを数え、左右に並べた mp4 と最初に差の出たコマの絵を書く。
func diffVideo(o Options, name, basePath, curPath string) (string, string, string) {
	ff := findFFmpeg()
	if ff == "" {
		return "ffmpeg が見つからないのでコマは比べていません（FFMPEG= で場所を渡す）", "", ""
	}
	fa, errA := frameHashes(ff, basePath)
	fb, errB := frameHashes(ff, curPath)
	if errA != nil || errB != nil {
		return "コマを読めません", "", ""
	}
	var diffs []int
	for i := 0; i < max(len(fa), len(fb)); i++ {
		if i >= len(fa) || i >= len(fb) || fa[i] != fb[i] {
			diffs = append(diffs, i)
		}
	}
	detail := fmt.Sprintf("%d / %d コマ", len(diffs), max(len(fa), len(fb)))
	if len(diffs) == 0 {
		detail = "コマは同じ"
	} else {
		detail += "・" + frameRanges(diffs)
	}
	switch sound := diffAudio(ff, basePath, curPath); {
	case sound != "":
		detail += "・" + sound
	case len(diffs) == 0:
		detail += "・音も同じ（入れ物だけの差）"
	}
	video := filepath.Join("videos", safeName(name)+".mp4")
	if err := sideBySide(ff, basePath, curPath, filepath.Join(o.OutDir, video)); err != nil {
		video = ""
		detail += "・並べた mp4 を作れません (" + err.Error() + ")"
	}
	pair := ""
	if len(diffs) > 0 && diffs[0] < len(fa) && diffs[0] < len(fb) {
		tmp, err := os.MkdirTemp("", "fge-compare-frame-")
		if err == nil {
			defer os.RemoveAll(tmp)
			pa, pb := filepath.Join(tmp, "a.png"), filepath.Join(tmp, "b.png")
			if extractFrame(ff, basePath, diffs[0], pa) == nil && extractFrame(ff, curPath, diffs[0], pb) == nil {
				a, ea := readPNG(pa)
				b, eb := readPNG(pb)
				if ea == nil && eb == nil {
					rel := filepath.Join("videos", safeName(name)+".first.png")
					if _, err := writePair(filepath.Join(o.OutDir, rel), a, b); err == nil {
						pair = rel
					}
				}
			}
		}
	}
	return detail, pair, video
}

// diffAudio は音の差の 1 行（同じなら空）。先に mp4 の音声の md5 を比べ、違えば連番の sfx.txt を名前つきで比べる
// （どの音が何コマ目で増えた・消えたか）。sfx.txt が無い動画は「音声が違う」とだけ言う。
func diffAudio(ff, basePath, curPath string) string {
	ha, ea := audioHash(ff, basePath)
	hb, eb := audioHash(ff, curPath)
	if ea == nil && eb == nil && ha == hb {
		return ""
	}
	sa, sb := videos.SfxBesideMp4(basePath), videos.SfxBesideMp4(curPath)
	if sa == "" || sb == "" {
		return "音声が違う（sfx.txt が無いので名前では比べていません）"
	}
	a, errA := videos.ReadSfx(sa)
	b, errB := videos.ReadSfx(sb)
	if errA != nil || errB != nil {
		return "音声が違う（sfx.txt を読めません）"
	}
	if named := videos.DiffSfx(a, b); named != "" {
		return named
	}
	return "音声が違う（鳴らした音の表は同じ — 音の中身か曲の差）"
}

// audioHash は mp4 の最初の音声の md5（音声が無ければ空の文字）。
func audioHash(ff, path string) (string, error) {
	out, err := exec.Command(ff, "-v", "error", "-i", path, "-map", "0:a:0?", "-f", "md5", "-").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func frameHashes(ff, path string) ([]string, error) {
	out, err := exec.Command(ff, "-v", "error", "-i", path, "-map", "0:v:0", "-f", "framemd5", "-").Output()
	if err != nil {
		return nil, err
	}
	var hashes []string
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}
		fields := strings.Split(line, ",")
		hashes = append(hashes, strings.TrimSpace(fields[len(fields)-1]))
	}
	return hashes, nil
}

func frameRanges(frames []int) string {
	var parts []string
	for i := 0; i < len(frames); {
		j := i
		for j+1 < len(frames) && frames[j+1] == frames[j]+1 {
			j++
		}
		if i == j {
			parts = append(parts, fmt.Sprint(frames[i]))
		} else {
			parts = append(parts, fmt.Sprintf("%d〜%d", frames[i], frames[j]))
		}
		i = j + 1
		if len(parts) == 8 && i < len(frames) {
			parts = append(parts, "…")
			break
		}
	}
	return "コマ " + strings.Join(parts, ", ")
}

func sideBySide(ff, a, b, out string) error {
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return err
	}
	// 高さが違っても並ぶよう、今の側を基準の高さに合わせる。音は今の側を残す。
	// libx264 は奇数の幅と高さを受けないので、並べた後に偶数へ丸める。
	filter := "[1:v][0:v]scale2ref=oh*mdar:ih[c][b];[b][c]hstack=inputs=2,scale=trunc(iw/2)*2:trunc(ih/2)*2[v]"
	return exec.Command(ff, "-y", "-v", "error", "-i", a, "-i", b, "-filter_complex", filter,
		"-map", "[v]", "-map", "1:a?", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23",
		"-movflags", "+faststart", out).Run()
}

func extractFrame(ff, path string, n int, out string) error {
	return exec.Command(ff, "-y", "-v", "error", "-i", path, "-vf", fmt.Sprintf(`select=eq(n\,%d)`, n),
		"-vframes", "1", out).Run()
}

// ── 書き出す ─────────────────────────────────────────────

func writeReport(o Options, items []Item) error {
	var b strings.Builder
	b.WriteString("kind\tname\tstate\tdetail\tpair\tvideo\n")
	for _, it := range items {
		fmt.Fprintf(&b, "%s\t%s\t%s\t%s\t%s\t%s\n", it.Kind, it.Name, it.State, it.Detail, it.Pair, it.Video)
	}
	return os.WriteFile(filepath.Join(o.OutDir, "report.tsv"), []byte(b.String()), 0o644)
}

var kindLabel = map[string]string{"image": "絵", "sound": "音", "video": "動画"}

var stateLabel = map[string]string{
	"same": "同じ", "diff": "差あり", "only-base": "基準だけ", "only-current": "今だけ",
}

func counts(items []Item) map[string]map[string]int {
	c := map[string]map[string]int{}
	for _, it := range items {
		if c[it.Kind] == nil {
			c[it.Kind] = map[string]int{}
		}
		c[it.Kind][it.State]++
	}
	return c
}

func writeProposal(o Options, items []Item, meta string, baseFailed, curFailed []string) error {
	c := counts(items)
	table := [][]string{{"種類", "同じ", "差あり", "基準だけ", "今だけ"}}
	for _, k := range []string{"image", "sound", "video"} {
		if c[k] == nil {
			continue
		}
		table = append(table, []string{kindLabel[k], fmt.Sprint(c[k]["same"]), fmt.Sprint(c[k]["diff"]),
			fmt.Sprint(c[k]["only-base"]), fmt.Sprint(c[k]["only-current"])})
	}
	sections := []map[string]any{{"title": "まとめ", "table": table}}
	if len(baseFailed)+len(curFailed) > 0 {
		sections = append(sections, map[string]any{"title": "描き出しの失敗", "table": [][]string{
			{"側", "段"}, {"基準", "!" + strings.Join(baseFailed, " / ")}, {"今", "!" + strings.Join(curFailed, " / ")}}})
	}
	var media []any
	var changed [][]string
	changed = append(changed, []string{"種類", "名前", "差", "どこ"})
	for _, it := range items {
		if it.State == "same" {
			continue
		}
		changed = append(changed, []string{kindLabel[it.Kind], "`" + it.Name + "`", stateLabel[it.State], it.Detail})
		if it.Video != "" {
			media = append(media, map[string]any{"src": it.Video, "caption": it.Name + " — 左 = 基準 / 右 = 今"})
		}
		if it.Pair != "" {
			media = append(media, map[string]any{"src": it.Pair, "pixel": true,
				"caption": it.Name + " — 基準 | 今 | 差の所（赤）・" + it.Detail})
		}
	}
	if len(changed) > 1 {
		sections = append(sections, map[string]any{"title": "差のある物", "table": changed})
	}
	if len(media) > 0 {
		sections = append(sections, map[string]any{"id": "A", "title": "前後を並べた物",
			"lead": "どちらを採るかを選ぶ。絵は実寸（左から 基準・今・差の所）。",
			"options": []map[string]any{
				{"id": "A0", "label": "基準のまま", "baseline": true, "text": o.Base},
				{"id": "A1", "label": "今の形", "rec": true, "text": "この作業場", "media": media},
			}})
	}
	manifest := map[string]any{
		"version":  1,
		"title":    "前後の比較",
		"meta":     time.Now().Format("2006-01-02 15:04") + " ・ " + meta,
		"lead":     "同じ描き出しを基準と今の 2 つの作業場で流し、バイトで比べた物。表の全部は report.tsv。",
		"sections": sections,
	}
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	path := filepath.Join(o.OutDir, "proposal.json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return err
	}
	if proposal.Build(path, io.Discard, o.Err) == 2 {
		return fmt.Errorf("index.html を組めません")
	}
	return nil
}

func printSummary(o Options, items []Item, baseFailed, curFailed []string) {
	c := counts(items)
	for _, k := range []string{"image", "sound", "video"} {
		if c[k] == nil {
			continue
		}
		fmt.Fprintf(o.Out, "[compare] %s: 同じ %d・差あり %d・基準だけ %d・今だけ %d\n", kindLabel[k],
			c[k]["same"], c[k]["diff"], c[k]["only-base"], c[k]["only-current"])
	}
	shown := 0
	for _, it := range items {
		if it.State == "same" {
			continue
		}
		if shown == 20 {
			fmt.Fprintln(o.Out, "  …（残りは report.tsv）")
			break
		}
		fmt.Fprintf(o.Out, "  %s %s: %s %s\n", stateLabel[it.State], it.Name, it.Detail, it.Pair)
		shown++
	}
	if len(baseFailed) > 0 {
		fmt.Fprintf(o.Out, "[compare] !! 基準で失敗した段: %s\n", strings.Join(baseFailed, " / "))
	}
	if len(curFailed) > 0 {
		fmt.Fprintf(o.Out, "[compare] !! 今で失敗した段: %s\n", strings.Join(curFailed, " / "))
	}
	rel, _ := filepath.Rel(o.Game, o.OutDir)
	fmt.Fprintf(o.Out, "[compare] %s/ (report.tsv・proposal.json・index.html)\n", rel)
}

// ── 小物 ─────────────────────────────────────────────────

func gitOut(dir string, args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).Output()
	return strings.TrimSpace(string(out)), err
}

func isFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.Mode().IsRegular()
}

func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}

func copyTree(src, dst string) error {
	// WhyNot: cp -c（APFS の複製）を先に試すのは、lib/cache が数百 MB あっても一瞬で済むため。
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if exec.Command("cp", "-cR", src, dst).Run() == nil {
		return nil
	}
	return exec.Command("cp", "-R", src, dst).Run()
}

func shortPath(p string) string {
	if home, err := os.UserHomeDir(); err == nil && strings.HasPrefix(p, home+"/") {
		return "~" + p[len(home):]
	}
	return p
}
