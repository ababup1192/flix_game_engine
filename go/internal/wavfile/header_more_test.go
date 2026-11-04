package wavfile

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestReadHeaderDropsShortSmpl(t *testing.T) {
	wav := withSmpl(wav16(8000, 1, make([]int16, 10)), 2, 7)
	short := append([]byte{}, wav[:len(wav)-68]...)
	short = append(short, "smpl"...)
	short = binary.LittleEndian.AppendUint32(short, 40)
	short = append(short, make([]byte, 40)...)
	h, _ := ReadHeader(short)
	if h.Loop != nil {
		t.Fatalf("Loop = %v, want nil", *h.Loop)
	}
}

func TestReadHeaderDropsSmplWithoutLoops(t *testing.T) {
	wav := withSmpl(wav16(8000, 1, make([]int16, 10)), 2, 7)
	binary.LittleEndian.PutUint32(wav[len(wav)-60+28:], 0)
	h, _ := ReadHeader(wav)
	if h.Loop != nil {
		t.Fatalf("Loop = %v, want nil", *h.Loop)
	}
}

// wav8 は 8bit PCM のモノラルの WAV（n フレーム）。
func wav8(n int) []byte {
	var buf bytes.Buffer
	buf.WriteString("RIFF")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(36+n))
	buf.WriteString("WAVEfmt ")
	for _, v := range []any{uint32(16), uint16(1), uint16(1), uint32(8000), uint32(8000), uint16(1), uint16(8)} {
		_ = binary.Write(&buf, binary.LittleEndian, v)
	}
	buf.WriteString("data")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(n))
	buf.Write(bytes.Repeat([]byte{128}, n))
	return buf.Bytes()
}

func TestReadHeaderCounts8BitFrames(t *testing.T) {
	h, err := ReadHeader(wav8(7))
	if err != nil || h.Frames != 7 {
		t.Fatalf("Frames = %d, err %v", h.Frames, err)
	}
}

// 奇数の長さの data の後ろの詰め物 1 バイトを飛ばして smpl を読む。
func TestReadHeaderSkipsPadByteBeforeSmpl(t *testing.T) {
	h, err := ReadHeader(withSmpl(append(wav8(7), 0), 1, 5))
	if err != nil || h.Loop == nil || *h.Loop != (Loop{Start: 1, End: 6}) {
		t.Fatalf("Loop = %v, err %v", h.Loop, err)
	}
}

// WAVE_FORMAT_EXTENSIBLE でもサブフォーマットが PCM なら読む。
func TestReadHeaderAcceptsExtensiblePcm(t *testing.T) {
	var buf bytes.Buffer
	buf.WriteString("RIFF")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(4+8+40+8+4))
	buf.WriteString("WAVEfmt ")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(40))
	for _, v := range []any{uint16(0xFFFE), uint16(1), uint32(8000), uint32(16000), uint16(2), uint16(16), uint16(22), uint16(16), uint32(4), uint16(1)} {
		_ = binary.Write(&buf, binary.LittleEndian, v)
	}
	buf.Write(make([]byte, 14))
	buf.WriteString("data")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(4))
	buf.Write(make([]byte, 4))
	h, err := ReadHeader(buf.Bytes())
	if err != nil || h.Frames != 2 {
		t.Fatalf("Frames = %d, err %v", h.Frames, err)
	}
}
