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

// Skip は当てなかった検査 1 つ（理由は必須。checkset-design §3。px と snd が共有する）。
type Skip struct {
	Code string `json:"code"`
	Why  string `json:"why"`
	By   string `json:"by"` // 出どころ（kind:icon・op 名・--no-check など）
}

// Applied は 1 つの絵（sprite）か音に当てた検査の組。宣言と検査の組が前の周と同じなら ID だけ出す（Full は nil）。
type Applied struct {
	ID      string       `json:"id"`
	Changed bool         `json:"changed"`
	Full    *AppliedFull `json:"full,omitempty"` // 最初の周・組が変わった周・--explain だけ
}

// AppliedFull は当てた検査の組の全文（checkset-design §7）。kind は宣言（declared）か推した物（inferred）。
// Fidelity・FidelityBy は low-bit ↔ hi-bit の軸（§9）の値と出どころ（門・機種・不明）。
type AppliedFull struct {
	Kind       string   `json:"kind,omitempty"`
	KindBy     string   `json:"kindBy,omitempty"`
	Look       string   `json:"look,omitempty"` // 門の画風（報告だけ）
	Fidelity   *float64 `json:"fidelity,omitempty"`
	FidelityBy string   `json:"fidelityBy,omitempty"` // 出どころ（門・機種・不明）
	Style      string   `json:"style,omitempty"`
	Materials  []string `json:"materials,omitempty"`
	Checks     []string `json:"checks"`
	Skipped    []Skip   `json:"skipped,omitempty"`
}
