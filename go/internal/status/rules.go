package status

// 規約データ (bin/lint-rules/status.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "status.json")

type rulesFile struct {
	MaxLines           *int     `json:"maxLines"`
	BuildWarnEntries   *int     `json:"buildWarnEntries"`
	Sections           []string `json:"sections"`
	AgeJustNowSeconds  *float64 `json:"ageJustNowSeconds"`
	AgeMinuteSeconds   *float64 `json:"ageMinuteSeconds"`
	AgeHourSeconds     *float64 `json:"ageHourSeconds"`
	GitLogCount        *int     `json:"gitLogCount"`
	GreensShown        *int     `json:"greensShown"`
	ReferenceBadShown  *int     `json:"referenceBadShown"`
	BudgetDetailLines  *int     `json:"budgetDetailLines"`
	TicketsShown       *int     `json:"ticketsShown"`
	TicketSummaryWidth *int     `json:"ticketSummaryWidth"`
	NotesShown         *int     `json:"notesShown"`
	NotesWidth         *int     `json:"notesWidth"`
	TestLogsDir        *string  `json:"testLogsDir"`
	BuildGlobs         []string `json:"buildGlobs"`
	BuildDirs          []string `json:"buildDirs"`
	CloseRequest       *struct {
		SrcDir      *string `json:"srcDir"`
		AppPattern  *string `json:"appPattern"`
		HookPattern *string `json:"hookPattern"`
		Message     *string `json:"message"`
	} `json:"closeRequest"`
}

// CloseRequestRules は「閉じるボタンの口が繋がっているか」の規約。
type CloseRequestRules struct {
	// SrcDir はゲームのソース根（root からの相対）。
	SrcDir string
	// App は窓を開く呼び出し。これがあるファイルが 1 つも無ければ検査しない。
	App *regexp.Regexp
	// Hook は閉じるボタンを World へ渡す口。
	Hook *regexp.Regexp
	// Message は出す 1 行。
	Message string
}

// Rules は 1 画面の組み立てが使う規約。すべて JSON から来る。
//
// WhyNot: 節の並びを map にしないのは、Go の map が並びを持たず、画面に出る節の順が
// 走らせるたびに変わってしまうため。並びが意味を持つ物は配列で受ける。
type Rules struct {
	MaxLines           int
	BuildWarnEntries   int
	Sections           []string
	AgeJustNowSeconds  float64
	AgeMinuteSeconds   float64
	AgeHourSeconds     float64
	GitLogCount        int
	GreensShown        int
	ReferenceBadShown  int
	BudgetDetailLines  int
	TicketsShown       int
	TicketSummaryWidth int
	NotesShown         int
	NotesWidth         int
	TestLogsDir        string
	BuildGlobs         []string
	BuildDirs          []string
	CloseRequest       CloseRequestRules
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに既定値へ倒さないのは、規約ファイルを消しただけで
// 画面が黙って別物になる穴を作らないため。呼ぶ側は必ずエラーで止める。
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
	case f.MaxLines == nil:
		missing = "maxLines"
	case f.BuildWarnEntries == nil:
		missing = "buildWarnEntries"
	case f.Sections == nil:
		missing = "sections"
	case f.AgeJustNowSeconds == nil:
		missing = "ageJustNowSeconds"
	case f.AgeMinuteSeconds == nil:
		missing = "ageMinuteSeconds"
	case f.AgeHourSeconds == nil:
		missing = "ageHourSeconds"
	case f.GitLogCount == nil:
		missing = "gitLogCount"
	case f.GreensShown == nil:
		missing = "greensShown"
	case f.ReferenceBadShown == nil:
		missing = "referenceBadShown"
	case f.BudgetDetailLines == nil:
		missing = "budgetDetailLines"
	case f.TicketsShown == nil:
		missing = "ticketsShown"
	case f.TicketSummaryWidth == nil:
		missing = "ticketSummaryWidth"
	case f.NotesShown == nil:
		missing = "notesShown"
	case f.NotesWidth == nil:
		missing = "notesWidth"
	case f.TestLogsDir == nil:
		missing = "testLogsDir"
	case f.BuildGlobs == nil:
		missing = "buildGlobs"
	case f.BuildDirs == nil:
		missing = "buildDirs"
	case f.CloseRequest == nil:
		missing = "closeRequest"
	case f.CloseRequest.SrcDir == nil:
		missing = "closeRequest.srcDir"
	case f.CloseRequest.AppPattern == nil:
		missing = "closeRequest.appPattern"
	case f.CloseRequest.HookPattern == nil:
		missing = "closeRequest.hookPattern"
	case f.CloseRequest.Message == nil:
		missing = "closeRequest.message"
	}
	if missing != "" {
		return nil, fmt.Errorf("規約ファイルに %s がありません (%s)", missing, path)
	}
	appRe, err := regexp.Compile(*f.CloseRequest.AppPattern)
	if err != nil {
		return nil, fmt.Errorf("closeRequest.appPattern が正規表現として壊れています (%s): %v", path, err)
	}
	hookRe, err := regexp.Compile(*f.CloseRequest.HookPattern)
	if err != nil {
		return nil, fmt.Errorf("closeRequest.hookPattern が正規表現として壊れています (%s): %v", path, err)
	}
	return &Rules{
		MaxLines:           *f.MaxLines,
		BuildWarnEntries:   *f.BuildWarnEntries,
		Sections:           f.Sections,
		AgeJustNowSeconds:  *f.AgeJustNowSeconds,
		AgeMinuteSeconds:   *f.AgeMinuteSeconds,
		AgeHourSeconds:     *f.AgeHourSeconds,
		GitLogCount:        *f.GitLogCount,
		GreensShown:        *f.GreensShown,
		ReferenceBadShown:  *f.ReferenceBadShown,
		BudgetDetailLines:  *f.BudgetDetailLines,
		TicketsShown:       *f.TicketsShown,
		TicketSummaryWidth: *f.TicketSummaryWidth,
		NotesShown:         *f.NotesShown,
		NotesWidth:         *f.NotesWidth,
		TestLogsDir:        *f.TestLogsDir,
		BuildGlobs:         f.BuildGlobs,
		BuildDirs:          f.BuildDirs,
		CloseRequest: CloseRequestRules{
			SrcDir:  *f.CloseRequest.SrcDir,
			App:     appRe,
			Hook:    hookRe,
			Message: *f.CloseRequest.Message,
		},
	}, nil
}
