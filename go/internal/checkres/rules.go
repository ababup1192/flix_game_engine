package checkres

// 決まり（bin/lint-rules/checkfmt.json）: near の帯・score の重み・上位の件数・画素の上限・周回の止め時。

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
)

// RulesPath は決まりの置き場（リポジトリのルートからの相対）。
var RulesPath = filepath.Join("bin", "lint-rules", "checkfmt.json")

// NearBand は code ごとの許容の帯。Ratio（割合の下限）か Gap（|gap| の上限・単位は code の unit）のどちらか。
type NearBand struct {
	Ratio *float64 `json:"ratio,omitempty"`
	Gap   *float64 `json:"gap,omitempty"`
	Why   string   `json:"why,omitempty"`
}

// ScoreRules は score の重み。
type ScoreRules struct {
	Gate        float64 `json:"gate"`        // gate の fail 1 件で引く点
	Lint        float64 `json:"lint"`        // lint の fail 1 件
	Advice      float64 `json:"advice"`      // advice の fail 1 件
	NearFactor  float64 `json:"nearFactor"`  // near は fail の何倍を引くか
	RepeatDecay float64 `json:"repeatDecay"` // 同じ code の 2 件目からは前の件のこの倍（同じ外れの数で点が尽きない）
	GateCap     float64 `json:"gateCap"`     // gate の外れがある時の上限
}

// StopRules は周回の止め時（rounds snap のまとめの stop）。
type StopRules struct {
	NoGainRounds   int     `json:"noGainRounds"`   // score がこの周数続けて上がらなければ止める
	SameNextRounds int     `json:"sameNextRounds"` // next が同じ code・同じ場所をこの周数続けて指せば止める
	BudgetShare    float64 `json:"budgetShare"`    // 使ったトークンが予算のこの割合を超えたら止める
}

// Rules は決まり全部。
type Rules struct {
	NearRatio float64             `json:"nearRatio"`
	Near      map[string]NearBand `json:"near"`
	Score     ScoreRules          `json:"score"`
	Top       int                 `json:"top"`
	MaxCells  int                 `json:"maxCells"`
	Stop      StopRules           `json:"stop"`
}

// LoadRules は決まりを読む。読めなければ止める（既定値へ倒すと消しただけで帯が黙って変わる）。
func LoadRules(root string) (*Rules, error) {
	path := filepath.Join(root, RulesPath)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("検査の返し方の決まりを読めない: %v", err)
	}
	var r Rules
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("%s が JSON として壊れている: %v", path, err)
	}
	if r.NearRatio <= 0 || r.NearRatio >= 1 || r.Top < 1 || r.MaxCells < 1 || r.Score.Gate <= 0 || r.Score.GateCap <= 0 ||
		r.Stop.NoGainRounds < 1 || r.Stop.SameNextRounds < 1 || r.Stop.BudgetShare <= 0 {
		return nil, fmt.Errorf("%s に nearRatio（0〜1）・top・maxCells・score.gate・score.gateCap・stop.noGainRounds・stop.sameNextRounds・stop.budgetShare を書く", path)
	}
	// near の code が表にあるかは、px と snd の両方が載った所（go/ の main のテスト）で見る
	return &r, nil
}

// near は外れが許容の帯の中か。
func (r *Rules) near(code string, ratio, gap float64) bool {
	if r == nil {
		return false
	}
	if b, ok := r.Near[code]; ok {
		switch {
		case b.Gap != nil:
			return math.Abs(gap) <= *b.Gap
		case b.Ratio != nil:
			return ratio >= *b.Ratio
		}
	}
	return ratio >= r.NearRatio
}
