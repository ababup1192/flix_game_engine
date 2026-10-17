package snd

// WAV の取り決め: 16bit PCM のモノラル（鳴らす側と同じ。書き方は engine_tools の SfxSynth.wavBytes・
// wavBytesLooped と同じバイト）かステレオ（左右を交互に）。ループのある音は smpl チャンクにループ 1 本
// （頭のフレーム〜最後のフレーム）。ステレオを鳴らす側が読めるかは採用の時の別仕事。

import (
	"encoding/binary"
	"fmt"
)

// quantize16 は SfxSynth.clip16 と同じ: 32767 倍して 0 の向きへ切り捨て、16bit に収める。
func quantize16(x float64) int16 {
	v := x * 32767
	if v != v { // NaN
		return 0
	}
	if v >= 32767 {
		return 32767
	}
	if v <= -32768 {
		return -32768
	}
	return int16(int64(v)) // Go の変換は 0 の向きへ切り捨て（Java の (int) と同じ）
}

// EncodeWAV は 16bit の WAV のバイト列（chans が 1 本ならモノラル・2 本ならステレオ）。
// loopStart が 0 以上・長さ未満なら smpl を付ける。
func EncodeWAV(rate int, chans [][]float64, loopStart int) []byte {
	nc := max(1, len(chans))
	n := 0
	if len(chans) > 0 {
		n = len(chans[0])
	}
	looped := loopStart >= 0 && loopStart < n
	dataSize := n * 2 * nc
	riff := 36 + dataSize
	if looped {
		riff += 68
	}
	b := make([]byte, 0, 8+riff)
	le32 := func(v uint32) { b = binary.LittleEndian.AppendUint32(b, v) }
	le16 := func(v uint16) { b = binary.LittleEndian.AppendUint16(b, v) }
	b = append(b, "RIFF"...)
	le32(uint32(riff))
	b = append(b, "WAVEfmt "...)
	le32(16)
	le16(1)
	le16(uint16(nc))
	le32(uint32(rate))
	le32(uint32(rate * 2 * nc))
	le16(uint16(2 * nc))
	le16(16)
	b = append(b, "data"...)
	le32(uint32(dataSize))
	for i := 0; i < n; i++ {
		for _, ch := range chans {
			le16(uint16(quantize16(ch[i])))
		}
	}
	if looped {
		b = append(b, "smpl"...)
		for _, v := range []uint32{60, 0, 0, uint32(1000000000 / max(1, rate)), 60, 0, 0, 0, 1, 0, 0, 0, uint32(loopStart), uint32(n - 1), 0, 0} {
			le32(v)
		}
	}
	return b
}

// Clip は読んだ WAV 1 本（チャンネルごとの -1〜1・左右を交互に並べた 16bit の値・ループの頭。無ければ -1）。
type Clip struct {
	Rate      int
	Chans     [][]float64
	Ints      []int16
	LoopStart int
	LoopEnd   int
}

// Frames はフレームの数（1 チャンネルぶんのサンプル数）。
func (c Clip) Frames() int {
	if len(c.Chans) == 0 {
		return 0
	}
	return len(c.Chans[0])
}

// DecodeWAV は 16bit PCM のモノラルかステレオの WAV を読む（smpl のループ 1 本目も）。
func DecodeWAV(data []byte) (Clip, error) {
	c := Clip{LoopStart: -1, LoopEnd: -1}
	if len(data) < 12 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return c, fmt.Errorf("RIFF/WAVE ではない")
	}
	pos := 12
	bits, channels := 0, 0
	for pos+8 <= len(data) {
		id := string(data[pos : pos+4])
		size := int(binary.LittleEndian.Uint32(data[pos+4 : pos+8]))
		body := pos + 8
		end := min(len(data), body+size)
		switch id {
		case "fmt ":
			if end-body >= 16 {
				channels = int(binary.LittleEndian.Uint16(data[body+2:]))
				c.Rate = int(binary.LittleEndian.Uint32(data[body+4:]))
				bits = int(binary.LittleEndian.Uint16(data[body+14:]))
			}
		case "data":
			if bits != 16 || channels < 1 || channels > 2 {
				return c, fmt.Errorf("16bit のモノラルかステレオだけ読む（%d bit・%d ch）", bits, channels)
			}
			c.Chans = make([][]float64, channels)
			for i := body; i+1 < end; i += 2 {
				v := int16(binary.LittleEndian.Uint16(data[i:]))
				k := len(c.Ints) % channels
				c.Ints = append(c.Ints, v)
				c.Chans[k] = append(c.Chans[k], float64(v)/32768)
			}
			c.Chans[channels-1] = append(c.Chans[channels-1], make([]float64, len(c.Chans[0])-len(c.Chans[channels-1]))...)
		case "smpl":
			if end-body >= 36+24 && binary.LittleEndian.Uint32(data[body+28:]) > 0 {
				c.LoopStart = int(binary.LittleEndian.Uint32(data[body+36+8:]))
				c.LoopEnd = int(binary.LittleEndian.Uint32(data[body+36+12:]))
			}
		}
		pos = body + size + size%2
	}
	if c.Rate == 0 {
		return c, fmt.Errorf("fmt チャンクが無い")
	}
	return c, nil
}
