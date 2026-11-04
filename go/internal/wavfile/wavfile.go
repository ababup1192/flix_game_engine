// Package wavfile は PCM の WAV をチャンネルごとの波形へ開く（fge waveform と fge compare が使う）。
package wavfile

import (
	"encoding/binary"
	"fmt"
	"math"
)

// Header は PCM の WAV の形（中身の波形を開かずに読める所）。
type Header struct {
	Channels   int
	SampleRate int
	Bits       int
	Frames     int
	// Loop は smpl の最初のループ [頭, 終わり)（フレームの番号）。無い・使えない時は nil。
	Loop *Loop
	body []byte
}

// Loop はループ点。End は含まない。
type Loop struct{ Start, End int }

// ReadHeader は PCM の WAV（8bit か 16bit・モノラルかステレオ）の形とループ点を読む。
// ループ点はデスクトップ（engine の AudioUtil.loopPointsOf と Audio の読み込み）と同じ条件で採る:
// smpl が 60 バイト以上・ループが 1 本以上・0 ≤ 頭 ≤ 最後・最後 + 1 ≤ フレーム数。
//
// WhyNot: 読めない形式を無音として通さない。黙って白紙の絵が出ると、
// 音が壊れているのか道具が壊れているのか呼ぶ側から見分けられない。
func ReadHeader(data []byte) (Header, error) {
	var h Header
	if len(data) < 12 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return h, fmt.Errorf("RIFF/WAVE ではありません")
	}
	var (
		format  uint16
		smpl    []byte
		haveFmt bool
	)
	pos := 12
	for pos+8 <= len(data) {
		tag := string(data[pos : pos+4])
		size := int(binary.LittleEndian.Uint32(data[pos+4 : pos+8]))
		start := pos + 8
		end := start + size
		if end > len(data) || end < start {
			end = len(data)
		}
		switch tag {
		case "fmt ":
			if end-start < 16 {
				return h, fmt.Errorf("fmt チャンクが短すぎます")
			}
			format = binary.LittleEndian.Uint16(data[start : start+2])
			h.Channels = int(binary.LittleEndian.Uint16(data[start+2 : start+4]))
			h.SampleRate = int(binary.LittleEndian.Uint32(data[start+4 : start+8]))
			h.Bits = int(binary.LittleEndian.Uint16(data[start+14 : start+16]))
			// WAVE_FORMAT_EXTENSIBLE は中身の形をサブフォーマットの GUID の頭 2 バイトに持つ。
			if format == 0xFFFE && end-start >= 26 {
				format = binary.LittleEndian.Uint16(data[start+24 : start+26])
			}
			haveFmt = true
		case "data":
			h.body = data[start:end]
		case "smpl":
			smpl = data[start:end]
		}
		pos = start + size
		if size%2 == 1 {
			pos++
		}
	}
	if !haveFmt {
		return h, fmt.Errorf("fmt チャンクがありません")
	}
	if format != 1 {
		return h, fmt.Errorf("PCM (format 1) ではありません: format %d", format)
	}
	if h.Bits != 8 && h.Bits != 16 {
		return h, fmt.Errorf("対応していないビット数です: %d bit (8 か 16 だけ)", h.Bits)
	}
	if h.Channels < 1 || h.Channels > 2 {
		return h, fmt.Errorf("対応していないチャンネル数です: %d (モノラルかステレオだけ)", h.Channels)
	}
	if h.SampleRate <= 0 {
		return h, fmt.Errorf("サンプルレートが読めません: %d", h.SampleRate)
	}
	if h.body == nil {
		return h, fmt.Errorf("data チャンクがありません")
	}
	h.Frames = len(h.body) / (h.Bits / 8 * h.Channels)
	if len(smpl) >= 60 && int32(binary.LittleEndian.Uint32(smpl[28:])) >= 1 {
		start := int(int32(binary.LittleEndian.Uint32(smpl[36+8:])))
		last := int(int32(binary.LittleEndian.Uint32(smpl[36+12:])))
		if start >= 0 && last >= start && last+1 <= h.Frames {
			h.Loop = &Loop{Start: start, End: last + 1}
		}
	}
	return h, nil
}

// Decode は PCM の WAV（8bit か 16bit・モノラルかステレオ）をチャンネルごとの -1.0 〜 1.0 の列へ開く
// （ステレオは左・右の順）。返すのはサンプルレートと列。
func Decode(data []byte) (int, [][]float64, error) {
	h, err := ReadHeader(data)
	if err != nil {
		return 0, nil, err
	}
	bytesPerSample := h.Bits / 8
	frameSize := bytesPerSample * h.Channels
	out := make([][]float64, h.Channels)
	for ch := range out {
		out[ch] = make([]float64, h.Frames)
	}
	for i := 0; i < h.Frames; i++ {
		for ch := 0; ch < h.Channels; ch++ {
			at := i*frameSize + ch*bytesPerSample
			if h.Bits == 8 {
				out[ch][i] = (float64(h.body[at]) - 128.0) / 128.0
				continue
			}
			out[ch][i] = float64(int16(binary.LittleEndian.Uint16(h.body[at:at+2]))) / 32768.0
		}
	}
	return h.SampleRate, out, nil
}

// Summary は比べるときに並べる形と大きさ。
type Summary struct {
	Channels   int
	SampleRate int
	Seconds    float64
	Peaks      []float64 // チャンネルごとのピーク（0〜1）
}

// Summarize は WAV のバイト列から Summary を作る。
func Summarize(data []byte) (Summary, error) {
	rate, chans, err := Decode(data)
	if err != nil {
		return Summary{}, err
	}
	peaks := make([]float64, len(chans))
	for i, ch := range chans {
		for _, v := range ch {
			peaks[i] = math.Max(peaks[i], math.Abs(v))
		}
	}
	return Summary{len(chans), rate, float64(len(chans[0])) / float64(rate), peaks}, nil
}

// String は「2ch 44100Hz 93.33 秒 ピーク L 0.891 R 0.876」の形（モノラルは「ピーク 0.891」）。
func (s Summary) String() string {
	head := fmt.Sprintf("%dch %dHz %.2f 秒", s.Channels, s.SampleRate, s.Seconds)
	if len(s.Peaks) == 2 {
		return fmt.Sprintf("%s ピーク L %.3f R %.3f", head, s.Peaks[0], s.Peaks[1])
	}
	if len(s.Peaks) == 1 {
		return fmt.Sprintf("%s ピーク %.3f", head, s.Peaks[0])
	}
	return head
}
