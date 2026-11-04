package wavfile

import (
	"bytes"
	"encoding/binary"
	"testing"
)

// withSmpl は wav の後ろに、ループ 1 本（頭 start・最後 last）の smpl を足す。
func withSmpl(wav []byte, start, last uint32) []byte {
	var buf bytes.Buffer
	buf.Write(wav)
	buf.WriteString("smpl")
	for _, v := range []uint32{60, 0, 0, 0, 60, 0, 0, 0, 1, 0, 0, 0, start, last, 0, 0} {
		_ = binary.Write(&buf, binary.LittleEndian, v)
	}
	return buf.Bytes()
}

func TestReadHeaderLoopEndExcludesLastSample(t *testing.T) {
	h, err := ReadHeader(withSmpl(wav16(8000, 1, make([]int16, 10)), 2, 7))
	if err != nil {
		t.Fatal(err)
	}
	if h.Loop == nil || *h.Loop != (Loop{Start: 2, End: 8}) {
		t.Fatalf("Loop = %v, want [2, 8)", h.Loop)
	}
}

func TestReadHeaderDropsLoopPastLastFrame(t *testing.T) {
	h, err := ReadHeader(withSmpl(wav16(8000, 1, make([]int16, 10)), 2, 10))
	if err != nil {
		t.Fatal(err)
	}
	if h.Loop != nil {
		t.Fatalf("Loop = %v, want nil", *h.Loop)
	}
}

func TestReadHeaderDropsReversedLoop(t *testing.T) {
	h, _ := ReadHeader(withSmpl(wav16(8000, 1, make([]int16, 10)), 5, 3))
	if h.Loop != nil {
		t.Fatalf("Loop = %v, want nil", *h.Loop)
	}
}

func TestReadHeaderCountsStereoFrames(t *testing.T) {
	h, _ := ReadHeader(wav16(8000, 2, make([]int16, 10)))
	if h.Frames != 5 {
		t.Fatalf("Frames = %d, want 5", h.Frames)
	}
}
