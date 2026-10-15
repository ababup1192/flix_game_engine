package ztable

// 規約データ (bin/lint-rules/z-table.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "z-table.json")

type rulesFile struct {
	ScopeSuffixes  *[]string `json:"scopeSuffixes"`
	SkipPrefixes   *[]string `json:"skipPrefixes"`
	SkipDirNames   *[]string `json:"skipDirNames"`
	TableFileNames *[]string `json:"tableFileNames"`
	ConstPattern   *string   `json:"constPattern"`
	ZDefPattern    *string   `json:"zDefPattern"`
	BorrowWarnOnly *bool     `json:"borrowWarnOnly"`
	// Exempt は「残すと決めた z の数」。鍵は "パス::宣言名"、値は残す理由 (1 行必須)。
	// WhyNot: 行番号でなく名前で持つのは、上の行が増減しても鍵がずれないため。
	Exempt *map[string]string `json:"exempt"`
}

// Rules は検査が使う規約。すべて JSON から来る。
type Rules struct {
	ScopeSuffixes  []string
	SkipPrefixes   []string
	SkipDirNames   []string
	TableFileNames []string
	// Const は z を数で決める 1 行。1 つ目の組が宣言名、2 つ目が数。
	Const *regexp.Regexp
	// ZDef は z を返す関数の宣言 (数で決めた物に限らない)。1 つ目の組が宣言名。借用を見るのに使う。
	ZDef *regexp.Regexp
	// BorrowWarnOnly は借用を出すだけにして、終了コードに数えないか。
	// WhyNot: --warn と分けて持つのは、表の外の数と散らばりは止め、借用だけ様子を見る、を
	// 1 回の呼び出しで両立させるため (precommit は検査ごとに 1 回しか呼ばない)。
	BorrowWarnOnly bool
	Exempt         map[string]string
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
	case f.TableFileNames == nil:
		return nil, fmt.Errorf("規約ファイルに tableFileNames がありません (%s)", path)
	case f.ConstPattern == nil:
		return nil, fmt.Errorf("規約ファイルに constPattern がありません (%s)", path)
	case f.ZDefPattern == nil:
		return nil, fmt.Errorf("規約ファイルに zDefPattern がありません (%s)", path)
	case f.BorrowWarnOnly == nil:
		return nil, fmt.Errorf("規約ファイルに borrowWarnOnly がありません (%s)", path)
	case f.Exempt == nil:
		return nil, fmt.Errorf("規約ファイルに exempt がありません (%s)", path)
	}
	re, err := regexp.Compile(*f.ConstPattern)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルの constPattern が正規表現として壊れています (%s): %v", path, err)
	}
	if re.NumSubexp() != 2 {
		return nil, fmt.Errorf("規約ファイルの constPattern は組を 2 つ (宣言名・数) 持つ形にしてください (%s)", path)
	}
	zdef, err := regexp.Compile(*f.ZDefPattern)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルの zDefPattern が正規表現として壊れています (%s): %v", path, err)
	}
	if zdef.NumSubexp() != 1 {
		return nil, fmt.Errorf("規約ファイルの zDefPattern は組を 1 つ (宣言名) 持つ形にしてください (%s)", path)
	}
	for key, reason := range *f.Exempt {
		if !strings.Contains(key, "::") || strings.TrimSpace(reason) == "" {
			return nil, fmt.Errorf("規約ファイルの exempt %q は \"パス::宣言名\" と理由 1 行の形にしてください (%s)", key, path)
		}
	}
	return &Rules{
		ScopeSuffixes:  *f.ScopeSuffixes,
		SkipPrefixes:   *f.SkipPrefixes,
		SkipDirNames:   *f.SkipDirNames,
		TableFileNames: *f.TableFileNames,
		Const:          re,
		ZDef:           zdef,
		BorrowWarnOnly: *f.BorrowWarnOnly,
		Exempt:         *f.Exempt,
	}, nil
}

// InScope は --all で見るファイルか。
func (r *Rules) InScope(rel string) bool {
	if !r.IsFlix(rel) {
		return false
	}
	for _, p := range r.SkipPrefixes {
		if strings.HasPrefix(rel, p) {
			return false
		}
	}
	return !r.underSkipDir(rel)
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

// underSkipDir はパスの途中に skipDirNames の名前のフォルダがあるか。
// WhyNot: 接頭辞だけで外さないのは、テンプレやゲームの中の test/ と lib/ が
// どの深さにも出るため（test の z は期待値で、表の外にあって正しい）。
func (r *Rules) underSkipDir(rel string) bool {
	parts := strings.Split(rel, "/")
	for _, dir := range parts[:len(parts)-1] {
		for _, name := range r.SkipDirNames {
			if dir == name {
				return true
			}
		}
	}
	return false
}

// IsTable は表のファイルか (名前だけで決める)。
func (r *Rules) IsTable(rel string) bool {
	base := filepath.Base(rel)
	for _, name := range r.TableFileNames {
		if base == name {
			return true
		}
	}
	return false
}
