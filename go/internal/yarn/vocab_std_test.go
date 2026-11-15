package yarn

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func writeVocabFiles(t *testing.T, vocab, std string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, vocabName), []byte(vocab), 0o644); err != nil {
		t.Fatal(err)
	}
	if std != "" {
		if err := os.WriteFile(filepath.Join(dir, stdVocabName), []byte(std), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return filepath.Join(dir, vocabName)
}

func commandNamesOf(t *testing.T, data []byte) []string {
	t.Helper()
	var root struct {
		Commands map[string]json.RawMessage `json:"commands"`
	}
	if err := json.Unmarshal(data, &root); err != nil {
		t.Fatal(err)
	}
	var names []string
	for k := range root.Commands {
		names = append(names, k)
	}
	sort.Strings(names)
	return names
}

// vocab.std.json の命令は、ゲームの vocab.json の命令と合わせて読む。
func TestStdVocabCommandsAreMergedIntoTheGameVocab(t *testing.T) {
	path := writeVocabFiles(t, `{"version": 2, "commands": {"hop": {"params": []}}}`, `{"version": 2, "commands": {"bg": {"params": []}}}`)
	data, err := readVocab(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(commandNamesOf(t, data), ","); got != "bg,hop" {
		t.Errorf("命令 = %s", got)
	}
}

// vocab.std.json が無ければ vocab.json のまま。
func TestWithoutStdVocabTheGameVocabIsReadAsIs(t *testing.T) {
	path := writeVocabFiles(t, `{"version": 2, "commands": {"hop": {"params": []}}}`, "")
	data, err := readVocab(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(commandNamesOf(t, data), ","); got != "hop" {
		t.Errorf("命令 = %s", got)
	}
}

// 同じ名前の命令が両方にあれば止める。
func TestSameCommandInBothVocabsStops(t *testing.T) {
	path := writeVocabFiles(t, `{"version": 2, "commands": {"bg": {"params": []}}}`, `{"version": 2, "commands": {"bg": {"params": []}}}`)
	if _, err := readVocab(path); err == nil || !strings.Contains(err.Error(), "bg") {
		t.Errorf("err = %v", err)
	}
}

// テンプレートの作例は vocab.json（ゲームの命令）と vocab.std.json（標準の命令）を合わせて、bg の表を引ける。
func TestTemplateVocabFindsStandardCommandsThroughStd(t *testing.T) {
	v, _ := loadV2(t, soundNovelRoot(t))
	if v.Specs["bg"] == nil || v.Specs["tween"] == nil {
		t.Errorf("bg か tween の表が無い")
	}
}
