package yarn

// 標準の命令の表（vocab.std.json）を、同じフォルダの vocab.json の commands に合わせる。
// テンプレートが標準の命令の表を vocab.std.json に書き、ゲームの vocab.json は自分の命令の表だけを持つ
// （テンプレートの追随で vocab.std.json を上書きしても、ゲームの vocab.json を書き直さずに済む）。

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const stdVocabName = "vocab.std.json"

// readVocab は vocabPath の語彙を読み、隣に vocab.std.json があればその commands を合わせた語彙の JSON を返す。
// 同じ名前の命令が両方にあれば止める（どちらの表で検査するかが決まらない）。vocab.std.json が無ければ vocab.json のまま。
func readVocab(vocabPath string) ([]byte, error) {
	data, err := os.ReadFile(vocabPath)
	if err != nil {
		return nil, err
	}
	stdPath := filepath.Join(filepath.Dir(vocabPath), stdVocabName)
	std, err := os.ReadFile(stdPath)
	if errors.Is(err, fs.ErrNotExist) {
		return data, nil
	}
	if err != nil {
		return nil, fmt.Errorf("%s を読めない: %v", stdVocabName, err)
	}
	return mergeStdVocab(data, std)
}

// mergeStdVocab は語彙 data の commands に、std の commands を足した JSON を返す。
func mergeStdVocab(data, std []byte) ([]byte, error) {
	var game map[string]json.RawMessage
	if err := json.Unmarshal(data, &game); err != nil {
		return nil, fmt.Errorf("語彙の JSON を読めない: %v", err)
	}
	var stdRoot struct {
		Commands map[string]json.RawMessage `json:"commands"`
	}
	if err := json.Unmarshal(std, &stdRoot); err != nil {
		return nil, fmt.Errorf("%s の JSON を読めない: %v", stdVocabName, err)
	}
	commands := map[string]json.RawMessage{}
	if raw, ok := game["commands"]; ok && len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &commands); err != nil {
			return nil, fmt.Errorf("語彙の commands は名前を鍵にした object で書く（%s と合わせる時）: %v", stdVocabName, err)
		}
	}
	var dup []string
	for name, spec := range stdRoot.Commands {
		if _, ok := commands[name]; ok {
			dup = append(dup, name)
			continue
		}
		commands[name] = spec
	}
	if len(dup) > 0 {
		sort.Strings(dup)
		return nil, fmt.Errorf("命令 %s が vocab.json と %s の両方にある（ゲームの命令は標準の命令と名前を重ねない）", strings.Join(dup, "・"), stdVocabName)
	}
	merged, err := json.Marshal(commands)
	if err != nil {
		return nil, err
	}
	game["commands"] = merged
	return json.Marshal(game)
}
