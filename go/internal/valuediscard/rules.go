package valuediscard

// 規約データ (bin/lint-rules/value-discard.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "value-discard.json")

type rulesFile struct {
	ScopeSuffixes *[]string `json:"scopeSuffixes"`
	SkipPrefixes  *[]string `json:"skipPrefixes"`
	Pattern       *string   `json:"pattern"`
	Hint          *string   `json:"hint"`
}

// Rules は検査が使う規約。すべて JSON から来る。
type Rules struct {
	ScopeSuffixes []string
	SkipPrefixes  []string
	// Pattern は値を捨てる書き方 (let _ =)。コメントと文字列の中身を落とした行に当てる。
	Pattern *regexp.Regexp
	// Hint は直し方。画面に出るので空を許さない。
	Hint string
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに空の規約へ倒さないのは、規約ファイルを消しただけで
// 検査が黙って何も見つけない形になるため。呼ぶ側は必ずエラーで止める。
func LoadRules(root string) (*Rules, error) {
	path := filepath.Join(root, RulesPath)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	var f rulesFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("規約ファイルが JSON として壊れています (%s): %v", path, err)
	}
	switch {
	case f.ScopeSuffixes == nil:
		return nil, fmt.Errorf("規約ファイルに scopeSuffixes がありません (%s)", path)
	case f.SkipPrefixes == nil:
		return nil, fmt.Errorf("規約ファイルに skipPrefixes がありません (%s)", path)
	case f.Pattern == nil:
		return nil, fmt.Errorf("規約ファイルに pattern がありません (%s)", path)
	case f.Hint == nil || strings.TrimSpace(*f.Hint) == "":
		return nil, fmt.Errorf("規約ファイルに hint がありません (%s)", path)
	}
	re, err := regexp.Compile(*f.Pattern)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルの pattern が正規表現として壊れています (%s): %v", path, err)
	}
	return &Rules{
		ScopeSuffixes: *f.ScopeSuffixes,
		SkipPrefixes:  *f.SkipPrefixes,
		Pattern:       re,
		Hint:          *f.Hint,
	}, nil
}

// InScope は全量で歩くときに見るパスか。
func (r *Rules) InScope(path string) bool {
	for _, p := range r.SkipPrefixes {
		if strings.HasPrefix(path, p) {
			return false
		}
	}
	return r.IsFlix(path)
}

// IsFlix は中身を読む対象の拡張子か。
// WhyNot: 名指しで渡されたファイルに skipPrefixes を効かせない — 見本 (testdata/)
// を名指しで鳴らせなくなるうえ、人が「このファイルを見て」と言った物を黙って飛ばす形になる。
func (r *Rules) IsFlix(path string) bool {
	for _, s := range r.ScopeSuffixes {
		if strings.HasSuffix(path, s) {
			return true
		}
	}
	return false
}
