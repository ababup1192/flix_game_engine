package waveform

// waveform — WAV の読み口と、WAV を目視できる 1 枚の PNG（コンタクトシート）にする。
// 1 音につき横 1 段。段の中に波形とスペクトログラムを並べ、名前・長さ・
// サンプルレート・ピーク振幅を書き込む。ステレオは波形の欄を上下に割って左（上）と右（下）を描き、
// 左右それぞれのピークと、左右の差の大きさ（side / mid）を書く。スペクトログラムは左右の平均。

import (
	"bytes"
	"fmt"
	"image"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
	"github.com/ababup1192/flix_game_engine/go/internal/wavfile"
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

// Clip は 1 音ぶんの波形 (-1.0 〜 1.0)。Samples は左右の平均（モノラルならそのまま）、
// Channels はチャンネルごとの列（モノラルは 1 本・ステレオは左・右の 2 本）。
type Clip struct {
	Name       string
	SampleRate int
	Samples    []float64
	Channels   [][]float64
}

func peakOf(samples []float64) float64 {
	peak := 0.0
	for _, s := range samples {
		if a := math.Abs(s); a > peak {
			peak = a
		}
	}
	return peak
}

// Peak はどのチャンネルかで一番大きな振れ幅（左右で打ち消し合う音を無音と見誤らない）。
func (c Clip) Peak() float64 {
	if len(c.Channels) == 0 {
		return peakOf(c.Samples)
	}
	peak := 0.0
	for _, ch := range c.Channels {
		peak = math.Max(peak, peakOf(ch))
	}
	return peak
}

func (c Clip) IsStereo() bool { return len(c.Channels) == 2 }

// SidePeaks は左右それぞれのピーク。モノラルは両方とも同じ値。
func (c Clip) SidePeaks() (float64, float64) {
	if !c.IsStereo() {
		p := c.Peak()
		return p, p
	}
	return peakOf(c.Channels[0]), peakOf(c.Channels[1])
}

// SideToMid は左右の差 (L-R)/2 の RMS を、左右の和 (L+R)/2 の RMS で割った値。
// 0 = 左右が同じ（モノラルと同じに聞こえる）・大きいほど左右に広がる。モノラルと無音は 0。
func (c Clip) SideToMid() float64 {
	if !c.IsStereo() {
		return 0
	}
	var side, mid float64
	l, r := c.Channels[0], c.Channels[1]
	for i := 0; i < len(l) && i < len(r); i++ {
		d, s := (l[i]-r[i])/2, (l[i]+r[i])/2
		side += d * d
		mid += s * s
	}
	if mid == 0 {
		return 0
	}
	return math.Sqrt(side / mid)
}

func (c Clip) DurationMS() int {
	if c.SampleRate <= 0 {
		return 0
	}
	return int(math.Round(float64(len(c.Samples)) * 1000.0 / float64(c.SampleRate)))
}

// DecodeWAVChannels は PCM の WAV をチャンネルごとの -1.0 〜 1.0 の列へ開く（ステレオは左・右の順。中身は wavfile.Decode）。
func DecodeWAVChannels(data []byte) (int, [][]float64, error) {
	return wavfile.Decode(data)
}

// DecodeWAV は PCM の WAV をモノラルの -1.0 〜 1.0 へ開く（ステレオは左右の平均）。
func DecodeWAV(data []byte) (int, []float64, error) {
	rate, channels, err := DecodeWAVChannels(data)
	if err != nil {
		return 0, nil, err
	}
	return rate, averageOf(channels), nil
}

func averageOf(channels [][]float64) []float64 {
	if len(channels) == 1 {
		return channels[0]
	}
	out := make([]float64, len(channels[0]))
	for i := range out {
		sum := 0.0
		for _, ch := range channels {
			sum += ch[i]
		}
		out[i] = sum / float64(len(channels))
	}
	return out
}

func LoadClip(path string) (Clip, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Clip{}, err
	}
	rate, channels, err := DecodeWAVChannels(data)
	if err != nil {
		return Clip{}, fmt.Errorf("%s: %v", filepath.Base(path), err)
	}
	name := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	return Clip{Name: name, SampleRate: rate, Samples: averageOf(channels), Channels: channels}, nil
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
	if clip.IsStereo() {
		l, r := clip.SidePeaks()
		// 帯の字は横 53 字まで入るので、ステレオは短く: l / r = 左右のピーク・side = 左右の差の大きさ。
		label = fmt.Sprintf("%s  %dms %dhz  l %.2f r %.2f side %.2f",
			clip.Name, clip.DurationMS(), clip.SampleRate, l, r, clip.SideToMid())
	}
	c.drawText(wfPadX, top+3, label, wfText, wfTextSize)

	waveTop := top + wfHeaderH
	c.fillRect(wfPadX, waveTop, wfPlotW, wfWaveH, wfPanelBG)
	if clip.IsStereo() {
		// 上半分が左・下半分が右。
		c.drawWave(waveTop, wfWaveH/2, clip.Channels[0])
		c.drawWave(waveTop+wfWaveH/2, wfWaveH/2, clip.Channels[1])
	} else {
		c.drawWave(waveTop, wfWaveH, clip.Samples)
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

// drawWave は top から高さ h の帯に、samples の振れ幅を横 wfPlotW に縮めて描く（真ん中が 0）。
func (c *canvas) drawWave(top, h int, samples []float64) {
	mid := top + h/2
	for x := 0; x < wfPlotW; x++ {
		c.set(wfPadX+x, mid, wfZeroLine)
	}
	if len(samples) == 0 {
		return
	}
	half := float64(h/2 - 1)
	for x := 0; x < wfPlotW; x++ {
		from := len(samples) * x / wfPlotW
		to := len(samples) * (x + 1) / wfPlotW
		if to <= from {
			to = from + 1
		}
		lo, hi := 0.0, 0.0
		for i := from; i < to && i < len(samples); i++ {
			if samples[i] < lo {
				lo = samples[i]
			}
			if samples[i] > hi {
				hi = samples[i]
			}
		}
		yTop := mid - int(math.Round(hi*half))
		yBottom := mid - int(math.Round(lo*half))
		for y := yTop; y <= yBottom; y++ {
			c.set(wfPadX+x, y, wfWave)
		}
	}
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
