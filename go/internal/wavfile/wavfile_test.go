package wavfile

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// wav16 は 16bit PCM の WAV（channels 本を交互に並べた samples）を組む。
func wav16(rate, channels int, samples []int16) []byte {
	var body, buf bytes.Buffer
	for _, v := range samples {
		_ = binary.Write(&body, binary.LittleEndian, v)
	}
	buf.WriteString("RIFF")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(36+body.Len()))
	buf.WriteString("WAVEfmt ")
	for _, v := range []any{uint32(16), uint16(1), uint16(channels), uint32(rate),
		uint32(rate * 2 * channels), uint16(2 * channels), uint16(16)} {
		_ = binary.Write(&buf, binary.LittleEndian, v)
	}
	buf.WriteString("data")
	_ = binary.Write(&buf, binary.LittleEndian, uint32(body.Len()))
	buf.Write(body.Bytes())
	return buf.Bytes()
}

func TestSummarizeStereoShowsBothPeaks(t *testing.T) {
	s, err := Summarize(wav16(44100, 2, []int16{16384, 0, -8192, 0}))
	if err != nil {
		t.Fatal(err)
	}
	want := "2ch 44100Hz 0.00 秒 ピーク L 0.500 R 0.000"
	if got := s.String(); got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestSummarizeMonoShowsOnePeak(t *testing.T) {
	s, err := Summarize(wav16(10, 1, []int16{16384, -32768, 0, 0, 0}))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := s.String(), "1ch 10Hz 0.50 秒 ピーク 1.000"; got != want {
		t.Errorf("got %q want %q", got, want)
	}
}
