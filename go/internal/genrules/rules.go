package genrules

// 規約データ (bin/lint-rules/gen-rules.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "gen-rules.json")

// RuleSpec は 1 本のルール。out が出力名・src が元の doc・globs が効かせたいファイル。
// more があるルールは、元の doc のうち芯の印で囲った所だけを出し、末尾に more の 1 行を付ける。
type RuleSpec struct {
	Out   string   `json:"out"`
	Src   string   `json:"src"`
	Globs []string `json:"globs"`
	More  string   `json:"more"`
}

// CoreMarkers は元の doc の中で「rules へ出す芯」を囲む印の行。
type CoreMarkers struct {
	Begin string `json:"begin"`
	End   string `json:"end"`
}

type rulesFile struct {
	Banner      *string      `json:"banner"`
	Rules       *[]RuleSpec  `json:"rules"`
	OutDirs     *[]string    `json:"outDirs"`
	CoreMarkers *CoreMarkers `json:"coreMarkers"`
}

// Rules は生成が使う規約。すべて JSON から来る。
type Rules struct {
	Banner      string
	Rules       []RuleSpec
	OutDirs     []string
	CoreMarkers CoreMarkers
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに既定値へ倒さないのは、規約ファイルを消しただけで
// 中身の違う rules を黙って書き出す穴を作らないため。呼ぶ側は必ずエラーで止める。
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
	missing := ""
	switch {
	case f.Banner == nil:
		missing = "banner"
	case f.Rules == nil:
		missing = "rules"
	case f.OutDirs == nil:
		missing = "outDirs"
	}
	if missing != "" {
		return nil, fmt.Errorf("規約ファイルに %s がありません (%s)", missing, path)
	}
	var markers CoreMarkers
	for _, r := range *f.Rules {
		if r.Out == "" || r.Src == "" {
			return nil, fmt.Errorf("規約ファイルの rules に out か src が無い項目があります (%s)", path)
		}
		if r.More == "" {
			continue
		}
		// WhyNot: 印を任意にしないのは、more を書いたのに印の行が JSON から消えたとき
		// 全文を黙って出す（毎回読む量が元へ戻る）穴を作らないため。
		if f.CoreMarkers == nil || f.CoreMarkers.Begin == "" || f.CoreMarkers.End == "" {
			return nil, fmt.Errorf("規約ファイルの %s に more がありますが coreMarkers (begin・end) がありません (%s)", r.Out, path)
		}
		markers = *f.CoreMarkers
	}
	return &Rules{Banner: *f.Banner, Rules: *f.Rules, OutDirs: *f.OutDirs, CoreMarkers: markers}, nil
}
