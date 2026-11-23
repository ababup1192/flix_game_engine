package dashboard

import (
	"io"
	"strings"
	"sync"
)

const installLogLines = 40

// installState は頁から見る engine の取得の進み具合。
type installState struct {
	mu      sync.Mutex
	running bool
	done    bool
	err     string
	lines   []string
	partial string
}

// InstallView は /_api/state の install の形。
type InstallView struct {
	Running bool     `json:"running"`
	Done    bool     `json:"done"`
	Error   string   `json:"error,omitempty"`
	Log     []string `json:"log"`
}

func (s *installState) view() InstallView {
	s.mu.Lock()
	defer s.mu.Unlock()
	log := append([]string{}, s.lines...)
	if s.partial != "" {
		log = append(log, s.partial)
	}
	return InstallView{Running: s.running, Done: s.done, Error: s.err, Log: log}
}

// begin は走っていなければ running を立てて true を返す。
func (s *installState) begin() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.running {
		return false
	}
	s.running, s.done, s.err = true, false, ""
	s.lines, s.partial = nil, ""
	return true
}

func (s *installState) finish(err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.partial != "" {
		s.appendLine(s.partial)
		s.partial = ""
	}
	s.running = false
	if err != nil {
		s.err = err.Error()
		return
	}
	s.done = true
}

// Write は進み具合の行を受ける。\r で書き直す進み具合は最後の 1 行だけを残す。
func (s *installState) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	text := s.partial + strings.ReplaceAll(string(p), "\r\n", "\n")
	parts := strings.Split(text, "\n")
	for _, line := range parts[:len(parts)-1] {
		s.appendLine(lastSegment(line))
	}
	s.partial = lastSegment(parts[len(parts)-1])
	return len(p), nil
}

func (s *installState) appendLine(line string) {
	if strings.TrimSpace(line) == "" {
		return
	}
	s.lines = append(s.lines, line)
	if n := len(s.lines); n > installLogLines {
		s.lines = s.lines[n-installLogLines:]
	}
}

func lastSegment(line string) string {
	if i := strings.LastIndex(line, "\r"); i >= 0 {
		return line[i+1:]
	}
	return line
}

var _ io.Writer = (*installState)(nil)
