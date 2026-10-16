package agenteval

// 本命の採点（strict）。
//
// 答えの JSON の "choice"（この依頼で実際に使う物・最大 choiceMax 個）だけに期待の語と減点の語を当てる。
// 関係しそうな道具を "others" にいくつ並べても、読んだファイルに何を書いても点にならない。
//
// WhyNot: 答え全体に当てる今までの採点（loose）をやめるのは、答えは本命のほかに関係しそうな
// 道具を並べるので、1 本の答えでほかのお題の期待の語まで満たし、「本命を選んだか」を見分けられないため
// （0.35.21 では 1 本あたり、ほかのお題の期待の語 37 個のうち平均 6 個が当たっていた）。
// loose も同じ答えで数え続け、前の版（loose の記録）と比べるときに使う。

import (
	"encoding/json"
	"regexp"
	"sort"
	"strings"
)

// choiceMax は "choice" から見る数。これより後ろに並べた物は数えない。
//
// WhyNot: 4 にするのは、期待の語が 3 つあるお題（チケットから台本の行・効果音を拍に合わせる）でも
// 1 つずつ書けて、ほかのお題の物まで並べる余地はほとんど残らない数のため。
const choiceMax = 4

// 答えの頼み方。お題の後ろに必ず付ける。
//
// WhyNot: お題の JSON ごとに変えられるようにしないのは、言い方が違うと前後・ゲーム間で
// 点が比べられなくなるため。0.35.28 で "choice" を足した（それより前の記録は loose だけ）。
const suffix = "。実装はせず、JSON で答えて。" +
	`"choice" にはこの依頼で実際に使う物（API・make の口・lint・スキル・見るファイル）だけを、1 つに 1 つずつ名前を省かずに、使う順に最大 4 つ。` +
	`"others" には関係はあるが今回は使わない物、"read" には判断のために読んだファイル`

// extractChoice は答えの JSON の "choice" を、1 つずつ文字列にして返す（先頭から choiceMax 個）。
// JSON が読めない・"choice" が無い・空のときは ok=false。
//
// WhyNot: コードフェンスや「最初の { から最後の }」で切り出さないのは、前置きの文に { がある・
// JSON が 2 つある・フェンスの中の文字列に ``` がある答えで読めなくなるため。{ の位置ごとに
// JSON の値を 1 つだけ読み、"choice" を持つ最初の物を使う。
func extractChoice(answer string) ([]string, bool) {
	for i := 0; i < len(answer); i++ {
		if answer[i] != '{' {
			continue
		}
		var root map[string]json.RawMessage
		if json.NewDecoder(strings.NewReader(answer[i:])).Decode(&root) != nil {
			continue
		}
		raw, ok := root["choice"]
		if !ok {
			continue
		}
		var items []json.RawMessage
		if json.Unmarshal(raw, &items) != nil {
			items = []json.RawMessage{raw} // 配列でなく 1 つだけ書いた
		}
		var out []string
		for _, it := range items {
			if len(out) >= choiceMax {
				break
			}
			if s := itemText(it); s != "" {
				out = append(out, s)
			}
		}
		return out, len(out) > 0
	}
	return nil, false
}

// nameKeys は、choice の 1 つをオブジェクトで書いたときに道具の名前として読む鍵。
var nameKeys = []string{"name", "tool", "api", "target", "command", "skill", "file", "path", "名前", "道具"}

// itemText は "choice" の 1 つを文字列に。オブジェクトなら名前の鍵の値だけ（無ければ最初の文字列の値）を読む。
//
// WhyNot: オブジェクトの字面ごと当てないのは、"why" の説明文に期待の語が当たったり、
// 中に配列を入れて 4 つの上限を抜けられたりするため。
func itemText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal(raw, &obj) != nil {
		return ""
	}
	for _, k := range nameKeys {
		if v, ok := obj[k]; ok && json.Unmarshal(v, &s) == nil {
			return s
		}
	}
	keys := make([]string, 0, len(obj))
	for k := range obj {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if json.Unmarshal(obj[k], &s) == nil {
			return s
		}
	}
	return ""
}

func anyStrict(results []Result) bool {
	for _, r := range results {
		if r.Strict {
			return true
		}
	}
	return false
}

// noChoiceAtAll は、失敗していない答えのどれにも "choice" が無いか（choice の無い古い記録を strict で付け直した）。
func noChoiceAtAll(results []Result) bool {
	for _, r := range results {
		if r.Err == "" && len(r.Choice) > 0 {
			return false
		}
	}
	return len(results) > 0
}

// headSeparator は choice の 1 つの中で、1 つ目の道具の終わりと見なす所（「+」「→」「、」「,」「;」
// 「 / 」「・」「 と 」「 and 」と括弧の開き）。
var headSeparator = regexp.MustCompile(`\+|＋|→|->|=>|、|,|，|;|；|\s/\s|／|・|\s(と|and)\s|\(|（|\[|「`)

// headOf は choice の 1 つから、1 つ目の道具の名前だけを切り出す。
//
// WhyNot: 期待の語を 1 つ全体に当てないのは、「Timeline.build + withSound + App.withAudio」のように
// 1 つの中に API を詰めると、4 つの上限を抜けて全部当たってしまうため。減点の語は 1 つ全体に当てる
// （詰めた中の古い書き方も見逃さない）。
func headOf(item string) string {
	if loc := headSeparator.FindStringIndex(item); loc != nil {
		return strings.TrimSpace(item[:loc[0]])
	}
	return strings.TrimSpace(item)
}

// scoreChoice は "choice" に期待の語（1 つ目の道具の名前だけ）と減点の語（1 つ全体）を当てる。
func scoreChoice(r *Result, t Task, choice []string) {
	r.Hit, r.Penalty, r.Missed, r.AvoidHits = 0, 0, nil, nil
	heads := make([]string, len(choice))
	for i, c := range choice {
		heads[i] = headOf(c)
	}
	for _, p := range t.Expect {
		if anyMatch(regexp.MustCompile(p.Re), nil, heads, false) {
			r.Hit++
		} else {
			r.Missed = append(r.Missed, label(p))
		}
	}
	for _, p := range t.Avoid {
		var unless *regexp.Regexp
		if p.Unless != "" {
			unless = regexp.MustCompile(p.Unless)
		}
		if anyMatch(regexp.MustCompile(p.Re), unless, choice, true) {
			r.Penalty++
			r.AvoidHits = append(r.AvoidHits, label(p))
		}
	}
}

// anyMatch は choice のどれかに re が当たるか。減点の語（avoid）は打ち消しと unless も見る
// （「ZStack.topLayer（z の大きな数は使わない）」のような 1 つの中の但し書きで減点しない）。
func anyMatch(re, unless *regexp.Regexp, choice []string, avoid bool) bool {
	for _, c := range choice {
		if !re.MatchString(c) {
			continue
		}
		if avoid && (negatedNear(re, c) || (unless != nil && unless.MatchString(c))) {
			continue
		}
		return true
	}
	return false
}

// negatedNear は、choice の 1 つの中で re が当たった所の後ろ・同じ節（「。」「、」「（」まで）が打ち消しか。
// 「ZStack.topLayer（zIndex = 900 は使わない）」は減点しない。
//
// WhyNot: 1 つの中のどこかで探さないのは、本命の名前の後ろの但し書きに「古い」「lint」が
// 1 語あるだけで、選んだ古い書き方の減点まで消えるため。
func negatedNear(re *regexp.Regexp, item string) bool {
	loc := re.FindStringIndex(item)
	if loc == nil {
		return false
	}
	tail := item[loc[1]:]
	if k := strings.IndexAny(tail, "。、（"); k >= 0 {
		tail = tail[:k]
	}
	return negation.MatchString(tail) || negationAfter.MatchString(item[loc[1]:])
}

// crossHits は、text にほかのお題の期待の語がいくつ当たるか（ばらまきの量）。
// 自分の期待の語と同じ正規表現は数えない（本命を選んだだけで増えないように）。
func crossHits(self string, tasks []job, text string) int {
	own := map[string]bool{}
	for _, j := range tasks {
		if j.task.ID == self {
			for _, p := range j.task.Expect {
				own[p.Re] = true
			}
		}
	}
	n := 0
	for _, j := range tasks {
		if j.task.ID == self {
			continue
		}
		for _, p := range j.task.Expect {
			if !own[p.Re] && regexp.MustCompile(p.Re).MatchString(text) {
				n++
			}
		}
	}
	return n
}
