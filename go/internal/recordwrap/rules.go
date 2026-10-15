package recordwrap

// 規約データ (bin/lint-rules/record-wrap.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "record-wrap.json")

type rulesFile struct {
	ScopeSuffixes *[]string `json:"scopeSuffixes"`
	SkipPrefixes  *[]string `json:"skipPrefixes"`
	SkipDirNames  *[]string `json:"skipDirNames"`
	Roots         *[]string `json:"roots"`
	Threshold     *int      `json:"threshold"`
	// Exempt は「包まずに残すと決めた欄」。鍵は "モジュール.型::欄名"、値は残す理由 (1 行必須)。
	Exempt *map[string]string `json:"exempt"`
}

// Rules は検査が使う規約。すべて JSON から来る。
type Rules struct {
	ScopeSuffixes []string
	SkipPrefixes  []string
	SkipDirNames  []string
	// Roots は大きな record を包んで持つべき型 ("モジュール.型")。
	Roots     []string
	Threshold int
	Exempt    map[string]string
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
	case f.SkipDirNames == nil:
		return nil, fmt.Errorf("規約ファイルに skipDirNames がありません (%s)", path)
	case f.Roots == nil:
		return nil, fmt.Errorf("規約ファイルに roots がありません (%s)", path)
	case f.Threshold == nil || *f.Threshold <= 0:
		return nil, fmt.Errorf("規約ファイルの threshold は 1 以上の数にしてください (%s)", path)
	case f.Exempt == nil:
		return nil, fmt.Errorf("規約ファイルに exempt がありません (%s)", path)
	}
	for key, reason := range *f.Exempt {
		if !strings.Contains(key, "::") || strings.TrimSpace(reason) == "" {
			return nil, fmt.Errorf("規約ファイルの exempt %q は \"モジュール.型::欄名\" と理由 1 行の形にしてください (%s)", key, path)
		}
	}
	return &Rules{
		ScopeSuffixes: *f.ScopeSuffixes,
		SkipPrefixes:  *f.SkipPrefixes,
		SkipDirNames:  *f.SkipDirNames,
		Roots:         *f.Roots,
		Threshold:     *f.Threshold,
		Exempt:        *f.Exempt,
	}, nil
}

// IsFlix は検査の対象になる拡張子か。
func (r *Rules) IsFlix(path string) bool {
	for _, s := range r.ScopeSuffixes {
		if strings.HasSuffix(path, s) {
			return true
		}
	}
	return false
}

func (r *Rules) hasSkipPrefix(rel string) bool {
	for _, p := range r.SkipPrefixes {
		if strings.HasPrefix(rel, p) {
			return true
		}
	}
	return false
}

func (r *Rules) isSkipDirName(name string) bool {
	for _, n := range r.SkipDirNames {
		if name == n {
			return true
		}
	}
	return false
}
