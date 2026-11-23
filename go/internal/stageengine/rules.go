package stageengine

// 規約データ (bin/lint-rules/stage-engine.json) の読み込み。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// RulesPath は規約データの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "stage-engine.json")

// Item は運ぶ物 1 つ。
type Item struct {
	Src           string   `json:"src"`
	Dest          string   `json:"dest"`
	DestWindows   string   `json:"destWindows"`
	Exec          bool     `json:"exec"`
	SkipOnWindows bool     `json:"skipOnWindows"`
	Optional      bool     `json:"optional"`
	PruneDirs     []string `json:"pruneDirs"`
	Owner         string   `json:"owner"`
	Why           string   `json:"why"`
}

// OwnedByStudio はその中身を決めているのが Studio のリポか（既定は engine）。
//
// WhyNot: 「src が @ で始まるか」「bundle-zip が引数で渡すか」で決めないのは、
// それが「engine のリポの外に実体があるか」でしかないため。bin/flix は引数で渡すが
// 中身は Studio が決める（同梱 JRE を見るラッパ）ので、self-update で engine の
// devbox ラッパに上書きすると、その Studio ではゲームのビルドが一切通らなくなる。
func (it Item) OwnedByStudio() bool { return it.Owner == "studio" }

// DestOf は行き先（バンドルの中の相対パス）。Windows 用の名前があればそちら。
func (it Item) DestOf(windows bool) string {
	if windows && it.DestWindows != "" {
		return it.DestWindows
	}
	return it.Dest
}

// Rules は組み立てに使う規約。すべて JSON から来る。
type Rules struct {
	Items []Item `json:"items"`
}

// LoadRules は規約データを読む。
// WhyNot: 読めないときに既定値へ倒さないのは、一覧を消しただけで痩せたバンドルが
// 黙って出来上がり、配った先で「規約ファイルを読めません」になるため。
func LoadRules(root string) (*Rules, error) {
	path := filepath.Join(root, RulesPath)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("規約ファイルを読めません: %v", err)
	}
	var r Rules
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("規約ファイルが JSON として壊れています (%s): %v", path, err)
	}
	if len(r.Items) == 0 {
		return nil, fmt.Errorf("規約ファイルに items がありません (%s)", path)
	}
	for i, it := range r.Items {
		if it.Src == "" || it.Dest == "" {
			return nil, fmt.Errorf("items[%d] に src と dest が要ります (%s)", i, path)
		}
		if strings.HasPrefix(it.Src, "@") && !knownSource(it.Src) {
			return nil, fmt.Errorf("items[%d].src の %s は引数で渡せる物ではありません (%s)", i, it.Src, path)
		}
	}
	return &r, nil
}

// 引数で場所を渡す src。
const (
	srcFlixJar     = "@flix-jar"
	srcFlixWrapper = "@flix-wrapper"
	srcFgeGo       = "@fge-go"
	srcMavenSeed   = "@maven-seed"
	srcNatives     = "@natives"
)

func knownSource(src string) bool {
	switch {
	case src == srcFlixJar, src == srcFlixWrapper, src == srcFgeGo, src == srcNatives:
		return true
	case strings.HasPrefix(src, srcMavenSeed+"/"):
		return true
	}
	return false
}
