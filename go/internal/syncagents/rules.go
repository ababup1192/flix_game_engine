package syncagents

// 規約データ (bin/lint-rules/sync-agents.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "sync-agents.json")

type rulesFile struct {
	ManifestPath     *string   `json:"manifestPath"`
	ManifestKeys     *[]string `json:"manifestKeys"`
	SkillsDir        *string   `json:"skillsDir"`
	RulesDir         *string   `json:"rulesDir"`
	LedgerPath       *string   `json:"ledgerPath"`
	CoreDoc          *string   `json:"coreDoc"`
	LocalDoc         *string   `json:"localDoc"`
	AgentsMd         *string   `json:"agentsMd"`
	ClaudeMd         *string   `json:"claudeMd"`
	ClaudeMdBody     *string   `json:"claudeMdBody"`
	SkillFile        *string   `json:"skillFile"`
	SkillLinkPattern *string   `json:"skillLinkPattern"`
	SkillLinkRoots   *[]string `json:"skillLinkRoots"`
	LintPrefix       *string   `json:"lintPrefix"`
	SentenceSep      *string   `json:"sentenceSep"`
	TriggerSuffix    *string   `json:"triggerSuffix"`
}

// Rules は配る側が使う規約。すべて JSON から来る。
type Rules struct {
	ManifestPath   string
	ManifestKeys   []string
	SkillsDir      string
	RulesDir       string
	LedgerPath     string
	CoreDoc        string
	LocalDoc       string
	AgentsMd       string
	ClaudeMd       string
	ClaudeMdBody   string
	SkillFile      string
	SkillLink      *regexp.Regexp
	SkillLinkRoots []string
	LintPrefix     string
	SentenceSep    string
	TriggerSuffix  string
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに既定値へ倒さないのは、規約ファイルを消しただけで
// 中身の違う物を黙って他のリポへ書き込む穴を作らないため。呼ぶ側は必ずエラーで止める。
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
	case f.ManifestPath == nil:
		missing = "manifestPath"
	case f.ManifestKeys == nil:
		missing = "manifestKeys"
	case f.SkillsDir == nil:
		missing = "skillsDir"
	case f.RulesDir == nil:
		missing = "rulesDir"
	case f.LedgerPath == nil:
		missing = "ledgerPath"
	case f.CoreDoc == nil:
		missing = "coreDoc"
	case f.LocalDoc == nil:
		missing = "localDoc"
	case f.AgentsMd == nil:
		missing = "agentsMd"
	case f.ClaudeMd == nil:
		missing = "claudeMd"
	case f.ClaudeMdBody == nil:
		missing = "claudeMdBody"
	case f.SkillFile == nil:
		missing = "skillFile"
	case f.SkillLinkPattern == nil:
		missing = "skillLinkPattern"
	case f.SkillLinkRoots == nil:
		missing = "skillLinkRoots"
	case f.LintPrefix == nil:
		missing = "lintPrefix"
	case f.SentenceSep == nil:
		missing = "sentenceSep"
	case f.TriggerSuffix == nil:
		missing = "triggerSuffix"
	}
	if missing != "" {
		return nil, fmt.Errorf("規約ファイルに %s がありません (%s)", missing, path)
	}
	// WhyNot: 3 つに縛るのは、配る側 (copy / copyIfAbsent / copyDirs) の扱いが
	// キーごとに別々に書かれていて、増減させる余地が無いため。
	if len(*f.ManifestKeys) != 3 {
		return nil, fmt.Errorf("規約ファイルの manifestKeys は 3 つです (%s)", path)
	}
	// WhyNot: pxlib.CompilePy を通さないのは、この正規表現が ASCII の字類しか使わず
	// \w も \b も含まないため（包むと FindAll しか使えず、欲しい丸括弧の中が取れない）。
	link, err := regexp.Compile(*f.SkillLinkPattern)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルの skillLinkPattern が正規表現として壊れています (%s): %v", path, err)
	}
	if link.NumSubexp() != 1 {
		return nil, fmt.Errorf("規約ファイルの skillLinkPattern に丸括弧が 1 組ありません (%s)", path)
	}
	return &Rules{
		ManifestPath:   *f.ManifestPath,
		ManifestKeys:   *f.ManifestKeys,
		SkillsDir:      *f.SkillsDir,
		RulesDir:       *f.RulesDir,
		LedgerPath:     *f.LedgerPath,
		CoreDoc:        *f.CoreDoc,
		LocalDoc:       *f.LocalDoc,
		AgentsMd:       *f.AgentsMd,
		ClaudeMd:       *f.ClaudeMd,
		ClaudeMdBody:   *f.ClaudeMdBody,
		SkillFile:      *f.SkillFile,
		SkillLink:      link,
		SkillLinkRoots: *f.SkillLinkRoots,
		LintPrefix:     *f.LintPrefix,
		SentenceSep:    *f.SentenceSep,
		TriggerSuffix:  *f.TriggerSuffix,
	}, nil
}
