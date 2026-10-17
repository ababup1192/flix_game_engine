package main

// waveform の芯。WAV の復号と、白紙を出さない歯止めを確かめる。

import (
	"bytes"
	"encoding/binary"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// buildWAV16 は 16bit PCM の WAV をバイト列で組む。
func buildWAV16(sampleRate, channels int, frames [][]int16) []byte {
	var body bytes.Buffer
	for _, frame := range frames {
		for _, v := range frame {
			_ = binary.Write(&body, binary.LittleEndian, v)
		}
	}
	return wrapWAV(sampleRate, channels, 16, body.Bytes())
}

func wrapWAV(sampleRate, channels, bits int, body []byte) []byte {
	var buf bytes.Buffer
	blockAlign := channels * bits / 8
	buf.WriteString("RIFF")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(36+len(body)))
	buf.WriteString("WAVE")
	buf.WriteString("fmt ")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(16))
	_ = binary.Write(&buf, binary.LittleEndian, uint16(1))
	_ = binary.Write(&buf, binary.LittleEndian, uint16(channels))
	_ = binary.Write(&buf, binary.LittleEndian, uint32(sampleRate))
	_ = binary.Write(&buf, binary.LittleEndian, uint32(sampleRate*blockAlign))
	_ = binary.Write(&buf, binary.LittleEndian, uint16(blockAlign))
	_ = binary.Write(&buf, binary.LittleEndian, uint16(bits))
	buf.WriteString("data")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(len(body)))
	buf.Write(body)
	return buf.Bytes()
}

func TestDecodeWAVReadsMono16(t *testing.T) {
	data := buildWAV16(22050, 1, [][]int16{{0}, {16384}, {-32768}, {0}})
	rate, samples, err := decodeWAV(data)
	if err != nil {
		t.Fatal(err)
	}
	if rate != 22050 || len(samples) != 4 {
		t.Fatalf("サンプルレートと長さが合わない: %d %d", rate, len(samples))
	}
	if got := (soundClip{SampleRate: rate, Samples: samples}).Peak(); math.Abs(got-1.0) > 1e-9 {
		t.Errorf("ピークは 1.0 のはず: %v", got)
	}
}

func TestDecodeWAVAveragesStereo(t *testing.T) {
	data := buildWAV16(22050, 2, [][]int16{{32767, -32767}, {16384, 16384}})
	_, samples, err := decodeWAV(data)
	if err != nil {
		t.Fatal(err)
	}
	if len(samples) != 2 {
		t.Fatalf("ステレオは 1 本に混ぜるはず: %d", len(samples))
	}
	if math.Abs(samples[0]) > 1e-6 {
		t.Errorf("左右で打ち消し合うはず: %v", samples[0])
	}
}

func TestDecodeWAVReads8Bit(t *testing.T) {
	// 8bit PCM は 128 が無音の中心。
	_, samples, err := decodeWAV(wrapWAV(8000, 1, 8, []byte{128, 255, 0}))
	if err != nil {
		t.Fatal(err)
	}
	if len(samples) != 3 || samples[0] != 0 || samples[2] != -1 {
		t.Errorf("中心 128 を 0 とするはず: %v", samples)
	}
}

func TestDecodeWAVRejectsNonPCM(t *testing.T) {
	data := buildWAV16(22050, 1, [][]int16{{0}})
	// fmt チャンクの format を 3 (float) に差し替える。
	binary.LittleEndian.PutUint16(data[20:22], 3)
	if _, _, err := decodeWAV(data); err == nil {
		t.Error("PCM でない形式は理由を返すはず")
	}
}

func TestDecodeWAVRejectsNonRIFF(t *testing.T) {
	if _, _, err := decodeWAV([]byte("not a wav at all")); err == nil {
		t.Error("WAV でないバイト列は理由を返すはず")
	}
}

func TestDurationMSUsesSampleRate(t *testing.T) {
	clip := soundClip{SampleRate: 22050, Samples: make([]float64, 11025)}
	if got := clip.DurationMS(); got != 500 {
		t.Errorf("11025 サンプル / 22050Hz は 500ms のはず: %d", got)
	}
}

func writeToneWAV(t *testing.T, path string, frames int) {
	t.Helper()
	rows := make([][]int16, frames)
	for i := range rows {
		rows[i] = []int16{int16(20000 * math.Sin(2*math.Pi*440*float64(i)/22050))}
	}
	if err := os.WriteFile(path, buildWAV16(22050, 1, rows), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRunWaveformWritesNonBlankPNG(t *testing.T) {
	dir := t.TempDir()
	writeToneWAV(t, filepath.Join(dir, "beep.wav"), 4000)
	outPath := filepath.Join(dir, "sounds.png")
	var out, errOut strings.Builder
	if code := runWaveform(&out, &errOut, []string{dir}, outPath, false); code != 0 {
		t.Fatalf("緑のはず: %d %s", code, errOut.String())
	}
	im, err := pxlib.LoadPNG(outPath)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[[3]byte]bool{}
	for i := 0; i+3 < len(im.Pix); i += 4 {
		seen[[3]byte{im.Pix[i], im.Pix[i+1], im.Pix[i+2]}] = true
	}
	if len(seen) < 4 {
		t.Errorf("白紙に近い絵になっている: 色 %d 種", len(seen))
	}
}

func TestRunWaveformFailsWithoutInput(t *testing.T) {
	dir := t.TempDir()
	var out, errOut strings.Builder
	if code := runWaveform(&out, &errOut, []string{dir}, filepath.Join(dir, "x.png"), false); code == 0 {
		t.Error("WAV が 0 個なら 1 で終わるはず")
	}
	if !strings.Contains(errOut.String(), "見つかりません") {
		t.Errorf("理由を出すはず: %q", errOut.String())
	}
}

func TestRunWaveformFailsWhenAllSilent(t *testing.T) {
	dir := t.TempDir()
	silent := make([][]int16, 500)
	for i := range silent {
		silent[i] = []int16{0}
	}
	if err := os.WriteFile(filepath.Join(dir, "mute.wav"), buildWAV16(22050, 1, silent), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	if code := runWaveform(&out, &errOut, []string{dir}, filepath.Join(dir, "x.png"), false); code == 0 {
		t.Error("全部無音なら 1 で終わるはず")
	}
	if !strings.Contains(errOut.String(), "無音") {
		t.Errorf("無音である旨を出すはず: %q", errOut.String())
	}
}
