package tape

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// fieldOrder は頁の TAPE の欄の並び（モックの並びに、足した欄を後ろへ）。
var fieldOrder = []string{
	"game", "title", "flow", "commit", "fps", "duration", "yarn", "node", "playUrl", "stripPerSec",
	"scenes", "timeline", "lines", "speaker", "sounds", "objects", "branches", "probes",
	"speakers", "probeNames", "msg", "choices", "video", "videoBytes", "strip",
}

// required はゲームの tape.json が持つ欄と、無かった時に言う出どころ。
var required = []struct{ key, from string }{
	{"game", "ゲームのフォルダ名"},
	{"title", "TapeOut に渡す題名"},
	{"flow", "make tape の FLOW"},
	{"fps", "Outcome の fps"},
	{"duration", "コマの数 ÷ fps"},
	{"yarn", "台本のファイル名"},
	{"node", "台本のノード名"},
	{"scenes", "flow の mark"},
	{"timeline", "probe talkCursor の変わり目"},
	{"lines", "台本の行（Yarn.Program）"},
	{"speaker", "話し手の表示名 → id"},
	{"speakers", "theme の speakers（話し手の色）"},
	{"sounds", "鳴らした音"},
	{"objects", "画面に出ている物（無ければ []）"},
	{"probes", "選んだ probe"},
	{"probeNames", "probe の表示名"},
	{"msg", "メッセージウィンドウの寸法"},
	{"branches", "分岐（今は []）"},
}

// optional は無くてもよい欄。choices は選択肢を選ばない flow や前の版のテンプレートでは無い。commit 以下は Build が上書きする。
var optional = map[string]bool{"playUrl": true, "choices": true, "commit": true, "video": true, "stripPerSec": true, "strip": true}

// Tape は検査を通った tape.json。頁へは raw をそのまま渡し、型は検査と分岐の組み立てのためだけに読む。
type Tape struct {
	Title    string
	Duration float64
	Game     string
	Yarn     string
	Node     string
	Choices  []Choice
	raw      map[string]json.RawMessage
}

// Choice は tape.json の choices の 1 つ（選択肢を選んだ所）。T = 選択肢が出た秒、Line = 最初の選択肢の行、Picked = 選んだ番号、
// Question = 選択肢を出していた時の台詞（前の版のテンプレートでは無い）。
type Choice struct {
	T        float64  `json:"t"`
	Line     int      `json:"line"`
	Node     string   `json:"node"`
	Options  []string `json:"options"`
	Picked   int      `json:"picked"`
	Question string   `json:"question,omitempty"`
}

type scene struct {
	ID   *string  `json:"id"`
	Name *string  `json:"name"`
	T    *float64 `json:"t"`
}

type line struct {
	Who  *string `json:"who"`
	Text *string `json:"text"`
	Cmd  *string `json:"cmd"`
	Node *string `json:"node"`
}

type speakerColor struct {
	ID    *string `json:"id"`
	Name  *string `json:"name"`
	Color *string `json:"color"`
	Ink   *string `json:"ink"`
}

type sound struct {
	T     *float64 `json:"t"`
	Name  *string  `json:"name"`
	Kind  *string  `json:"kind"`
	Label *string  `json:"label"`
	Line  *int     `json:"line"`
}

type rect struct {
	X *float64 `json:"x"`
	Y *float64 `json:"y"`
	W *float64 `json:"w"`
	H *float64 `json:"h"`
}

type object struct {
	ID   *string  `json:"id"`
	Name *string  `json:"name"`
	From *float64 `json:"from"`
	To   *float64 `json:"to"`
	Rect *rect    `json:"rect"`
}

var msgKeys = []string{"x0", "x1", "cy", "lh", "padTop", "padBot", "font", "cps"}

// Parse は tape.json を読み、欠けた欄・型の違い・頁が落ちる食い違いを、どの欄かを言って止める。
func Parse(data []byte) (*Tape, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("%s が JSON のオブジェクトでない: %w", TapeFile, err)
	}
	var missing []string
	for _, r := range required {
		if _, ok := raw[r.key]; !ok {
			missing = append(missing, fmt.Sprintf("%q（%s）", r.key, r.from))
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("%s に欄が無い: %s", TapeFile, strings.Join(missing, "・"))
	}
	var unknown []string
	for k := range raw {
		if !optional[k] && !isRequired(k) {
			unknown = append(unknown, strconv.Quote(k))
		}
	}
	if len(unknown) > 0 {
		sort.Strings(unknown)
		return nil, fmt.Errorf("%s に知らない欄: %s（欄の名前は plans/tape/plan.md の「TAPE の欄」）", TapeFile, strings.Join(unknown, "・"))
	}
	c := &checker{raw: raw}
	t := &Tape{raw: raw}
	c.str("game", &t.Game)
	c.str("title", &t.Title)
	c.str("flow", nil)
	c.str("yarn", &t.Yarn)
	c.str("node", &t.Node)
	if _, ok := raw["playUrl"]; ok {
		c.str("playUrl", nil)
	}
	var fps float64
	c.num("fps", &fps)
	c.num("duration", &t.Duration)
	if c.err == nil && (fps <= 0 || t.Duration <= 0) {
		c.fail("\"fps\" と \"duration\" は 0 より大きい数（fps=%v duration=%v）", fps, t.Duration)
	}
	c.checkScenes()
	lines := c.checkLines()
	speakers := c.checkSpeakers()
	c.checkTimeline(lines)
	c.checkWho(lines, speakers)
	c.checkSpeakerMap()
	c.checkSounds()
	c.checkObjects()
	c.checkProbes()
	c.checkMsg()
	if _, ok := raw["choices"]; ok {
		t.Choices = c.checkChoices(lines)
	}
	var branches []json.RawMessage
	c.decode("branches", &branches, "配列")
	if c.err != nil {
		return nil, c.err
	}
	return t, nil
}

func isRequired(k string) bool {
	for _, r := range required {
		if r.key == k {
			return true
		}
	}
	return false
}

// checker は最初の誤りだけを持つ（後の検査は前の欄が読めた前提なので、続けると誤りが連鎖する）。
type checker struct {
	raw map[string]json.RawMessage
	err error
}

func (c *checker) fail(format string, a ...any) {
	if c.err == nil {
		c.err = fmt.Errorf("%s: "+format, append([]any{TapeFile}, a...)...)
	}
}

func (c *checker) decode(key string, into any, kind string) bool {
	if c.err != nil {
		return false
	}
	if err := strictUnmarshal(c.raw[key], into); err != nil {
		c.fail("%q は%s（%v）", key, kind, err)
		return false
	}
	return true
}

func strictUnmarshal(data []byte, into any) error {
	if bytes.Equal(bytes.TrimSpace(data), []byte("null")) {
		return fmt.Errorf("null")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	return d.Decode(into)
}

func (c *checker) str(key string, into *string) {
	var s string
	if c.decode(key, &s, "文字") && into != nil {
		*into = s
	}
}

func (c *checker) num(key string, into *float64) {
	var f float64
	if c.decode(key, &f, "数") && into != nil {
		*into = f
	}
}

func (c *checker) checkScenes() {
	var scenes []scene
	if !c.decode("scenes", &scenes, " {id, name, t} の配列") {
		return
	}
	if len(scenes) == 0 {
		c.fail("\"scenes\" が空（flow に mark が 1 つも無い。0 フレーム目に mark を打つ）")
		return
	}
	seen := map[string]bool{}
	for i, s := range scenes {
		if s.ID == nil || s.Name == nil || s.T == nil {
			c.fail("\"scenes\"[%d] に id・name・t のどれかが無い", i)
			return
		}
		if seen[*s.ID] {
			c.fail("\"scenes\" の id %q が 2 回ある（同じ名前の mark はテープの flow では使えない）", *s.ID)
			return
		}
		seen[*s.ID] = true
	}
}

func (c *checker) checkLines() map[int]line {
	var byKey map[string]line
	if !c.decode("lines", &byKey, " {行: {who, text} か {cmd}} のオブジェクト") {
		return nil
	}
	out := map[int]line{}
	for k, l := range byKey {
		n, err := strconv.Atoi(k)
		if err != nil {
			c.fail("\"lines\" の鍵 %q が行番号（整数）でない", k)
			return nil
		}
		isCmd := l.Cmd != nil && l.Who == nil && l.Text == nil
		isTalk := l.Cmd == nil && l.Who != nil && l.Text != nil
		if !isCmd && !isTalk {
			c.fail("\"lines\".%s は {who, text} か {cmd} のどちらか", k)
			return nil
		}
		out[n] = l
	}
	return out
}

func (c *checker) checkSpeakers() map[string]bool {
	var list []speakerColor
	if !c.decode("speakers", &list, " {id, name, color, ink} の配列") {
		return nil
	}
	names := map[string]bool{}
	for i, s := range list {
		if s.ID == nil || s.Name == nil || s.Color == nil || s.Ink == nil {
			c.fail("\"speakers\"[%d] に id・name・color・ink のどれかが無い", i)
			return nil
		}
		names[*s.Name] = true
	}
	return names
}

func (c *checker) checkTimeline(lines map[int]line) {
	var rows [][]json.RawMessage
	if !c.decode("timeline", &rows, " [[秒, 行|null]] の配列") {
		return
	}
	if len(rows) == 0 {
		c.fail("\"timeline\" が空（0 秒の行 [0, null] から始める）")
		return
	}
	for i, r := range rows {
		var t float64
		if len(r) != 2 || json.Unmarshal(r[0], &t) != nil {
			c.fail("\"timeline\"[%d] は [秒, 行|null]", i)
			return
		}
		if bytes.Equal(r[1], []byte("null")) {
			continue
		}
		var n int
		if json.Unmarshal(r[1], &n) != nil {
			c.fail("\"timeline\"[%d] の行は整数か null", i)
			return
		}
		if _, ok := lines[n]; !ok {
			c.fail("\"timeline\"[%d] の行 %d が \"lines\" に無い", i, n)
			return
		}
	}
}

func (c *checker) checkChoices(lines map[int]line) []Choice {
	var list []Choice
	if !c.decode("choices", &list, " {t, line, node, options, picked} の配列") {
		return nil
	}
	for i, ch := range list {
		if len(ch.Options) < 2 {
			c.fail("\"choices\"[%d] の options が 2 つより少ない（選べる道が 1 つの所は載せない）", i)
			return nil
		}
		if ch.Picked < 0 || ch.Picked >= len(ch.Options) {
			c.fail("\"choices\"[%d] の picked %d が options の外（0〜%d）", i, ch.Picked, len(ch.Options)-1)
			return nil
		}
		if _, ok := lines[ch.Line]; !ok {
			c.fail("\"choices\"[%d] の行 %d が \"lines\" に無い", i, ch.Line)
			return nil
		}
	}
	return list
}

func (c *checker) checkWho(lines map[int]line, speakers map[string]bool) {
	if c.err != nil {
		return
	}
	keys := make([]int, 0, len(lines))
	for n := range lines {
		keys = append(keys, n)
	}
	sort.Ints(keys)
	for _, n := range keys {
		if w := lines[n].Who; w != nil && !speakers[*w] {
			c.fail("\"lines\".%d の話し手 %q が \"speakers\" に無い（色が決まらない）", n, *w)
			return
		}
	}
}

func (c *checker) checkSpeakerMap() {
	var m map[string]string
	c.decode("speaker", &m, " {表示名: id} のオブジェクト")
}

func (c *checker) checkSounds() {
	var list []sound
	if !c.decode("sounds", &list, " {t, name, kind, label, line} の配列") {
		return
	}
	for i, s := range list {
		if s.T == nil || s.Name == nil || s.Kind == nil || s.Label == nil {
			c.fail("\"sounds\"[%d] に t・name・kind・label のどれかが無い", i)
			return
		}
	}
}

func (c *checker) checkObjects() {
	var list []object
	if !c.decode("objects", &list, " {id, name, from, to, rect} の配列") {
		return
	}
	for i, o := range list {
		if o.ID == nil || o.Name == nil || o.From == nil || o.To == nil || o.Rect == nil ||
			o.Rect.X == nil || o.Rect.Y == nil || o.Rect.W == nil || o.Rect.H == nil {
			c.fail("\"objects\"[%d] に id・name・from・to・rect{x,y,w,h} のどれかが無い", i)
			return
		}
	}
}

func (c *checker) checkProbes() {
	var probes map[string][][]json.RawMessage
	if !c.decode("probes", &probes, " {名前: [[秒, 値]]} のオブジェクト") {
		return
	}
	for name, rows := range probes {
		if len(rows) == 0 {
			c.fail("\"probes\".%s が空", name)
			return
		}
		for _, r := range rows {
			if len(r) != 2 {
				c.fail("\"probes\".%s の行は [秒, 値]", name)
				return
			}
		}
	}
	var names map[string]string
	c.decode("probeNames", &names, " {名前: 表示名} のオブジェクト")
}

func (c *checker) checkMsg() {
	var m map[string]json.RawMessage
	if !c.decode("msg", &m, " {x0, x1, cy, lh, padTop, padBot, font, cps} のオブジェクト") {
		return
	}
	for _, k := range msgKeys {
		v, ok := m[k]
		var f float64
		if !ok || json.Unmarshal(v, &f) != nil {
			c.fail("\"msg\" に数の %q が無い（x0・x1 は画面の幅、cy・lh・padTop・padBot・font は画面の高さに対する割合、cps は 1 秒の文字数）", k)
			return
		}
	}
	raw, ok := m["when"]
	if !ok {
		return
	}
	var when map[string]string
	if json.Unmarshal(raw, &when) != nil {
		c.fail("\"msg\" の \"when\" は {問いの名前: 値の文字} のオブジェクト")
		return
	}
	var probes map[string]json.RawMessage
	_ = json.Unmarshal(c.raw["probes"], &probes)
	for name := range when {
		if _, ok := probes[name]; !ok {
			c.fail("\"msg\" の \"when\" の問い %q が \"probes\" に無い", name)
			return
		}
	}
}
