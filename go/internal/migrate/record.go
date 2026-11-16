// Package migrate は、ゲームを新しいテンプレートへ移す前と後の記録を突き合わせ、前と同じ動きかを確かめる
// （plans/novel-vocab-n4-design.md の 10 章）。記録の形は docs/migrate-diff.md。
package migrate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
)

const (
	// FlowsDir・SavesDir は記録のフォルダ（baseline と new）の中の置き場。
	FlowsDir = "flows"
	SavesDir = "saves"
	// TapeFile・RestoreFile は 1 つの flow の 1 つの画面の大きさの記録と、古いセーブを読み戻した記録。
	TapeFile    = "tape.json"
	RestoreFile = "restore.json"
	// SingleSize は flow のフォルダの直下に tape.json を置いた（画面の大きさを分けない）時の大きさの名前。
	SingleSize = "-"
)

// Size は画面の大きさ（px）。
type Size struct {
	W float64 `json:"w"`
	H float64 `json:"h"`
}

// Line は tape.json の lines の 1 行（台詞か命令）。
type Line struct {
	Who  *string `json:"who"`
	Text *string `json:"text"`
	Cmd  *string `json:"cmd"`
	Node string  `json:"node"`
}

// Sound は鳴らした音の 1 つ。
type Sound struct {
	T    float64 `json:"t"`
	Name string  `json:"name"`
	Kind string  `json:"kind"`
}

// Rect は画面の幅・高さに対する割合の矩形。
type Rect struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	W float64 `json:"w"`
	H float64 `json:"h"`
}

// Object は画面に出ていた物の 1 区間。
type Object struct {
	ID   string  `json:"id"`
	From float64 `json:"from"`
	To   float64 `json:"to"`
	Rect Rect    `json:"rect"`
}

// Choice は選択肢を選んだ所。
type Choice struct {
	T       float64  `json:"t"`
	Node    string   `json:"node"`
	Options []string `json:"options"`
	Picked  int      `json:"picked"`
}

// Event は events の 1 つ（ノードの中の出来事）。Kind は line・choice・wait。
// Seq は line ならノードに入ってから何番目の台詞か（0 から）、choice と wait ならそれまでに出した台詞の数。
// Probes は line だけが持つ、その台詞を出し終えた時の問いの値の全部（無ければ比べない）。
type Event struct {
	T       float64                    `json:"t"`
	Node    string                     `json:"node"`
	Kind    string                     `json:"kind"`
	Seq     int                        `json:"seq"`
	Who     string                     `json:"who,omitempty"`
	Text    string                     `json:"text,omitempty"`
	Options []string                   `json:"options,omitempty"`
	Picked  *int                       `json:"picked,omitempty"`
	Seconds *float64                   `json:"seconds,omitempty"`
	Probes  map[string]json.RawMessage `json:"probes,omitempty"`
}

// Frame は書き出したコマの 1 枚。Kind は lineDone（台詞を出し終えた所）か mid（時間を取る命令の途中）。
// mid は Cmd（命令の名前）・Step（その台詞の後で何番目の時間を取る命令か）・At（命令の秒に対する割合）を持つ。
// Layer は world（文字の枠・HUD・UI を描かない）か all。画素を比べるのは world だけ。
// Seconds は mid の命令の秒（シナリオに書いた秒）。at は秒に対する割合なので、秒だけが替わると同じ割合のコマが同じ絵になり、
// 画素では差が出ない。組になった mid どうしで秒を比べてその差を拾う。
type Frame struct {
	File       string   `json:"file"`
	T          float64  `json:"t"`
	Node       string   `json:"node"`
	Seq        int      `json:"seq"`
	Kind       string   `json:"kind"`
	Cmd        string   `json:"cmd,omitempty"`
	Step       int      `json:"step,omitempty"`
	At         float64  `json:"at,omitempty"`
	Layer      string   `json:"layer"`
	Backdrop3d bool     `json:"backdrop3d,omitempty"`
	Seconds    *float64 `json:"seconds,omitempty"`
}

// Key は前と後のコマを組にする鍵の土台（同じノードへ入り直すと同じ土台が何度も出るので、組にする時は何回目かを足す）。
// WhyNot: 時刻を鍵に入れない — 版で揺れる。
func (f Frame) Key() string {
	if f.Kind == "mid" {
		return fmt.Sprintf("%s|%s#%d|mid|%d@%g", f.Layer, f.Node, f.Seq, f.Step, f.At)
	}
	return fmt.Sprintf("%s|%s#%d|%s", f.Layer, f.Node, f.Seq, f.Kind)
}

// BusPoint はバスの音量の変わり目。DB が nil なら無音。
type BusPoint struct {
	T  float64
	DB *float64
}

// ProbePoint は問いの値の変わり目。
type ProbePoint struct {
	T     float64
	Value string
}

// Tape は突き合わせに使う tape.json の欄だけを読んだ物。
// WhyNot: tape.Parse で読まない — あちらは頁を作る時の厳しい検査で、古い版の記録や欄を足した途中の記録で止まる。
// 突き合わせは欄が無くても「比べていない」と言って進む。
type Tape struct {
	Dir      string
	FPS      float64
	Duration float64
	Yarn     string
	Lines    map[int]Line
	Timeline []TimelineRow
	Sounds   []Sound
	Objects  []Object
	Probes   map[string][]ProbePoint
	Choices  []Choice
	Screen   *Size
	Events   []Event
	Buses    map[string][]BusPoint
	Frames   []Frame
	RanLines []int
	has      map[string]bool
}

// TimelineRow は timeline の 1 行（Line が nil なら台詞の無い所）。
type TimelineRow struct {
	T    float64
	Line *int
}

// Has はその欄が tape.json にあったか。
func (t *Tape) Has(key string) bool { return t.has[key] }

// LoadTape は dir/tape.json を読む。
func LoadTape(dir string) (*Tape, error) {
	path := filepath.Join(dir, TapeFile)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("%s が JSON のオブジェクトでない: %w", path, err)
	}
	t := &Tape{Dir: dir, has: map[string]bool{}}
	for k := range raw {
		t.has[k] = true
	}
	r := reader{raw: raw, path: path}
	r.get("fps", &t.FPS)
	r.get("duration", &t.Duration)
	r.get("yarn", &t.Yarn)
	var lines map[string]Line
	r.get("lines", &lines)
	t.Lines = map[int]Line{}
	for k, l := range lines {
		n, err := strconv.Atoi(k)
		if err != nil {
			return nil, fmt.Errorf("%s: lines の鍵 %q が行番号でない", path, k)
		}
		t.Lines[n] = l
	}
	var rows [][]json.RawMessage
	r.get("timeline", &rows)
	for i, row := range rows {
		var tr TimelineRow
		if len(row) != 2 || json.Unmarshal(row[0], &tr.T) != nil {
			return nil, fmt.Errorf("%s: timeline[%d] は [秒, 行|null]", path, i)
		}
		var n *int
		if json.Unmarshal(row[1], &n) != nil {
			return nil, fmt.Errorf("%s: timeline[%d] の行は整数か null", path, i)
		}
		tr.Line = n
		t.Timeline = append(t.Timeline, tr)
	}
	r.get("sounds", &t.Sounds)
	r.get("objects", &t.Objects)
	r.get("choices", &t.Choices)
	r.get("screen", &t.Screen)
	r.get("events", &t.Events)
	r.get("frames", &t.Frames)
	r.get("ranLines", &t.RanLines)
	t.Probes = r.probes("probes")
	t.Buses = r.buses("buses")
	if r.err != nil {
		return nil, r.err
	}
	if t.FPS <= 0 {
		t.FPS = 30
	}
	return t, nil
}

// Restore は古いセーブを読み戻した直後の記録（saves/<名前>/restore.json）。
type Restore struct {
	Dir     string
	Save    string                     `json:"save"`
	Refused bool                       `json:"refused"`
	Node    string                     `json:"node"`
	Seq     int                        `json:"seq"`
	Probes  map[string]json.RawMessage `json:"probes"`
	Objects []Object                   `json:"objects"`
	Frames  []Frame                    `json:"frames"`
	Screen  *Size                      `json:"screen"`
}

// LoadRestore は dir/restore.json を読む。
func LoadRestore(dir string) (*Restore, error) {
	path := filepath.Join(dir, RestoreFile)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var r Restore
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("%s を読めない: %w", path, err)
	}
	r.Dir = dir
	return &r, nil
}

// Side は baseline か new の記録の全部。Flows は flow の名前 → 画面の大きさの名前 → 記録。
type Side struct {
	Root     string
	Flows    map[string]map[string]*Tape
	Restores map[string]*Restore
}

// LoadSide は記録のフォルダを読む（flows/<flow>/<大きさ>/tape.json か flows/<flow>/tape.json と saves/<名前>/restore.json）。
func LoadSide(root string) (*Side, error) {
	if info, err := os.Stat(root); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("記録のフォルダ %s が無い", root)
	}
	s := &Side{Root: root, Flows: map[string]map[string]*Tape{}, Restores: map[string]*Restore{}}
	flowDirs, _ := os.ReadDir(filepath.Join(root, FlowsDir))
	for _, fd := range flowDirs {
		if !fd.IsDir() {
			continue
		}
		dir := filepath.Join(root, FlowsDir, fd.Name())
		sizes := map[string]*Tape{}
		if fileExists(filepath.Join(dir, TapeFile)) {
			t, err := LoadTape(dir)
			if err != nil {
				return nil, err
			}
			sizes[SingleSize] = t
		}
		subs, _ := os.ReadDir(dir)
		for _, sd := range subs {
			if !sd.IsDir() || !fileExists(filepath.Join(dir, sd.Name(), TapeFile)) {
				continue
			}
			t, err := LoadTape(filepath.Join(dir, sd.Name()))
			if err != nil {
				return nil, err
			}
			sizes[sd.Name()] = t
		}
		if len(sizes) > 0 {
			s.Flows[fd.Name()] = sizes
		}
	}
	saveDirs, _ := os.ReadDir(filepath.Join(root, SavesDir))
	for _, sd := range saveDirs {
		dir := filepath.Join(root, SavesDir, sd.Name())
		if !sd.IsDir() || !fileExists(filepath.Join(dir, RestoreFile)) {
			continue
		}
		r, err := LoadRestore(dir)
		if err != nil {
			return nil, err
		}
		s.Restores[sd.Name()] = r
	}
	if len(s.Flows) == 0 {
		return nil, fmt.Errorf("%s に flows/<flow>/…/tape.json が 1 つも無い", root)
	}
	return s, nil
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// reader は欄があれば読み、型が違えば最初の誤りだけを持つ。
type reader struct {
	raw  map[string]json.RawMessage
	path string
	err  error
}

func (r *reader) get(key string, into any) {
	v, ok := r.raw[key]
	if !ok || r.err != nil {
		return
	}
	if err := json.Unmarshal(v, into); err != nil {
		r.err = fmt.Errorf("%s: %q の型が違う: %w", r.path, key, err)
	}
}

func (r *reader) probes(key string) map[string][]ProbePoint {
	var m map[string][][]json.RawMessage
	r.get(key, &m)
	out := map[string][]ProbePoint{}
	for name, rows := range m {
		for _, row := range rows {
			var p ProbePoint
			if len(row) != 2 || json.Unmarshal(row[0], &p.T) != nil {
				r.fail("%q.%s の行は [秒, 値]", key, name)
				return out
			}
			p.Value = scalarText(row[1])
			out[name] = append(out[name], p)
		}
	}
	return out
}

func (r *reader) buses(key string) map[string][]BusPoint {
	if _, ok := r.raw[key]; !ok {
		return nil
	}
	var m map[string][][]json.RawMessage
	r.get(key, &m)
	out := map[string][]BusPoint{}
	for name, rows := range m {
		for _, row := range rows {
			var p BusPoint
			if len(row) != 2 || json.Unmarshal(row[0], &p.T) != nil || json.Unmarshal(row[1], &p.DB) != nil {
				r.fail("%q.%s の行は [秒, dB|null]", key, name)
				return out
			}
			out[name] = append(out[name], p)
		}
	}
	return out
}

func (r *reader) fail(format string, a ...any) {
	if r.err == nil {
		r.err = fmt.Errorf("%s: "+format, append([]any{r.path}, a...)...)
	}
}

// scalarText は問いの値を比べる字にする（"3" と 3 は別の値として残す）。
func scalarText(raw json.RawMessage) string {
	var v any
	if json.Unmarshal(raw, &v) != nil {
		return string(raw)
	}
	b, _ := json.Marshal(v)
	return string(b)
}
