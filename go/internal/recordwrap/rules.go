package recordwrap

// 規約データ (bin/lint-rules/record-wrap.json) と、ゲームの除外 (record-wrap.local.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

// Name は規約ファイルの名前 (bin/lint-rules/<Name>.json と <Name>.local.json)。
const Name = "record-wrap"

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath, _ = lintconf.Paths(Name)

// 規則の id。exemptRules の鍵 "<パス>::<id>" の後ろ半分。
const (
	RuleWorldResource = "world-resource"
	RuleWorldFields   = "world-fields"
)

type worldShapeFile struct {
	ResourceTypes *[]string `json:"resourceTypes"`
	MaxTopFields  *int      `json:"maxTopFields"`
}

type rulesFile struct {
	ScopeSuffixes *[]string `json:"scopeSuffixes"`
	SkipPrefixes  *[]string `json:"skipPrefixes"`
	SkipDirNames  *[]string `json:"skipDirNames"`
	Roots         *[]string `json:"roots"`
	Threshold     *int      `json:"threshold"`
	// Exempt は「包まずに残すと決めた欄」。鍵は "モジュール.型::欄名"、値は残す理由 (1 行必須)。
	Exempt *map[string]string `json:"exempt"`
	// WorldShape は World の形の 2 規則 (world-resource・world-fields) の規約。
	WorldShape *worldShapeFile `json:"worldShape"`
	// ExemptRules は World の形の規則の除外。鍵は "根からのパス::規則の id"、値は残す理由 (1 行必須)。
	ExemptRules *map[string]string `json:"exemptRules"`
}

// Rules は検査が使う規約。すべて JSON から来る。
type Rules struct {
	ScopeSuffixes []string
	SkipPrefixes  []string
	SkipDirNames  []string
	// Roots は大きな record を包んで持つべき型 ("モジュール.型")。World の形の 2 規則もこの型を見る。
	Roots     []string
	Threshold int
	// Exempt は配る側と local の exempt を足した物。
	Exempt map[string]string
	// ResourceTypes は World が持ってはいけない型の名前 ("モジュール.型" に当てる正規表現)。
	ResourceTypes []*regexp.Regexp
	MaxTopFields  int
	// ExemptRules は配る側と local の exemptRules を足した物 (Stale で古い除外を裁く)。
	ExemptRules *lintconf.Exempt
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
	case f.WorldShape == nil || f.WorldShape.ResourceTypes == nil:
		return nil, fmt.Errorf("規約ファイルに worldShape.resourceTypes がありません (%s)", path)
	case f.WorldShape.MaxTopFields == nil || *f.WorldShape.MaxTopFields <= 0:
		return nil, fmt.Errorf("規約ファイルの worldShape.maxTopFields は 1 以上の数にしてください (%s)", path)
	case f.ExemptRules == nil:
		return nil, fmt.Errorf("規約ファイルに exemptRules がありません (%s)", path)
	}
	var res []*regexp.Regexp
	for _, pat := range *f.WorldShape.ResourceTypes {
		re, err := regexp.Compile(pat)
		if err != nil {
			return nil, fmt.Errorf("規約ファイルの worldShape.resourceTypes %q が正規表現として壊れています (%s): %v", pat, path, err)
		}
		res = append(res, re)
	}
	exempt, err := lintconf.LoadKey(root, Name, "exempt")
	if err != nil {
		return nil, err
	}
	exemptRules, err := lintconf.LoadKey(root, Name, "exemptRules")
	if err != nil {
		return nil, err
	}
	for key := range exemptRules.Why {
		id := key[strings.LastIndex(key, "::")+2:]
		if id != RuleWorldResource && id != RuleWorldFields {
			return nil, fmt.Errorf("%s の exemptRules %q: 鍵は \"根からのパス::%s\" か \"::%s\" で終えてください",
				exemptRules.From[key], key, RuleWorldResource, RuleWorldFields)
		}
	}
	return &Rules{
		ScopeSuffixes: *f.ScopeSuffixes,
		SkipPrefixes:  *f.SkipPrefixes,
		SkipDirNames:  *f.SkipDirNames,
		Roots:         *f.Roots,
		Threshold:     *f.Threshold,
		Exempt:        exempt.Why,
		ResourceTypes: res,
		MaxTopFields:  *f.WorldShape.MaxTopFields,
		ExemptRules:   exemptRules,
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
