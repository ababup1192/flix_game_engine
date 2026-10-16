package apiindex

// 規約データ (bin/lint-rules/check-api-index.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "check-api-index.json")

// Target は「ソースの根」と「そこを案内する索引」の対。索引の粒度はモジュール単位。
type Target struct {
	Src string `json:"src"`
	Doc string `json:"doc"`
	// Parts は索引の本文を分けた先（glob。例: docs/modules/*.md）。Doc と合わせて 1 つの索引として見る。
	// 省略すると Doc だけ。
	Parts string `json:"parts,omitempty"`
}

type rulesFile struct {
	Targets []Target `json:"targets"`
	// ExtraDefSources は索引を持たないが実在確認だけには混ぜるソースの根。
	ExtraDefSources *[]string          `json:"extraDefSources"`
	Exempt          *map[string]string `json:"exempt"`
	SkipDirs        *[]string          `json:"skipDirs"`
	FileExts        *[]string          `json:"fileExts"`
}

// Rules は検査が使う規約。すべて JSON から来る。
type Rules struct {
	Targets         []Target
	ExtraDefSources []string
	// Exempt は索引に載せないモジュール。値は理由（1 行必須）。
	Exempt map[string]string
	// SkipDirs はこの名前のフォルダの配下を丸ごと見ないという指定。
	SkipDirs map[string]bool
	// FileExts は「App.flix」のようなファイル名参照を関数参照と誤認しないための拡張子。
	FileExts map[string]bool
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに既定値へ倒さないのは、規約ファイルを消しただけで検査の意味が
// 静かに変わる穴を作らないため。呼ぶ側は必ずエラーで止める。
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
	if len(f.Targets) == 0 {
		return nil, fmt.Errorf("規約ファイルに targets がありません (%s)", path)
	}
	for _, t := range f.Targets {
		if t.Src == "" || t.Doc == "" {
			return nil, fmt.Errorf("規約ファイルの targets に src / doc の欠けがあります (%s)", path)
		}
	}
	if f.ExtraDefSources == nil {
		return nil, fmt.Errorf("規約ファイルに extraDefSources がありません (%s)", path)
	}
	if f.Exempt == nil {
		return nil, fmt.Errorf("規約ファイルに exempt がありません (%s)", path)
	}
	for key, reason := range *f.Exempt {
		if reason == "" {
			return nil, fmt.Errorf("規約ファイルの exempt %q に理由がありません (%s)", key, path)
		}
	}
	if f.SkipDirs == nil {
		return nil, fmt.Errorf("規約ファイルに skipDirs がありません (%s)", path)
	}
	if f.FileExts == nil {
		return nil, fmt.Errorf("規約ファイルに fileExts がありません (%s)", path)
	}
	return &Rules{
		Targets:         f.Targets,
		ExtraDefSources: *f.ExtraDefSources,
		Exempt:          *f.Exempt,
		SkipDirs:        setOf(*f.SkipDirs),
		FileExts:        setOf(*f.FileExts),
	}, nil
}

func setOf(items []string) map[string]bool {
	out := map[string]bool{}
	for _, s := range items {
		out[s] = true
	}
	return out
}
