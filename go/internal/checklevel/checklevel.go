package checklevel

// checklevel — 道具の検査の重さ 3 段（px と snd が共有する）。
// gate（外れたら書き出さず終了コード 1）・lint（報告だけ）・advice（報告だけ。技法の助言）。

import (
	"encoding/json"
	"fmt"
)

// Level は検査の重さ。0 は不正な値（書き忘れを通さない）。
type Level int

const (
	_      Level = iota
	Gate         // 外れたら止める
	Lint         // 報告だけ
	Advice       // 報告だけ（技法の助言）
)

var names = map[Level]string{Gate: "gate", Lint: "lint", Advice: "advice"}

// Valid は 3 段のどれかか。
func (l Level) Valid() bool { _, ok := names[l]; return ok }

func (l Level) String() string {
	if n, ok := names[l]; ok {
		return n
	}
	return fmt.Sprintf("level(%d)", int(l))
}

// MarshalJSON は名前で書く。不正な値は書かない。
func (l Level) MarshalJSON() ([]byte, error) {
	n, ok := names[l]
	if !ok {
		return nil, fmt.Errorf("不正な level %d", int(l))
	}
	return json.Marshal(n)
}

// UnmarshalJSON は名前から戻す。読めない名前は誤り。
func (l *Level) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return err
	}
	for v, n := range names {
		if n == s {
			*l = v
			return nil
		}
	}
	return fmt.Errorf("知らない level %q（gate・lint・advice）", s)
}
