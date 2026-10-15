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

// LocalPath はゲームが自分の除外だけを置く所（無くてよい）。
// WhyNot: 除外を RulesPath に書かせないのは、bin/lint-rules/ はエンジンが配るたびに
// 上書きされ、ゲームの除外が次の追従で消えるため。配り元に無いファイルは sync で残る。
var LocalPath = filepath.Join("bin", "lint-rules", "z-table.local.json")

type rulesFile struct {
	ScopeSuffixes  *[]string `json:"scopeSuffixes"`
	SkipPrefixes   *[]string `json:"skipPrefixes"`
	SkipDirNames   *[]string `json:"skipDirNames"`
	TableFileNames *[]string `json:"tableFileNames"`
	TablePattern   *string   `json:"tablePattern"`
	ConstPattern   *string   `json:"constPattern"`
	ZDefPattern    *string   `json:"zDefPattern"`
	BorrowWarnOnly *bool     `json:"borrowWarnOnly"`
	RemapPattern   *string   `json:"remapPattern"`
	LayerZPattern  *string   `json:"layerZPattern"`
	LeafAbsPattern *string   `json:"leafAbsolutePattern"`
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
	// Table は表の宣言 (instance SortingLayer[...])。コメントを除いた行に 1 つでもあれば、
	// ファイル名が何であっても表のファイルとして扱う。
	Table *regexp.Regexp
	// Const は z を数で決める 1 行。1 つ目の組が宣言名、2 つ目が数。
	Const *regexp.Regexp
	// ZDef は z を返す関数の宣言 (数で決めた物に限らない)。1 つ目の組が宣言名。借用を見るのに使う。
	ZDef *regexp.Regexp
	// BorrowWarnOnly は借用を出すだけにして、終了コードに数えないか。
	// WhyNot: --warn と分けて持つのは、表の外の数と散らばりは止め、借用だけ様子を見る、を
	// 1 回の呼び出しで両立させるため (precommit は検査ごとに 1 回しか呼ばない)。
	BorrowWarnOnly bool
	// Remap は表を持つパッケージで使わない、z を付け替える呼び出し。1 つ目の組が呼んだ関数の名前。
	Remap *regexp.Regexp
	// LayerZ と LeafAbs は移行の間だけ残す口 (SortingLayer.z と ZStack.leafAbsolute) の呼び出し。
	// --all で残りを数え、LayerZ はコミットで新しく足した行を止める。
	LayerZ  *regexp.Regexp
	LeafAbs *regexp.Regexp
	Exempt  map[string]string
	// ExemptFrom は除外の鍵 → どのファイルに書いてあったか (RulesPath か LocalPath)。古い除外の文面に出す。
	ExemptFrom map[string]string
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
	case f.TablePattern == nil:
		return nil, fmt.Errorf("規約ファイルに tablePattern がありません (%s)", path)
	case f.ConstPattern == nil:
		return nil, fmt.Errorf("規約ファイルに constPattern がありません (%s)", path)
	case f.ZDefPattern == nil:
		return nil, fmt.Errorf("規約ファイルに zDefPattern がありません (%s)", path)
	case f.BorrowWarnOnly == nil:
		return nil, fmt.Errorf("規約ファイルに borrowWarnOnly がありません (%s)", path)
	case f.RemapPattern == nil:
		return nil, fmt.Errorf("規約ファイルに remapPattern がありません (%s)", path)
	case f.LayerZPattern == nil:
		return nil, fmt.Errorf("規約ファイルに layerZPattern がありません (%s)", path)
	case f.LeafAbsPattern == nil:
		return nil, fmt.Errorf("規約ファイルに leafAbsolutePattern がありません (%s)", path)
	case f.Exempt == nil:
		return nil, fmt.Errorf("規約ファイルに exempt がありません (%s)", path)
	}
	table, err := regexp.Compile(*f.TablePattern)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルの tablePattern が正規表現として壊れています (%s): %v", path, err)
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
	remap, err := regexp.Compile(*f.RemapPattern)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルの remapPattern が正規表現として壊れています (%s): %v", path, err)
	}
	if remap.NumSubexp() != 1 {
		return nil, fmt.Errorf("規約ファイルの remapPattern は組を 1 つ (呼んだ関数の名前) 持つ形にしてください (%s)", path)
	}
	layerZ, err := regexp.Compile(*f.LayerZPattern)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルの layerZPattern が正規表現として壊れています (%s): %v", path, err)
	}
	leafAbs, err := regexp.Compile(*f.LeafAbsPattern)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルの leafAbsolutePattern が正規表現として壊れています (%s): %v", path, err)
	}
	exempt := map[string]string{}
	from := map[string]string{}
	rulesName := filepath.ToSlash(RulesPath)
	for key, reason := range *f.Exempt {
		if !strings.Contains(key, "::") || strings.TrimSpace(reason) == "" {
			return nil, fmt.Errorf("規約ファイルの exempt %q は \"パス::宣言名\" と理由 1 行の形にしてください (%s)", key, path)
		}
		exempt[key] = reason
		from[key] = rulesName
	}
	if err := mergeLocal(filepath.Join(root, LocalPath), exempt, from); err != nil {
		return nil, err
	}
	return &Rules{
		ScopeSuffixes:  *f.ScopeSuffixes,
		SkipPrefixes:   *f.SkipPrefixes,
		SkipDirNames:   *f.SkipDirNames,
		TableFileNames: *f.TableFileNames,
		Table:          table,
		Const:          re,
		ZDef:           zdef,
		BorrowWarnOnly: *f.BorrowWarnOnly,
		Remap:          remap,
		LayerZ:         layerZ,
		LeafAbs:        leafAbs,
		Exempt:         exempt,
		ExemptFrom:     from,
	}, nil
}

// mergeLocal はゲームの除外 (LocalPath) を足す。ファイルが無ければ何もしない。
// 形は quadratic.local.json と同じ ({"exempt": {"パス::名前": "理由 1 行"}})。
func mergeLocal(path string, exempt, from map[string]string) error {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("ゲームの除外を読めません: %v", err)
	}
	var local struct {
		Exempt *map[string]string `json:"exempt"`
	}
	if err := json.Unmarshal(data, &local); err != nil {
		return fmt.Errorf("ゲームの除外が JSON として壊れています (%s): %v", path, err)
	}
	if local.Exempt == nil {
		return fmt.Errorf("ゲームの除外に exempt がありません (%s)", path)
	}
	localName := filepath.ToSlash(LocalPath)
	for key, reason := range *local.Exempt {
		if !strings.Contains(key, "::") || strings.TrimSpace(reason) == "" {
			return fmt.Errorf("ゲームの除外 %q は \"パス::名前\" と理由 1 行の形にしてください (%s)", key, path)
		}
		if _, dup := exempt[key]; dup {
			return fmt.Errorf("除外 %q がエンジンの規約とゲームの除外の両方にあります (%s)", key, path)
		}
		exempt[key] = reason
		from[key] = localName
	}
	return nil
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

// IsTable は表のファイルか。名前が tableFileNames にあるか、本文 (コメントを除く) に
// 表の宣言 (tablePattern) があれば表。
// WhyNot: 名前だけで決めないのは、層の表を instance SortingLayer[Layer] として
// ZOrder.flix 以外 (Main.flix や Layer.flix) に書くゲームもあるため。
func (r *Rules) IsTable(rel, body string) bool {
	base := filepath.Base(rel)
	for _, name := range r.TableFileNames {
		if base == name {
			return true
		}
	}
	if r.Table == nil || !r.Table.MatchString(body) {
		return false
	}
	for _, line := range strings.Split(body, "\n") {
		if r.Table.MatchString(stripComment(line)) {
			return true
		}
	}
	return false
}

// TablesOf はパッケージの本文 (パス → 本文) のうち、表のファイルを返す。
func (r *Rules) TablesOf(bodies map[string]string) map[string]bool {
	tables := map[string]bool{}
	for p, body := range bodies {
		if r.IsTable(p, body) {
			tables[p] = true
		}
	}
	return tables
}
