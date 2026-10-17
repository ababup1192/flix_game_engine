// Package wavfile は PCM の WAV をチャンネルごとの波形へ開く（fge waveform と fge compare が使う）。
package wavfile

import (
	"encoding/binary"
	"fmt"
	"math"
)

// Decode は PCM の WAV（8bit か 16bit・モノラルかステレオ）をチャンネルごとの -1.0 〜 1.0 の列へ開く
// （ステレオは左・右の順）。返すのはサンプルレートと列。
//
// WhyNot: 読めない形式を無音として通さない。黙って白紙の絵が出ると、
// 音が壊れているのか道具が壊れているのか呼ぶ側から見分けられない。
func Decode(data []byte) (int, [][]float64, error) {
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
	out := make([][]float64, channels)
	for ch := range out {
		out[ch] = make([]float64, frames)
	}
	for i := 0; i < frames; i++ {
		for ch := 0; ch < channels; ch++ {
			at := i*frameSize + ch*bytesPerSample
			if bits == 8 {
				out[ch][i] = (float64(body[at]) - 128.0) / 128.0
				continue
			}
			out[ch][i] = float64(int16(binary.LittleEndian.Uint16(body[at:at+2]))) / 32768.0
		}
	}
	return sampleRate, out, nil
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
