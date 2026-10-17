package waveform

// waveform — WAV の読み口と、WAV を目視できる 1 枚の PNG（コンタクトシート）にする。
// 1 音につき横 1 段。段の中に波形とスペクトログラムを並べ、名前・長さ・
// サンプルレート・ピーク振幅を書き込む。

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"image"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

const (
	wfPadX     = 10  // 左右の余白
	wfPlotW    = 640 // 波形・スペクトログラムの横幅
	wfHeaderH  = 20  // 名前などを書く帯の高さ
	wfWaveH    = 56  // 波形の高さ
	wfSpecH    = 88  // スペクトログラムの高さ
	wfGapH     = 8   // 段と段の間
	wfInnerGap = 4   // 波形とスペクトログラムの間
	wfTextSize = 2   // ドット字の拡大率

	wfWindow  = 512 // スペクトログラムの窓 (サンプル数)
	wfHop     = 256 // 窓を進める幅
	wfMaxHops = 4000
	wfFloorDB = -60.0 // これより弱い成分は真っ黒に潰す
)

var (
	wfBG       = pxlib.RGBA{0x10, 0x12, 0x18, 255}
	wfPanelBG  = pxlib.RGBA{0x1A, 0x1D, 0x26, 255}
	wfText     = pxlib.RGBA{0xE6, 0xE8, 0xF0, 255}
	wfZeroLine = pxlib.RGBA{0x50, 0x56, 0x66, 255}
	wfWave     = pxlib.RGBA{0x7C, 0xE0, 0x8A, 255}
)

// Clip は 1 音ぶんのモノラル波形 (-1.0 〜 1.0)。
type Clip struct {
	Name       string
	SampleRate int
	Samples    []float64
}

func (c Clip) Peak() float64 {
	peak := 0.0
	for _, s := range c.Samples {
		if a := math.Abs(s); a > peak {
			peak = a
		}
	}
	return peak
}

func (c Clip) DurationMS() int {
	if c.SampleRate <= 0 {
		return 0
	}
	return int(math.Round(float64(len(c.Samples)) * 1000.0 / float64(c.SampleRate)))
}

// DecodeWAV は PCM の WAV をモノラルの -1.0 〜 1.0 へ開く。
//
// WhyNot: 読めない形式を無音として通さない。黙って白紙の絵が出ると、
// 音が壊れているのか道具が壊れているのか呼ぶ側から見分けられない。
func DecodeWAV(data []byte) (int, []float64, error) {
	if len(data) < 12 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return 0, nil, fmt.Errorf("RIFF/WAVE ではありません")
	}
	var (
		format     uint16
		channels   int
		sampleRate int
		bits       int
		body       []byte
		haveFmt    bool
	)
	pos := 12
	for pos+8 <= len(data) {
		tag := string(data[pos : pos+4])
		size := int(binary.LittleEndian.Uint32(data[pos+4 : pos+8]))
		start := pos + 8
		end := start + size
		if end > len(data) {
			end = len(data)
		}
		switch tag {
		case "fmt ":
			if end-start < 16 {
				return 0, nil, fmt.Errorf("fmt チャンクが短すぎます")
			}
			format = binary.LittleEndian.Uint16(data[start : start+2])
			channels = int(binary.LittleEndian.Uint16(data[start+2 : start+4]))
			sampleRate = int(binary.LittleEndian.Uint32(data[start+4 : start+8]))
			bits = int(binary.LittleEndian.Uint16(data[start+14 : start+16]))
			haveFmt = true
		case "data":
			body = data[start:end]
		}
		pos = start + size
		if size%2 == 1 {
			pos++
		}
	}
	if !haveFmt {
		return 0, nil, fmt.Errorf("fmt チャンクがありません")
	}
	if format != 1 {
		return 0, nil, fmt.Errorf("PCM (format 1) ではありません: format %d", format)
	}
	if bits != 8 && bits != 16 {
		return 0, nil, fmt.Errorf("対応していないビット数です: %d bit (8 か 16 だけ)", bits)
	}
	if channels < 1 || channels > 2 {
		return 0, nil, fmt.Errorf("対応していないチャンネル数です: %d (モノラルかステレオだけ)", channels)
	}
	if sampleRate <= 0 {
		return 0, nil, fmt.Errorf("サンプルレートが読めません: %d", sampleRate)
	}
	if body == nil {
		return 0, nil, fmt.Errorf("data チャンクがありません")
	}

	bytesPerSample := bits / 8
	frameSize := bytesPerSample * channels
	frames := len(body) / frameSize
	samples := make([]float64, frames)
	for i := 0; i < frames; i++ {
		sum := 0.0
		for ch := 0; ch < channels; ch++ {
			at := i*frameSize + ch*bytesPerSample
			if bits == 8 {
				sum += (float64(body[at]) - 128.0) / 128.0
				continue
			}
			sum += float64(int16(binary.LittleEndian.Uint16(body[at:at+2]))) / 32768.0
		}
		samples[i] = sum / float64(channels)
	}
	return sampleRate, samples, nil
}

func LoadClip(path string) (Clip, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Clip{}, err
	}
	rate, samples, err := DecodeWAV(data)
	if err != nil {
		return Clip{}, fmt.Errorf("%s: %v", filepath.Base(path), err)
	}
	name := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	return Clip{Name: name, SampleRate: rate, Samples: samples}, nil
}

// CollectWAVs は渡された道 (ファイルかフォルダ) から *.wav を名前順に集める。
func CollectWAVs(paths []string) ([]string, error) {
	var found []string
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			return nil, err
		}
		if !info.IsDir() {
			found = append(found, p)
			continue
		}
		entries, err := os.ReadDir(p)
		if err != nil {
			return nil, err
		}
		var inDir []string
		for _, e := range entries {
			if e.IsDir() || !strings.EqualFold(filepath.Ext(e.Name()), ".wav") {
				continue
			}
			inDir = append(inDir, filepath.Join(p, e.Name()))
		}
		sort.Strings(inDir)
		found = append(found, inDir...)
	}
	return found, nil
}

// SpectrogramOf は列 (時間) × 行 (周波数) の 0.0〜1.0 の強さ。行 0 が一番低い周波数。
func SpectrogramOf(samples []float64) [][]float64 {
	bins := wfWindow / 2
	hops := 1
	if len(samples) > wfWindow {
		hops = (len(samples)-wfWindow)/wfHop + 1
	}
	if hops > wfMaxHops {
		hops = wfMaxHops
	}
	window := make([]float64, wfWindow)
	for i := range window {
		window[i] = 0.5 - 0.5*math.Cos(2*math.Pi*float64(i)/float64(wfWindow-1))
	}

	columns := make([][]float64, hops)
	maxMag := 0.0
	for h := 0; h < hops; h++ {
		frame := make([]float64, wfWindow)
		for i := 0; i < wfWindow; i++ {
			at := h*wfHop + i
			if at < len(samples) {
				frame[i] = samples[at] * window[i]
			}
		}
		column := make([]float64, bins)
		for k := 0; k < bins; k++ {
			re, im := 0.0, 0.0
			step := 2 * math.Pi * float64(k) / float64(wfWindow)
			for n := 0; n < wfWindow; n++ {
				angle := step * float64(n)
				re += frame[n] * math.Cos(angle)
				im -= frame[n] * math.Sin(angle)
			}
			mag := math.Hypot(re, im)
			column[k] = mag
			if mag > maxMag {
				maxMag = mag
			}
		}
		columns[h] = column
	}
	if maxMag <= 0 {
		return columns
	}
	for _, column := range columns {
		for k, mag := range column {
			db := 20 * math.Log10(mag/maxMag+1e-12)
			v := (db - wfFloorDB) / (0 - wfFloorDB)
			// WhyNot: 素の比のままにしない。弱い成分まで一様に明るいと、
			// 全部の音が同じ青いもやに見えて強弱が読めなくなる。
			column[k] = math.Pow(math.Max(0, math.Min(1, v)), 1.8)
		}
	}
	return columns
}

// heatColor は強さ 0.0〜1.0 を黒→青→黄→白の色へ。
func heatColor(v float64) pxlib.RGBA {
	v = math.Max(0, math.Min(1, v))
	stops := [][3]float64{
		{0x10, 0x12, 0x18},
		{0x2A, 0x4C, 0xA8},
		{0xE0, 0xC0, 0x40},
		{0xFF, 0xFF, 0xFF},
	}
	scaled := v * float64(len(stops)-1)
	i := int(scaled)
	if i >= len(stops)-1 {
		i = len(stops) - 2
	}
	t := scaled - float64(i)
	mix := func(n int) byte {
		return byte(math.Round(stops[i][n]*(1-t) + stops[i+1][n]*t))
	}
	return pxlib.RGBA{mix(0), mix(1), mix(2), 255}
}

const glyphW = 5

// wfGlyphs は 5x7 のドット字。名前・数値を書くのに要る字だけ持つ。
//
// WhyNot: TrueType を読まない。go.mod に外の依存を足さずに済ませたいのと、
// 書くのが名前と数値だけで、字形の良さより読めることが要るため。
var wfGlyphs = map[rune][7]string{
	'0': {".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."},
	'1': {"..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."},
	'2': {".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"},
	'3': {"#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."},
	'4': {"...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."},
	'5': {"#####", "#....", "####.", "....#", "....#", "#...#", ".###."},
	'6': {"..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."},
	'7': {"#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."},
	'8': {".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."},
	'9': {".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."},
	'a': {".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"},
	'b': {"####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."},
	'c': {".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."},
	'd': {"####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."},
	'e': {"#####", "#....", "#....", "####.", "#....", "#....", "#####"},
	'f': {"#####", "#....", "#....", "####.", "#....", "#....", "#...."},
	'g': {".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."},
	'h': {"#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"},
	'i': {".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."},
	'j': {"..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."},
	'k': {"#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"},
	'l': {"#....", "#....", "#....", "#....", "#....", "#....", "#####"},
	'm': {"#...#", "##.##", "#.#.#", "#...#", "#...#", "#...#", "#...#"},
	'n': {"#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"},
	'o': {".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."},
	'p': {"####.", "#...#", "#...#", "####.", "#....", "#....", "#...."},
	'q': {".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"},
	'r': {"####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"},
	's': {".####", "#....", "#....", ".###.", "....#", "....#", "####."},
	't': {"#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."},
	'u': {"#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."},
	'v': {"#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."},
	'w': {"#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"},
	'x': {"#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"},
	'y': {"#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."},
	'z': {"#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"},
	' ': {".....", ".....", ".....", ".....", ".....", ".....", "....."},
	'.': {".....", ".....", ".....", ".....", ".....", ".##..", ".##.."},
	',': {".....", ".....", ".....", ".....", ".##..", ".##..", ".#..."},
	':': {".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."},
	'-': {".....", ".....", ".....", "#####", ".....", ".....", "....."},
	'_': {".....", ".....", ".....", ".....", ".....", ".....", "#####"},
	'/': {"....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."},
	'%': {"##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##"},
	'(': {"..##.", ".#...", "#....", "#....", "#....", ".#...", "..##."},
	')': {".##..", "...#.", "....#", "....#", "....#", "...#.", ".##.."},
	'+': {".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."},
	'#': {".#.#.", "#####", ".#.#.", ".#.#.", "#####", ".#.#.", "....."},
}

var wfUnknownGlyph = [7]string{"#####", "#...#", "#...#", "#...#", "#...#", "#...#", "#####"}

func glyphOf(r rune) [7]string {
	if got, ok := wfGlyphs[r]; ok {
		return got
	}
	return wfUnknownGlyph
}

type canvas struct {
	w, h int
	grid [][]pxlib.RGBA
}

func newCanvas(w, h int, fill pxlib.RGBA) *canvas {
	grid := make([][]pxlib.RGBA, h)
	for y := range grid {
		row := make([]pxlib.RGBA, w)
		for x := range row {
			row[x] = fill
		}
		grid[y] = row
	}
	return &canvas{w, h, grid}
}

func (c *canvas) set(x, y int, px pxlib.RGBA) {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return
	}
	c.grid[y][x] = px
}

func (c *canvas) fillRect(x, y, w, h int, px pxlib.RGBA) {
	for dy := 0; dy < h; dy++ {
		for dx := 0; dx < w; dx++ {
			c.set(x+dx, y+dy, px)
		}
	}
}

func (c *canvas) drawText(x, y int, text string, px pxlib.RGBA, scale int) {
	at := x
	for _, r := range strings.ToLower(text) {
		rows := glyphOf(r)
		for gy, row := range rows {
			for gx, on := range row {
				if on != '#' {
					continue
				}
				c.fillRect(at+gx*scale, y+gy*scale, scale, scale, px)
			}
		}
		at += (glyphW + 1) * scale
	}
}

func (c *canvas) drawClip(top int, clip Clip) {
	label := fmt.Sprintf("%s  %dms  %dhz  peak %.3f",
		clip.Name, clip.DurationMS(), clip.SampleRate, clip.Peak())
	c.drawText(wfPadX, top+3, label, wfText, wfTextSize)

	waveTop := top + wfHeaderH
	c.fillRect(wfPadX, waveTop, wfPlotW, wfWaveH, wfPanelBG)
	mid := waveTop + wfWaveH/2
	for x := 0; x < wfPlotW; x++ {
		c.set(wfPadX+x, mid, wfZeroLine)
	}
	if len(clip.Samples) > 0 {
		half := float64(wfWaveH/2 - 1)
		for x := 0; x < wfPlotW; x++ {
			from := len(clip.Samples) * x / wfPlotW
			to := len(clip.Samples) * (x + 1) / wfPlotW
			if to <= from {
				to = from + 1
			}
			lo, hi := 0.0, 0.0
			for i := from; i < to && i < len(clip.Samples); i++ {
				if clip.Samples[i] < lo {
					lo = clip.Samples[i]
				}
				if clip.Samples[i] > hi {
					hi = clip.Samples[i]
				}
			}
			yTop := mid - int(math.Round(hi*half))
			yBottom := mid - int(math.Round(lo*half))
			for y := yTop; y <= yBottom; y++ {
				c.set(wfPadX+x, y, wfWave)
			}
		}
	}

	specTop := waveTop + wfWaveH + wfInnerGap
	c.fillRect(wfPadX, specTop, wfPlotW, wfSpecH, wfPanelBG)
	columns := SpectrogramOf(clip.Samples)
	if len(columns) == 0 {
		return
	}
	bins := len(columns[0])
	for x := 0; x < wfPlotW; x++ {
		column := columns[len(columns)*x/wfPlotW]
		for y := 0; y < wfSpecH; y++ {
			bin := bins * (wfSpecH - 1 - y) / wfSpecH
			c.set(wfPadX+x, specTop+y, heatColor(column[bin]))
		}
	}
	// 周波数の目盛 (上端がナイキスト・下端が 0Hz)。
	nyquist := fmt.Sprintf("%dk", clip.SampleRate/2000)
	c.drawText(wfPadX+3, specTop+2, nyquist, wfText, 1)
	c.drawText(wfPadX+3, specTop+wfSpecH-9, "0k", wfText, 1)
}

func rowHeight() int {
	return wfHeaderH + wfWaveH + wfInnerGap + wfSpecH + wfGapH
}

// BuildSheet は 1 音 1 段のコンタクトシートを組む。
func BuildSheet(clips []Clip) (int, int, [][]pxlib.RGBA) {
	w := wfPadX*2 + wfPlotW
	h := wfPadX*2 + rowHeight()*len(clips)
	sheet := newCanvas(w, h, wfBG)
	for i, clip := range clips {
		sheet.drawClip(wfPadX+rowHeight()*i, clip)
	}
	return sheet.w, sheet.h, sheet.grid
}

// EncodePNG は RGBA の格子を PNG のバイト列にする。
func EncodePNG(width, height int, grid [][]pxlib.RGBA) []byte {
	img := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y, row := range grid {
		for x, px := range row {
			i := img.PixOffset(x, y)
			copy(img.Pix[i:i+4], px[:])
		}
	}
	var b bytes.Buffer
	_ = png.Encode(&b, img)
	return b.Bytes()
}

// WriteSheet は WAV のファイルを 1 音 1 段のシートにして outPNG へ書く。
func WriteSheet(paths []string, outPNG string) error {
	var clips []Clip
	for _, p := range paths {
		c, err := LoadClip(p)
		if err != nil {
			return err
		}
		clips = append(clips, c)
	}
	w, h, grid := BuildSheet(clips)
	if err := os.MkdirAll(filepath.Dir(outPNG), 0o755); err != nil {
		return err
	}
	return os.WriteFile(outPNG, EncodePNG(w, h, grid), 0o644)
}
