package agenteval

import (
	"encoding/json"
	"testing"
)

func strictJob() job {
	return job{"engine", Task{ID: "t",
		Expect: []Pattern{{Re: `topLayer`}, {Re: `UiTooltip`}},
		Avoid:  []Pattern{{Re: `zIndex\s*=\s*\d{3}`}}}}
}

func resultLine(answer string) []byte {
	b, _ := json.Marshal(answer)
	return []byte(`{"type":"result","result":` + string(b) + `}` + "\n")
}

// 本命の採点は "choice" だけを見る。others に並べた期待の語は点にならないが、答え全体の点には入る。
func TestStrictScoresOnlyChoice(t *testing.T) {
	answer := "```json\n{\n  \"choice\": [\"ZStack.topLayer で手前へ\"],\n  \"others\": [\n    \"UiTooltip\",\n    \"zIndex = 900\"\n  ]\n}\n```"
	r := score(strictJob(), resultLine(answer), true)
	if r.Hit != 1 || r.Penalty != 0 || r.Points() != 50 {
		t.Errorf("strict: hit %d penalty %d points %d", r.Hit, r.Penalty, r.Points())
	}
	if r.LooseHit != 2 || r.LoosePoints() != 100 { // 答え全体: 2 語当たり。others は使わない物の欄なので減点しない
		t.Errorf("loose: hit %d penalty %d points %d", r.LooseHit, r.LoosePenalty, r.LoosePoints())
	}
}

// choice に古い書き方を選べば減点する。choice は 5 つ目から数えない。
func TestStrictPenaltyAndChoiceLimit(t *testing.T) {
	answer := `{"choice": ["zIndex = 900 で手前へ", "a", "b", "c", "ZStack.topLayer", "UiTooltip"]}`
	r := score(strictJob(), resultLine(answer), true)
	if r.Hit != 0 || r.Penalty != 1 || len(r.Choice) != choiceMax {
		t.Errorf("hit %d penalty %d choice %v", r.Hit, r.Penalty, r.Choice)
	}
}

// choice が無い答えは本命の点が 0 で、外れた理由に出す。
func TestStrictWithoutChoice(t *testing.T) {
	r := score(strictJob(), resultLine("ZStack.topLayer と UiTooltip を使う"), true)
	if r.Points() != 0 || len(r.Missed) == 0 || r.Missed[0] != "choice が読めない" || r.LoosePoints() != 100 {
		t.Errorf("points %d missed %v loose %d", r.Points(), r.Missed, r.LoosePoints())
	}
}

// 採点を替えた版は、前の版（答え全体の記録）と答え全体の点どうしで比べる（継ぎ目で「下がった」が鳴らない）。
func TestRegressionsAcrossScoringUseLoosePoints(t *testing.T) {
	prev := BuildHistory("0.1.0", 1, 0, []Result{{ID: "a", Want: 2, Hit: 2}})
	cur := BuildHistory("0.1.1", 1, 0, []Result{{ID: "a", Want: 2, Hit: 0, Strict: true, LooseHit: 2}})
	cur.Scoring = scoringStrict
	if got := Regressions(prev, cur); len(got) != 0 {
		t.Errorf("継ぎ目で鳴った: %v", got)
	}
	cur2 := BuildHistory("0.1.2", 1, 0, []Result{{ID: "a", Want: 2, Hit: 0, Strict: true, LooseHit: 0}})
	cur2.Scoring = scoringStrict
	if got := Regressions(cur, cur2); len(got) != 0 {
		t.Errorf("本命の点はどちらも 0 なのに鳴った: %v", got)
	}
}

// 前置きの文に { があっても・JSON が 2 つあっても、"choice" を持つ JSON を読む。
// オブジェクトで書いた 1 つは名前の鍵だけを読む（why の説明文には当てない）。
func TestExtractChoiceFindsTheRightJSON(t *testing.T) {
	answer := "前置き {これは JSON ではない}\n```json\n{\"plan\": 1}\n```\n```json\n{\"choice\": [{\"name\": \"ZStack.topLayer\", \"why\": \"UiTooltip は使わない\"}, null, \"make check\"]}\n```"
	got, ok := extractChoice(answer)
	if !ok || len(got) != 2 || got[0] != "ZStack.topLayer" || got[1] != "make check" {
		t.Errorf("got %v ok %v", got, ok)
	}
	if _, ok := extractChoice(`{"choice": null}`); ok {
		t.Error("choice: null を読めたことにした")
	}
}
