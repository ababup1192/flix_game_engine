package snd

// 機種の決まり（音源の縛り）と検査の閾値: bin/lint-rules/snd.json。spec の "style": "gb" で styles から引く。
// ゲームが独自の機種を持つなら "style": "audio/x.sndstyle.json"（同じ形の Doc。作業場の根からの相対）。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// sndStyle は機種 1 つの決まり（省略は見ない）。
type sndStyle struct {
	Label      string         `json:"label"`
	Note       string         `json:"note"`
	Voices     map[string]int `json:"voices"`     // 部品 → 同時に鳴らせる数（書いていない部品は 0）
	Ops        []string       `json:"ops"`        // 書ける op
	Duties     []float64      `json:"duties"`     // パルスの山の割合
	NoiseKinds []string       `json:"noiseKinds"` // 雑音の作り方
	Breaks     []string       `json:"breaks"`     // 破ってよい所（機種の外の手: reverb・delay・sidechain・sub・pan・saw・sine・unison・filter・pitchenv。pan は振り切りより細かい左右）
	name       string
}

// loudness は種類ごとの音量の目安（LUFS）と幅。
type loudness struct {
	Target    float64 `json:"target"`
	Tolerance float64 `json:"tolerance"`
}

// sndRules は snd.json。
type sndRules struct {
	Styles        map[string]*sndStyle `json:"styles"`
	Loudness      map[string]loudness  `json:"loudness"`
	PeakDBFS      float64              `json:"peakDbfs"`      // これを超えるピークは lint
	TruePeakDBTP  float64              `json:"truePeakDbtp"`  // これを超える true peak は lint（normalize の既定の上限）
	HeadSilenceMs float64              `json:"headSilenceMs"` // 鳴り出しの遅れの上限
	TailClick     float64              `json:"tailClick"`     // 終わりのサンプルの大きさの上限（ループしない音）
	DC            float64              `json:"dc"`            // 平均の大きさの上限
	SeamStepRatio float64              `json:"seamStepRatio"` // 継ぎ目の段差 ÷ まわりの隣り合う差の最大
	SeamLevelDB   float64              `json:"seamLevelDb"`   // 継ぎ目の前後 20ms の音量の差
	BarTolerance  int                  `json:"barTolerance"`  // 輪の長さと整数小節の差（サンプル）
	DroneSeconds  float64              `json:"droneSeconds"`  // 打ち直さず高さも変えずに鳴り続ける音の上限（秒。gate）
}

func loadRules(engineRoot string) (*sndRules, error) {
	p := filepath.Join(engineRoot, "bin", "lint-rules", "snd.json")
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, fmt.Errorf("snd の決まり %s が読めない: %w", p, err)
	}
	var r sndRules
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, fmt.Errorf("%s が JSON として壊れている: %w", p, err)
	}
	for n, s := range r.Styles {
		s.name = n
	}
	return &r, nil
}

func (r *sndRules) style(workRoot, name string) (*sndStyle, error) {
	if strings.HasSuffix(name, ".json") {
		data, err := os.ReadFile(filepath.Join(workRoot, name))
		if err != nil {
			return nil, fmt.Errorf("style %s が読めない: %w", name, err)
		}
		var st sndStyle
		if err := json.Unmarshal(data, &st); err != nil {
			return nil, fmt.Errorf("style %s が JSON として壊れている: %w", name, err)
		}
		st.name = name
		return &st, nil
	}
	st, ok := r.Styles[name]
	if !ok {
		var names []string
		for n := range r.Styles {
			names = append(names, n)
		}
		return nil, fmt.Errorf("知らない style %q（%s か .json の Doc）", name, strings.Join(sortedStrings(names), "・"))
	}
	return st, nil
}

// free は縛りの無い機種か（ops も voices も書いていない）。
func (s *sndStyle) free() bool { return len(s.Ops) == 0 && s.Voices == nil }

// checkStyle は機種の外の op・引数・同時に鳴らす数を見る。返すのは（何が・原因の op）の組。
func (s *sndStyle) checkStyle(sp *spec, res *rendered) [][2]string {
	if s.free() {
		return nil
	}
	var out [][2]string
	add := func(where, f string, a ...any) { out = append(out, [2]string{fmt.Sprintf(f, a...), where}) }
	for _, vo := range sp.Voices {
		for _, c := range vo.Ops {
			if len(s.Ops) > 0 && !contains(s.Ops, c.Name) {
				add(c.Where, "%s は %s の外の op（書ける op: %s）", c.Name, s.label(), strings.Join(s.Ops, "・"))
				continue
			}
			switch c.Name {
			case "pulse":
				if len(s.Duties) > 0 && !containsF(s.Duties, c.Args.Num("duty")) {
					add(c.Where, "duty %v は %s の外（%v のどれか）", c.Args.Num("duty"), s.label(), s.Duties)
				}
			case "noise":
				if len(s.NoiseKinds) > 0 && !contains(s.NoiseKinds, c.Args.Str("kind")) {
					add(c.Where, "noise の kind %q は %s の外（%s）", c.Args.Str("kind"), s.label(), strings.Join(s.NoiseKinds, "・"))
				}
			}
		}
	}
	for _, c := range sp.Post {
		if len(s.Ops) > 0 && !contains(s.Ops, c.Name) {
			add(c.Where, "%s は %s の外の op（書ける op: %s）", c.Name, s.label(), strings.Join(s.Ops, "・"))
		}
	}
	for _, b := range res.breaks {
		if !contains(s.Breaks, b) {
			add(breakCause(sp, b), "%s は %s の外の手（破ってよい所: %s）", b, s.label(), orNone(s.Breaks))
		}
	}
	if s.Voices == nil {
		return out
	}
	// 同時に鳴らす数: 声を頭の順に見て、部品ごとに重なった数が機種の数を超えた声を原因にする
	for v, vo := range sp.Voices {
		mine := map[part]int{}
		for _, p := range res.parts[v] {
			mine[p]++
		}
		for p, n := range mine {
			limit := s.Voices[string(p)]
			busy := n
			for u := range sp.Voices {
				if u < v && overlaps(res.spans[u], res.spans[v]) {
					for _, q := range res.parts[u] {
						if q == p {
							busy++
						}
					}
				}
			}
			if busy > limit {
				if limit == 0 {
					add(vo.Ops[0].Where, "%s は %s に無い部品", p, s.label())
				} else {
					add(vo.Ops[0].Where, "%s が同時に %d 本（%s は %d 本まで）", p, busy, s.label(), limit)
				}
			}
		}
	}
	return out
}

// breakCause は機種の外の手を使った op の場所（声の pan・reverb の op・song の op）。
func breakCause(sp *spec, b string) string {
	for _, vo := range sp.Voices {
		if b == "pan" && vo.Pan != 0 && vo.Pan != 1 && vo.Pan != -1 {
			return fmt.Sprintf("voices(%s).pan", vo.ID)
		}
		for _, c := range vo.Ops {
			if registry[c.Name].Break == b || c.Name == "song" {
				return c.Where
			}
		}
	}
	for _, c := range sp.Post {
		if registry[c.Name].Break == b {
			return c.Where
		}
	}
	return ""
}

func orNone(ss []string) string {
	if len(ss) == 0 {
		return "無し"
	}
	return strings.Join(ss, "・")
}

func (s *sndStyle) label() string {
	if s.Label != "" {
		return s.name + "（" + s.Label + "）"
	}
	return s.name
}

func overlaps(a, b [2]int) bool { return a[0] < b[1] && b[0] < a[1] }

func containsF(fs []float64, f float64) bool {
	for _, x := range fs {
		if x == f {
			return true
		}
	}
	return false
}

func sortedStrings(ss []string) []string {
	out := append([]string(nil), ss...)
	sort.Strings(out)
	return out
}
