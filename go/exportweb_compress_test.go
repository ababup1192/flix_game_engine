package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/fontbake"
	"github.com/ababup1192/flix_game_engine/go/internal/snd"
)

func TestResolveWebCompressWithoutWebIsDefault(t *testing.T) {
	c, err := resolveWebCompress(nil)
	if err != nil || !c.Audio || !c.Images || c.AudioBitrateKbps != webDefaultAudioKbps {
		t.Fatalf("got %+v, %v", c, err)
	}
}

func TestResolveWebCompressAudioFalseKeepsImagesOn(t *testing.T) {
	c, err := resolveWebCompress(json.RawMessage(`{"compress": {"audio": false}}`))
	if err != nil || c.Audio || !c.Images {
		t.Fatalf("got %+v, %v", c, err)
	}
}

func TestResolveWebCompressRejectsUnknownKey(t *testing.T) {
	if _, err := resolveWebCompress(json.RawMessage(`{"compress": {"audioBitrateKpbs": 64}}`)); err == nil {
		t.Fatal("綴りの誤りを通した")
	}
}

func TestResolveWebCompressRejectsBitrateOutOfRange(t *testing.T) {
	if _, err := resolveWebCompress(json.RawMessage(`{"compress": {"audioBitrateKbps": 8}}`)); err == nil {
		t.Fatal("8 kbps を通した")
	}
}

func TestResolveWebCompressRejectsQualityOutOfRange(t *testing.T) {
	if _, err := resolveWebCompress(json.RawMessage(`{"compress": {"lossyImages": [{"glob": "assets/*.png", "quality": 0}]}}`)); err == nil {
		t.Fatal("quality 0 を通した")
	}
}

func TestResolveWebCompressIgnoresOtherWebKeys(t *testing.T) {
	if _, err := resolveWebCompress(json.RawMessage(`{"keysDoc": "assets/k.json", "compress": {"images": false}}`)); err != nil {
		t.Fatal(err)
	}
}

func TestCompileWebGlobDoubleStarMatchesNested(t *testing.T) {
	g, _ := compileWebGlob("assets/bg/**/*.png")
	if !g.match("assets/bg/a/b/c.png") || !g.match("assets/bg/c.png") {
		t.Fatal("** が段を越えない")
	}
}

func TestCompileWebGlobSingleStarStaysInOneLevel(t *testing.T) {
	g, _ := compileWebGlob("assets/*.png")
	if g.match("assets/bg/c.png") {
		t.Fatal("* が / を越えた")
	}
}

// exportFixture は書き出し先の形（<out>/assets/…）に絵 1 枚・音 1 本・アトラス 1 本を置く。
func exportFixture(t *testing.T) (string, webBundle, []string) {
	t.Helper()
	out := t.TempDir()
	put := func(rel string, data []byte) {
		p := exportAssetPath(out, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	wave := make([]float64, 800)
	put("assets/a.png", bytes.Repeat([]byte{1}, 400))
	put("assets/s.wav", snd.EncodeWAV(8000, [][]float64{wave}, 200))
	put("font-atlas/f.fontatlas", make([]byte, 4096))
	b := webBundle{Images: []string{"assets/a.png"}, Sounds: []webSound{{Name: "s", Path: "assets/s.wav", Looping: true}}}
	return out, b, []string{"font-atlas/f.fontatlas"}
}

// fakeToolSized は、出力の道（cwebp は -o の次・ffmpeg は最後の引数）へ size バイトを書く道具を作る。size が負なら失敗する。
func fakeToolSized(t *testing.T, size int) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("sh の道具で差し替えるので windows では飛ばす")
	}
	script := "#!/bin/sh\necho broken >&2\nexit 1\n"
	if size >= 0 {
		script = "#!/bin/sh\n" +
			`out=""; prev=""; for a in "$@"; do if [ "$prev" = "-o" ]; then out="$a"; fi; prev="$a"; last="$a"; done` + "\n" +
			`[ -z "$out" ] && out="$last"` + "\n" +
			"head -c " + strconv.Itoa(size) + ` /dev/zero > "$out"` + "\n"
	}
	p := filepath.Join(t.TempDir(), "tool")
	if err := os.WriteFile(p, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestTranscodeWithoutToolsKeepsFilesAndSaysWhy(t *testing.T) {
	out, b, atlases := exportFixture(t)
	r := transcodeWebAssets(out, &b, atlases, defaultWebCompress(), webEncoders{})
	notes := strings.Join(r.Notes, "\n")
	if !fileExists(exportAssetPath(out, "assets/a.png")) || !strings.Contains(notes, "cwebp") || !strings.Contains(notes, "ffmpeg") {
		t.Fatalf("notes = %q", notes)
	}
}

func TestTranscodeGzipsAtlasWithoutTools(t *testing.T) {
	out, b, atlases := exportFixture(t)
	transcodeWebAssets(out, &b, atlases, defaultWebCompress(), webEncoders{})
	if b.Transcoded["font-atlas/f.fontatlas"] != "font-atlas/f.fontatlas.gz" {
		t.Fatalf("transcoded = %v", b.Transcoded)
	}
}

func TestTranscodeGzipsAtlasWhenDwebpIsMissing(t *testing.T) {
	out, b, atlases := exportFixture(t)
	r := transcodeWebAssets(out, &b, atlases, defaultWebCompress(), webEncoders{Cwebp: fakeToolSized(t, 10)})
	if b.Transcoded["font-atlas/f.fontatlas"] != "font-atlas/f.fontatlas.gz" || !strings.Contains(strings.Join(r.Notes, "\n"), "dwebp") {
		t.Fatalf("transcoded = %v notes = %v", b.Transcoded, r.Notes)
	}
}

// gradientAtlas は RenderFontCache.encode と同じ並びのアトラス（字 2 つ・画素は距離場に似たなめらかな階調）。
func gradientAtlas(side int) []byte {
	var d []byte
	d = binary.BigEndian.AppendUint64(d, 0x46474546_4F4E5402)
	d = binary.BigEndian.AppendUint32(d, 1)
	d = binary.BigEndian.AppendUint32(d, uint32(side))
	d = append(d, make([]byte, 32)...)
	d = binary.BigEndian.AppendUint32(d, 2)
	for _, cp := range []uint32{'A', 0x6CC9} {
		d = binary.BigEndian.AppendUint32(d, cp)
		d = append(d, bytes.Repeat([]byte{7}, 72)...)
	}
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			d = append(d, byte((x*x+y*3)%251))
		}
	}
	return append(d, bytes.Repeat([]byte{9}, 16)...)
}

// 画素を WebP にした形から、頁と同じ手順（WebP を解いて 1 つの色を画素へ）で組み直すと元のアトラスとバイト一致する。
func TestWebpAtlasJoinsBackToSameBytes(t *testing.T) {
	enc := findWebEncoders(engineDirOf(repoRoot()), defaultWebCompress())
	if enc.Cwebp == "" || enc.Dwebp == "" {
		t.Skip("cwebp と dwebp が無い")
	}
	out := t.TempDir()
	rel := "font-atlas/g.fontatlas"
	orig := gradientAtlas(256)
	if err := os.MkdirAll(filepath.Dir(exportAssetPath(out, rel)), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(exportAssetPath(out, rel), orig, 0o644); err != nil {
		t.Fatal(err)
	}
	b := webBundle{}
	transcodeWebAssets(out, &b, []string{rel}, defaultWebCompress(), enc)
	if b.Transcoded[rel] != rel+webAtlasSuffix {
		t.Fatalf("transcoded = %v", b.Transcoded)
	}
	served, _ := os.ReadFile(exportAssetPath(out, rel+webAtlasSuffix))
	restLen := 52 + 2*76 + 16
	webp := filepath.Join(t.TempDir(), "p.webp")
	ppm := webp + ".ppm"
	if err := os.WriteFile(webp, served[restLen:], 0o644); err != nil {
		t.Fatal(err)
	}
	if err := runQuiet(enc.Dwebp, "-quiet", webp, "-ppm", "-o", ppm); err != nil {
		t.Fatal(err)
	}
	ppmBytes, _ := os.ReadFile(ppm)
	_, _, _, rgb, err := splitPpm(ppmBytes)
	if err != nil {
		t.Fatal(err)
	}
	pixels := make([]byte, len(rgb)/3)
	for i := range pixels {
		pixels[i] = rgb[3*i]
	}
	back, err := fontbake.JoinPixels(served[:restLen], pixels)
	if err != nil || !bytes.Equal(back, orig) {
		t.Fatalf("組み直しが元と違う（%v）", err)
	}
}

func TestSameGrayPixelsRejectsOneChangedPixel(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a.ppm")
	_ = os.WriteFile(p, append([]byte("P6\n2 1\n255\n"), 5, 5, 5, 6, 6, 7), 0o644)
	if err := sameGrayPixels(p, []byte{5, 6}, 2); err == nil {
		t.Fatal("1 画素違うのを通した")
	}
}

func TestTranscodeWritesLoopPointsInSeconds(t *testing.T) {
	out, b, atlases := exportFixture(t)
	transcodeWebAssets(out, &b, atlases, defaultWebCompress(), webEncoders{})
	s := b.Sounds[0]
	if s.Seconds != 0.1 || s.LoopStart != 0.025 || s.LoopEnd != 0.1 {
		t.Fatalf("got seconds %v loop [%v, %v)", s.Seconds, s.LoopStart, s.LoopEnd)
	}
}

func TestTranscodeKeepsPngWhenWebpIsLarger(t *testing.T) {
	out, b, atlases := exportFixture(t)
	transcodeWebAssets(out, &b, atlases, defaultWebCompress(), webEncoders{Cwebp: fakeToolSized(t, 1000)})
	if _, ok := b.Transcoded["assets/a.png"]; ok || fileExists(exportAssetPath(out, "assets/a.webp")) {
		t.Fatalf("transcoded = %v", b.Transcoded)
	}
}

func TestTranscodeReplacesPngWhenWebpIsSmaller(t *testing.T) {
	out, b, atlases := exportFixture(t)
	transcodeWebAssets(out, &b, atlases, defaultWebCompress(), webEncoders{Cwebp: fakeToolSized(t, 10)})
	if b.Transcoded["assets/a.png"] != "assets/a.webp" || fileExists(exportAssetPath(out, "assets/a.png")) {
		t.Fatalf("transcoded = %v", b.Transcoded)
	}
}

func TestTranscodeKeepsWavBesideOpus(t *testing.T) {
	out, b, atlases := exportFixture(t)
	transcodeWebAssets(out, &b, atlases, defaultWebCompress(), webEncoders{FFmpeg: fakeToolSized(t, 10)})
	if b.Transcoded["assets/s.wav"] != "assets/s.webm" || !fileExists(exportAssetPath(out, "assets/s.wav")) {
		t.Fatalf("transcoded = %v", b.Transcoded)
	}
}

func TestTranscodeFailedImageKeepsOriginalAndSaysSo(t *testing.T) {
	out, b, atlases := exportFixture(t)
	r := transcodeWebAssets(out, &b, atlases, defaultWebCompress(), webEncoders{Cwebp: fakeToolSized(t, -1)})
	if !fileExists(exportAssetPath(out, "assets/a.png")) || !strings.Contains(strings.Join(r.Notes, "\n"), "assets/a.png は変換できなかった") {
		t.Fatalf("notes = %v", r.Notes)
	}
}

func TestTranscodeUncompressedAudioGlobKeepsWav(t *testing.T) {
	out, b, atlases := exportFixture(t)
	c, _ := resolveWebCompress(json.RawMessage(`{"compress": {"uncompressedAudio": ["assets/*.wav"]}}`))
	transcodeWebAssets(out, &b, atlases, c, webEncoders{FFmpeg: fakeToolSized(t, 10)})
	if _, ok := b.Transcoded["assets/s.wav"]; ok {
		t.Fatalf("transcoded = %v", b.Transcoded)
	}
}

func TestTranscodeSaysWhenLossyGlobMatchesNothing(t *testing.T) {
	out, b, atlases := exportFixture(t)
	c, _ := resolveWebCompress(json.RawMessage(`{"compress": {"lossyImages": [{"glob": "assets/bg/**", "quality": 80}]}}`))
	r := transcodeWebAssets(out, &b, atlases, c, webEncoders{})
	if !strings.Contains(strings.Join(r.Notes, "\n"), `"assets/bg/**" に当たる絵が無い`) {
		t.Fatalf("notes = %v", r.Notes)
	}
}

// 同じ wav から毎回同じバイトの Opus が出る（出なければ書き出しのたびに版のハッシュが変わる）。
func TestOpusOutputIsSameBytesEveryTime(t *testing.T) {
	enc := findWebEncoders(engineDirOf(repoRoot()), defaultWebCompress())
	if enc.FFmpeg == "" {
		t.Skip("libopus 付きの ffmpeg が無い")
	}
	dir := t.TempDir()
	wave := make([]float64, 8000)
	for i := range wave {
		wave[i] = float64(i%100) / 100
	}
	src := filepath.Join(dir, "a.wav")
	if err := os.WriteFile(src, snd.EncodeWAV(16000, [][]float64{wave}, -1), 0o644); err != nil {
		t.Fatal(err)
	}
	var outs [][]byte
	for _, name := range []string{"1.webm", "2.webm"} {
		dst := filepath.Join(dir, name)
		if err := runQuiet(enc.FFmpeg, opusArgs(src, dst, 48)...); err != nil {
			t.Fatal(err)
		}
		data, _ := os.ReadFile(dst)
		outs = append(outs, data)
	}
	if !bytes.Equal(outs[0], outs[1]) {
		t.Fatal("2 回の Opus のバイトが違う")
	}
}
