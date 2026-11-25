package tape

import (
	"fmt"
	"os"
	"sync"
	"testing"
)

// videoCacheDir は makeVideoSized が作った試験の動画の置き場（パッケージのテストの間だけ）。
var (
	videoCacheDir string
	videoCacheMu  sync.Mutex
)

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "tape-video-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	videoCacheDir = dir
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}
