package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"

	"github.com/ababup1192/flix_game_engine/go/internal/fontbake"
	"github.com/ababup1192/flix_game_engine/go/internal/wavfile"
)

// project.json の web.compress（書き出しの時だけ素材を小さくする設定）。書いていない鍵は既定。
type webCompressSettings struct {
	Audio             *bool          `json:"audio"`
	AudioBitrateKbps  *int           `json:"audioBitrateKbps"`
	UncompressedAudio []string       `json:"uncompressedAudio"`
	Images            *bool          `json:"images"`
	LossyImages       []webLossyRule `json:"lossyImages"`
}

type webLossyRule struct {
	Glob    string `json:"glob"`
	Quality int    `json:"quality"`
}

// webCompress は読み終えた web.compress。
type webCompress struct {
	Audio             bool
	AudioBitrateKbps  int
	UncompressedAudio []webGlob
	Images            bool
	LossyImages       []webLossyGlob
}

type webGlob struct {
	Pattern string
	re      *regexp.Regexp
}

type webLossyGlob struct {
	webGlob
	Quality int
}

const (
	webDefaultAudioKbps = 96
	webMinAudioKbps     = 16
	webMaxAudioKbps     = 320
)

func defaultWebCompress() webCompress {
	return webCompress{Audio: true, AudioBitrateKbps: webDefaultAudioKbps, Images: true}
}

// resolveWebCompress は project.json の web 欄から compress を読む。無ければ既定（音は Opus・絵は lossless の WebP）。
// WhyNot: 知らない鍵を黙って捨てない — audioBitrateKpbs のような綴りの誤りが既定値のまま通り、効いていないことに気付けない。
func resolveWebCompress(raw json.RawMessage) (webCompress, error) {
	c := defaultWebCompress()
	if len(raw) == 0 || string(raw) == "null" {
		return c, nil
	}
	var web struct {
		Compress json.RawMessage `json:"compress"`
	}
	if err := json.Unmarshal(raw, &web); err != nil {
		return c, fmt.Errorf("project.json の web を読めない: %v", err)
	}
	if len(web.Compress) == 0 || string(web.Compress) == "null" {
		return c, nil
	}
	var s webCompressSettings
	dec := json.NewDecoder(bytes.NewReader(web.Compress))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&s); err != nil {
		return c, fmt.Errorf("project.json の web.compress を読めない: %v\n  次: 鍵は audio・audioBitrateKbps・uncompressedAudio・images・lossyImages（[{glob, quality}]）", err)
	}
	if s.Audio != nil {
		c.Audio = *s.Audio
	}
	if s.Images != nil {
		c.Images = *s.Images
	}
	if s.AudioBitrateKbps != nil {
		k := *s.AudioBitrateKbps
		if k < webMinAudioKbps || k > webMaxAudioKbps {
			return c, fmt.Errorf("project.json の web.compress.audioBitrateKbps が %d。\n  次: %d〜%d にする（ステレオの値・モノラルはその半分で詰める）", k, webMinAudioKbps, webMaxAudioKbps)
		}
		c.AudioBitrateKbps = k
	}
	for _, g := range s.UncompressedAudio {
		wg, err := compileWebGlob(g)
		if err != nil {
			return c, fmt.Errorf("project.json の web.compress.uncompressedAudio: %v", err)
		}
		c.UncompressedAudio = append(c.UncompressedAudio, wg)
	}
	for _, r := range s.LossyImages {
		wg, err := compileWebGlob(r.Glob)
		if err != nil {
			return c, fmt.Errorf("project.json の web.compress.lossyImages: %v", err)
		}
		if r.Quality < 1 || r.Quality > 100 {
			return c, fmt.Errorf("project.json の web.compress.lossyImages の %q の quality が %d。\n  次: 1〜100 にする（WebP の画質）", r.Glob, r.Quality)
		}
		c.LossyImages = append(c.LossyImages, webLossyGlob{wg, r.Quality})
	}
	return c, nil
}

// compileWebGlob はゲームの根からの `/` 区切りの道に当てる glob（`*` は 1 段・`**` は何段でも・`?` は 1 字）。
func compileWebGlob(pattern string) (webGlob, error) {
	p := strings.TrimSpace(pattern)
	if p == "" || strings.HasPrefix(p, "/") || strings.Contains(p, "\\") {
		return webGlob{}, fmt.Errorf("glob %q はゲームの根からの `/` 区切りの道にする（例 assets/bg/**/*.png）", pattern)
	}
	var b strings.Builder
	b.WriteString("^")
	for i := 0; i < len(p); i++ {
		switch {
		case strings.HasPrefix(p[i:], "**/"):
			b.WriteString("(?:.*/)?")
			i += 2
		case strings.HasPrefix(p[i:], "**"):
			b.WriteString(".*")
			i++
		case p[i] == '*':
			b.WriteString("[^/]*")
		case p[i] == '?':
			b.WriteString("[^/]")
		default:
			b.WriteString(regexp.QuoteMeta(p[i : i+1]))
		}
	}
	b.WriteString("$")
	re, err := regexp.Compile(b.String())
	if err != nil {
		return webGlob{}, fmt.Errorf("glob %q を読めない: %v", pattern, err)
	}
	return webGlob{Pattern: p, re: re}, nil
}

func (g webGlob) match(rel string) bool { return g.re.MatchString(rel) }

// uncompressedGlobOf は rel に当たる最初の uncompressedAudio の glob の印（当たらなければ nil）。
func (c webCompress) uncompressedGlobOf(rel string) *regexp.Regexp {
	for _, g := range c.UncompressedAudio {
		if g.match(rel) {
			return g.re
		}
	}
	return nil
}

// webEncoders は見つかった変換の道具の道（空は無い）。Dwebp はアトラスの画素を戻して元と比べるのに使う。
type webEncoders struct {
	FFmpeg, Cwebp, Dwebp string
}

// findWebEncoders は PATH → engine の devbox の順に、使う種類の道具（ffmpeg は libopus 付き・cwebp・dwebp）を探す。
// WhyNot: images が false でも cwebp を探す — アトラスは劣化なしで、戻した画素が元とバイト一致した時だけ替えるので、絵の圧縮を止める理由が当たらない。
func findWebEncoders(engine string, c webCompress) webEncoders {
	var e webEncoders
	if p := findWebTool("ffmpeg", engine); c.Audio && p != "" && ffmpegHasLibopus(p) {
		e.FFmpeg = p
	}
	e.Cwebp = findWebTool("cwebp", engine)
	e.Dwebp = findWebTool("dwebp", engine)
	return e
}

func findWebTool(name, engine string) string {
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	exe := name
	if os.PathSeparator == '\\' {
		exe += ".exe"
	}
	if p := filepath.Join(engine, ".devbox", "nix", "profile", "default", "bin", exe); fileExists(p) {
		return p
	}
	return ""
}

func ffmpegHasLibopus(ffmpeg string) bool {
	out, err := exec.Command(ffmpeg, "-hide_banner", "-encoders").Output()
	return err == nil && regexp.MustCompile(`(?m)^\s*A\S*\s+libopus\s`).Match(out)
}

// webSizePair は 1 種類の素材の、変換の前と後の配る大きさ。
type webSizePair struct{ Before, After int64 }

// webTranscodeReport は変換の結果（大きさの表と、知らせの行）。
type webTranscodeReport struct {
	Images, Sounds, Atlases webSizePair
	// FallbackBytes は配る道を替えた音の、元の wav のぶん（置き場には残すが、解けない時だけ取る）。
	FallbackBytes int64
	Notes         []string
}

// webJob は 1 本の変換。encode は src を dst へ書く。
type webJob struct {
	rel, src, dst string
	encode        func(src, dst string) error
}

// transcodeWebAssets は書き出し先に写した素材のうち、小さくなる物だけを WebP・Opus・gzip へ替え（アトラスは画素だけ WebP にした形か gzip の小さい方）、
// b.Transcoded に論理の道 → 配る道を書く。sounds には元の長さとループ点を書く（圧縮しない時も）。
// 道具が無い種類と、1 本だけ変換に失敗した物は元のまま配り、知らせを report.Notes に積む（書き出しは止めない）。
func transcodeWebAssets(out string, b *webBundle, atlases []string, c webCompress, enc webEncoders) webTranscodeReport {
	var r webTranscodeReport
	b.Transcoded = map[string]string{}
	before := map[string]int64{}
	for _, rel := range append(append([]string{}, b.Images...), atlases...) {
		before[rel] = fileSize(exportAssetPath(out, rel))
	}
	for _, s := range b.Sounds {
		before[s.Path] = fileSize(exportAssetPath(out, s.Path))
	}
	taken := map[string]bool{}
	for _, rel := range b.copyList() {
		taken[rel] = true
	}
	for _, a := range atlases {
		taken[a] = true
	}

	var jobs []webJob
	imageJobs, notes := planWebImages(out, b.Images, c, enc, taken)
	r.Notes = append(r.Notes, notes...)
	jobs = append(jobs, imageJobs...)
	soundJobs, notes := planWebSounds(out, b, c, enc, taken)
	r.Notes = append(r.Notes, notes...)
	jobs = append(jobs, soundJobs...)

	errs := runWebJobs(jobs)
	isSound := map[string]bool{}
	for _, s := range b.Sounds {
		isSound[s.Path] = true
	}
	for i, j := range jobs {
		if errs[i] != nil {
			os.Remove(j.dst)
			r.Notes = append(r.Notes, fmt.Sprintf("%s は変換できなかった — 元のまま配る（%v）", j.rel, errs[i]))
			continue
		}
		after := fileSize(j.dst)
		if after <= 0 || after >= before[j.rel] {
			os.Remove(j.dst)
			continue
		}
		b.Transcoded[j.rel] = servedRel(out, j.dst)
		if isSound[j.rel] {
			// WhyNot: 元の wav を消さない — 古い Safari が Opus を解けない時に、頁がこれを取り直して鳴らす。
			r.FallbackBytes += before[j.rel]
			continue
		}
		os.Remove(j.src)
	}

	atlasJobs, notes := planWebAtlases(out, atlases, enc)
	r.Notes = append(r.Notes, notes...)
	for i, err := range runWebJobs(atlasJobs) {
		if err != nil {
			os.Remove(atlasJobs[i].dst)
			r.Notes = append(r.Notes, fmt.Sprintf("%s の画素を WebP にできなかった — gzip で配る（%v）", atlasJobs[i].rel, err))
		}
	}
	for _, a := range atlases {
		if err := settleWebAtlas(out, a, b); err != nil {
			r.Notes = append(r.Notes, fmt.Sprintf("%s を小さくできなかった — 元のまま配る（%v）", a, err))
		}
	}

	sum := func(rels []string) webSizePair {
		var p webSizePair
		for _, rel := range rels {
			p.Before += before[rel]
			p.After += fileSize(exportAssetPath(out, b.served(rel)))
		}
		return p
	}
	soundRels := make([]string, 0, len(b.Sounds))
	for _, s := range b.Sounds {
		soundRels = append(soundRels, s.Path)
	}
	r.Images, r.Sounds, r.Atlases = sum(b.Images), sum(soundRels), sum(atlases)
	if len(b.Transcoded) == 0 {
		b.Transcoded = nil
	}
	return r
}

func servedRel(out, dst string) string {
	rel, _ := filepath.Rel(filepath.Join(out, "assets"), dst)
	return filepath.ToSlash(rel)
}

func fileSize(p string) int64 {
	info, err := os.Stat(p)
	if err != nil {
		return 0
	}
	return info.Size()
}

// planWebImages は png（既定は lossless）と、lossyImages に当たる png・jpg（劣化あり）の変換を組む。
// WhyNot: jpg を lossless の WebP にしない — 解いた画素を劣化なしで詰め直すと、ほぼ必ず元の jpg より大きくなる。
func planWebImages(out string, images []string, c webCompress, enc webEncoders, taken map[string]bool) ([]webJob, []string) {
	var notes []string
	if !c.Images {
		return nil, nil
	}
	used := map[*regexp.Regexp]bool{}
	candidates := 0
	seen := map[string]bool{}
	var jobs []webJob
	for _, rel := range images {
		if seen[rel] {
			continue
		}
		seen[rel] = true
		ext := strings.ToLower(path.Ext(rel))
		q := 0
		for _, r := range c.LossyImages {
			if r.match(rel) {
				used[r.re] = true
				if q == 0 {
					q = r.Quality
				}
			}
		}
		if ext != ".png" && !(q > 0 && (ext == ".jpg" || ext == ".jpeg")) {
			continue
		}
		candidates++
		if enc.Cwebp == "" {
			continue
		}
		target := strings.TrimSuffix(rel, path.Ext(rel)) + ".webp"
		if taken[target] {
			notes = append(notes, fmt.Sprintf("%s は %s が既にあるので WebP にしない", rel, target))
			continue
		}
		taken[target] = true
		cwebp, quality := enc.Cwebp, q
		jobs = append(jobs, webJob{rel: rel, src: exportAssetPath(out, rel), dst: exportAssetPath(out, target),
			encode: func(src, dst string) error { return runQuiet(cwebp, cwebpArgs(src, dst, quality)...) }})
	}
	for _, r := range c.LossyImages {
		if !used[r.re] {
			notes = append(notes, fmt.Sprintf("web.compress.lossyImages の glob %q に当たる絵が無い（textures の道を確かめる）", r.Pattern))
		}
	}
	if enc.Cwebp == "" && candidates > 0 {
		notes = append(notes, "絵は圧縮していない — cwebp（libwebp）が見つからない。入れ方: brew install webp（Windows は libwebp の cwebp.exe を PATH に置く）")
	}
	return jobs, notes
}

// cwebpArgs は WebP の引数。quality が 0 なら劣化なし。
// WhyNot: -exact を外さない — 透明の画素の RGB を書き換えると、乗算の合成や自作のシェーダーが読む色が元の png と変わる。
func cwebpArgs(src, dst string, quality int) []string {
	if quality == 0 {
		return []string{"-quiet", "-lossless", "-exact", "-z", "6", "-metadata", "none", src, "-o", dst}
	}
	return []string{"-quiet", "-q", strconv.Itoa(quality), "-m", "6", "-exact", "-metadata", "none", src, "-o", dst}
}

// planWebSounds は wav の元の長さとループ点を sounds に書き、Opus（WebM）への変換を組む。
func planWebSounds(out string, b *webBundle, c webCompress, enc webEncoders, taken map[string]bool) ([]webJob, []string) {
	var notes []string
	var jobs []webJob
	wavs := 0
	planned := map[string]bool{}
	keptBy := map[*regexp.Regexp]bool{}
	for i := range b.Sounds {
		s := &b.Sounds[i]
		if strings.ToLower(path.Ext(s.Path)) != ".wav" {
			continue
		}
		wavs++
		data, err := os.ReadFile(exportAssetPath(out, s.Path))
		if err != nil {
			notes = append(notes, fmt.Sprintf("%s を読めない — 元のまま配る（%v）", s.Path, err))
			continue
		}
		h, err := wavfile.ReadHeader(data)
		if err != nil {
			notes = append(notes, fmt.Sprintf("%s は 8/16bit の PCM の wav でない — 元のまま配る（%v）", s.Path, err))
			continue
		}
		rate := float64(h.SampleRate)
		s.Seconds = float64(h.Frames) / rate
		if h.Loop != nil {
			s.LoopStart = float64(h.Loop.Start) / rate
			s.LoopEnd = float64(h.Loop.End) / rate
		}
		if kept := c.uncompressedGlobOf(s.Path); kept != nil {
			keptBy[kept] = true
			continue
		}
		if !c.Audio || enc.FFmpeg == "" || planned[s.Path] {
			continue
		}
		planned[s.Path] = true
		target := strings.TrimSuffix(s.Path, path.Ext(s.Path)) + ".webm"
		if taken[target] {
			notes = append(notes, fmt.Sprintf("%s は %s が既にあるので Opus にしない", s.Path, target))
			continue
		}
		taken[target] = true
		kbps := c.AudioBitrateKbps
		if h.Channels == 1 {
			kbps /= 2
		}
		ffmpeg := enc.FFmpeg
		jobs = append(jobs, webJob{rel: s.Path, src: exportAssetPath(out, s.Path), dst: exportAssetPath(out, target),
			encode: func(src, dst string) error { return runQuiet(ffmpeg, opusArgs(src, dst, kbps)...) }})
	}
	for _, g := range c.UncompressedAudio {
		if !keptBy[g.re] {
			notes = append(notes, fmt.Sprintf("web.compress.uncompressedAudio の glob %q に当たる音が無い（sounds の道を確かめる）", g.Pattern))
		}
	}
	if c.Audio && enc.FFmpeg == "" && wavs > 0 {
		notes = append(notes, "音は圧縮していない — libopus 付きの ffmpeg が見つからない。入れ方: brew install ffmpeg（Windows は winget install ffmpeg）")
	}
	return jobs, notes
}

// opusArgs は wav を WebM の Opus にする ffmpeg の引数。
// WhyNot: bitexact を外さない — WebM は乱数の SegmentUID と道具の版を書き込み、同じ素材でも書き出すたびに版のハッシュが変わって、
// 置き先で全部の素材を取り直させる。
func opusArgs(src, dst string, kbps int) []string {
	return []string{"-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", src,
		"-map", "0:a:0", "-c:a", "libopus", "-b:a", strconv.Itoa(kbps) + "k", "-vbr", "on", "-application", "audio",
		"-threads", "1", "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", "-f", "webm", dst}
}

// webAtlasSuffix は、アトラスの画素だけを WebP にした配り方の、配る道の末尾（<道>.fontatlas-webp）。
// 中身は fontbake.SplitPixels の残り（頭・字の表・検算）の後ろに、画素を灰色の絵として劣化なしで詰めた WebP を続けた物。
// 頁（fge-web.js の fgeJoinAtlasPixels）が元のアトラスのバイトに組み直すので、wasm の読み手は gzip の時と同じ物を受け取る。
// WhyNot: 画素を gzip のまま配らない — 距離場はなめらかな階調で、WebP の劣化なしの予測の方が 4 割ほど小さい。
// WhyNot: 頭と字の表を別のファイルにしない — 1 本のアトラスを 2 回取りに行くと、片方だけ古い版が残る置き先で組み直しが壊れる。
const webAtlasSuffix = "-webp"

// planWebAtlases はアトラスの画素を WebP にする変換を組む。cwebp と dwebp が揃わなければ組まない（gzip だけになる）。
// WhyNot: dwebp が無い時に確かめずに替えない — 戻した画素が 1 バイトでも違うと、ブラウザの読み手は検算で落として組み込みフォントで出す。
func planWebAtlases(out string, atlases []string, enc webEncoders) ([]webJob, []string) {
	if len(atlases) == 0 {
		return nil, nil
	}
	if enc.Cwebp == "" || enc.Dwebp == "" {
		return nil, []string{"アトラスは gzip で配る — cwebp と dwebp（libwebp）が揃っていない。入れ方: brew install webp（Windows は libwebp の cwebp.exe と dwebp.exe を PATH に置く）"}
	}
	jobs := make([]webJob, 0, len(atlases))
	for _, rel := range atlases {
		cwebp, dwebp := enc.Cwebp, enc.Dwebp
		jobs = append(jobs, webJob{rel: rel, src: exportAssetPath(out, rel), dst: exportAssetPath(out, rel+webAtlasSuffix),
			encode: func(src, dst string) error { return encodeWebAtlas(cwebp, dwebp, src, dst) }})
	}
	return jobs, nil
}

// encodeWebAtlas は src のアトラスの画素を WebP にし、dwebp で戻して元とバイト一致した時だけ dst を書く。
func encodeWebAtlas(cwebp, dwebp, src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	rest, pixels, side, err := fontbake.SplitPixels(data)
	if err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(filepath.Dir(dst), ".atlas-webp-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	gray := filepath.Join(tmp, "pixels.png")
	if err := writeGrayPng(gray, pixels, side); err != nil {
		return err
	}
	webp := filepath.Join(tmp, "pixels.webp")
	if err := runQuiet(cwebp, cwebpArgs(gray, webp, 0)...); err != nil {
		return err
	}
	back := filepath.Join(tmp, "back.ppm")
	if err := runQuiet(dwebp, "-quiet", webp, "-ppm", "-o", back); err != nil {
		return err
	}
	if err := sameGrayPixels(back, pixels, side); err != nil {
		return err
	}
	webpBytes, err := os.ReadFile(webp)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, append(rest, webpBytes...), 0o644)
}

// WhyNot: 一時の png を強く詰めない — すぐ cwebp が読んで消すので、詰める時間がそのまま書き出しの待ちになる。
func writeGrayPng(path string, pixels []byte, side int) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	img := &image.Gray{Pix: pixels, Stride: side, Rect: image.Rect(0, 0, side, side)}
	if err := (&png.Encoder{CompressionLevel: png.BestSpeed}).Encode(f, img); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// sameGrayPixels は dwebp が書いた PPM（P6・8bit）の 3 つの色の値が、どの画素でも元の灰色の値と同じかを見る。
func sameGrayPixels(ppmPath string, pixels []byte, side int) error {
	data, err := os.ReadFile(ppmPath)
	if err != nil {
		return err
	}
	w, h, maxv, body, err := splitPpm(data)
	if err != nil {
		return fmt.Errorf("dwebp の PPM を読めない: %v", err)
	}
	if w != side || h != side || maxv != 255 || len(body) != side*side*3 {
		return fmt.Errorf("戻した絵が %dx%d（最大 %d・%d バイト）で、元の %dx%d と形が違う", w, h, maxv, len(body), side, side)
	}
	for i, v := range pixels {
		if body[3*i] != v || body[3*i+1] != v || body[3*i+2] != v {
			return fmt.Errorf("戻した画素が元と違う（%d 番目: 元 %d・戻し %v）", i, v, body[3*i:3*i+3])
		}
	}
	return nil
}

// splitPpm は P6 の PPM を頭の 3 つの数（幅・高さ・最大値）と画素の並びに分ける（注釈の行は dwebp が書かないので読まない）。
func splitPpm(data []byte) (w, h, maxv int, body []byte, err error) {
	fields := make([]int, 0, 3)
	at := 2
	if len(data) < 2 || string(data[:2]) != "P6" {
		return 0, 0, 0, nil, fmt.Errorf("頭が P6 でない")
	}
	for len(fields) < 3 {
		for at < len(data) && (data[at] == ' ' || data[at] == '\n' || data[at] == '\r' || data[at] == '\t') {
			at++
		}
		start := at
		for at < len(data) && data[at] >= '0' && data[at] <= '9' {
			at++
		}
		if start == at {
			return 0, 0, 0, nil, fmt.Errorf("頭の数が足りない")
		}
		v, _ := strconv.Atoi(string(data[start:at]))
		fields = append(fields, v)
	}
	if at >= len(data) {
		return 0, 0, 0, nil, fmt.Errorf("画素が無い")
	}
	return fields[0], fields[1], fields[2], data[at+1:], nil
}

// settleWebAtlas は元・gzip・画素を WebP にした形（あれば）のうち一番小さい物を残し、配る道を書く。
func settleWebAtlas(out, rel string, b *webBundle) error {
	src := exportAssetPath(out, rel)
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	gz, err := gzipBytes(data)
	if err != nil {
		return err
	}
	webpPath := src + webAtlasSuffix
	webpSize := fileSize(webpPath)
	switch {
	case webpSize > 0 && webpSize < int64(len(gz)) && webpSize < int64(len(data)):
		b.Transcoded[rel] = rel + webAtlasSuffix
		return os.Remove(src)
	case len(gz) < len(data):
		os.Remove(webpPath)
		if err := os.WriteFile(src+".gz", gz, 0o644); err != nil {
			return err
		}
		b.Transcoded[rel] = rel + ".gz"
		return os.Remove(src)
	default:
		os.Remove(webpPath)
		return nil
	}
}

func gzipBytes(data []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(data); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func runQuiet(name string, args ...string) error {
	c := exec.Command(name, args...)
	var stderr bytes.Buffer
	c.Stderr = &stderr
	if err := c.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if i := strings.IndexByte(msg, '\n'); i >= 0 {
			msg = msg[:i]
		}
		if msg == "" {
			return err
		}
		return fmt.Errorf("%v: %s", err, msg)
	}
	return nil
}

// runWebJobs は変換を CPU の数だけ並べて流し、1 本ずつの誤りを同じ並びで返す。
func runWebJobs(jobs []webJob) []error {
	errs := make([]error, len(jobs))
	next := make(chan int)
	var wg sync.WaitGroup
	for w := 0; w < max(1, runtime.NumCPU()); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range next {
				errs[i] = jobs[i].encode(jobs[i].src, jobs[i].dst)
			}
		}()
	}
	for i := range jobs {
		next <- i
	}
	close(next)
	wg.Wait()
	return errs
}

// served は論理の道を配る道へ（変換していなければそのまま）。
func (b *webBundle) served(rel string) string {
	if s, ok := b.Transcoded[rel]; ok {
		return s
	}
	return rel
}
