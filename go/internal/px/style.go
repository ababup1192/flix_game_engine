package px

// 機種の決まり（色数と解像度の縛り）。pxsrc の一番外に "style": "gb4" と書くと、
// bin/lint-rules/px.json の styles から引いて、色の集合を色票に足し（"gb0" などの色キーで描ける）、
// depth_fade の選ぶ色をその集合に絞り、検査 style（gate）で縛りを見る。
// ゲームが独自の機種を持つなら "style": "art/x.pxstyle.json"（同じ形の Doc。ゲームのルートからの相対）。
//
// 形をパレットの Doc の差し替えにしなかった理由: 色の集合だけでなく「1 コマの色数・升目ごとの色数・
// RGB の段数」まで縛りたい。パレットの Doc は色の表で、数の決まりを書く場所が無い。

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

// pxStyle は機種 1 つの決まり（0 と省略は見ない）。
type pxStyle struct {
	Label         string            `json:"label"`
	Note          string            `json:"note"`
	Colors        map[string]string `json:"colors"`        // 使える色（色キー → #rrggbb）
	MaxColors     int               `json:"maxColors"`     // 1 コマの色数（透明を除く）
	Tile          [2]int            `json:"tile"`          // 升目の大きさ
	MaxTileColors int               `json:"maxTileColors"` // 升目ごとの色数（透明を除く）
	ChannelLevels int               `json:"channelLevels"` // RGB の 1 チャンネルの段数（32 = 5 bit）
	MaxSize       [2]int            `json:"maxSize"`       // 絵の最大の大きさ
	Palettes      *paletteRule      `json:"palettes"`      // 色を何本のパレットに分けて持つか（無ければ見ない）
	Pixel         [2]int            `json:"pixel"`         // 画素の横:縦（PC-88 の 200 ライン = [1, 2]）。--png の PNG・GIF をこの比で引き伸ばす
	name          string
}

// paletteRule は機種のパレットの縛り: 1 コマの色を count 本 × size 色（透明を除く）に割り付けられるか。
// 割り付ける単位は tile があれば升目ごとの色の集合（BG）、無ければ部品ごとの色の集合（スプライト。1 部品 = 1 本）。
type paletteRule struct {
	Count int    `json:"count"`
	Size  int    `json:"size"`
	Tile  [2]int `json:"tile"`
}

// loadStyle は spec の style を引く。名前なら px.json の styles、.json で終われば workRoot からの Doc。
func loadStyle(workRoot, engineRoot, name string) (*pxStyle, error) {
	if name == "" {
		return nil, nil
	}
	if strings.HasSuffix(name, ".json") {
		data, err := os.ReadFile(filepath.Join(workRoot, name))
		if err != nil {
			return nil, fmt.Errorf("style %s が読めない: %w", name, err)
		}
		var st pxStyle
		if err := json.Unmarshal(data, &st); err != nil {
			return nil, fmt.Errorf("style %s が JSON として壊れている: %w", name, err)
		}
		st.name = name
		return &st, nil
	}
	data, err := os.ReadFile(filepath.Join(engineRoot, "bin", "lint-rules", "px.json"))
	if err != nil {
		return nil, fmt.Errorf("機種の決まり（bin/lint-rules/px.json）が読めない: %w", err)
	}
	var r pxRules
	if err := json.Unmarshal(data, &r); err != nil {
		return nil, err
	}
	st, ok := r.Styles[name]
	if !ok {
		names := make([]string, 0, len(r.Styles))
		for k := range r.Styles {
			names = append(names, k)
		}
		sort.Strings(names)
		return nil, fmt.Errorf("知らない style %q（%s か *.pxstyle.json）", name, strings.Join(names, "・"))
	}
	st.name = name
	return st, nil
}

// pixelAspect は --png で引き伸ばす横と縦の倍率（style が無いか pixel を書いていなければ 1:1）。
func (st *pxStyle) pixelAspect() (int, int) {
	if st == nil || st.Pixel[0] < 1 || st.Pixel[1] < 1 {
		return 1, 1
	}
	return st.Pixel[0], st.Pixel[1]
}

// allowsHex は色がこの機種で出せるか。
func (st *pxStyle) allowsHex(hex string) bool {
	hex = strings.ToLower(hex)
	if len(st.Colors) > 0 {
		found := false
		for _, h := range st.Colors {
			if strings.ToLower(h) == hex {
				found = true
			}
		}
		if !found {
			return false
		}
	}
	if st.ChannelLevels > 1 {
		c, ok := pxlib.RGBAOfValue(hex)
		if !ok {
			return false
		}
		for i := 0; i < 3; i++ {
			if !channelOK(c[i], st.ChannelLevels) {
				return false
			}
		}
	}
	return true
}

// channelOK は 8 bit の値 v が、levels 段の 1 チャンネルを 8 bit に広げた値か（ずれは 0 だけ許す）。
// 広げ方は機材と道具でまちまちなので、よく使われる 3 つをどれも通す:
//   - 左へずらすだけ（SNES の v<<3・PC-98 の v<<4。最大は #f8・#f0）
//   - 上の bit を下へ繰り返す（v<<3 | v>>2。最大は #ff）
//   - 等分に丸める（round(k·255/(levels−1))。段数が 2 の冪でない時はこれだけ）
func channelOK(v uint8, levels int) bool {
	bits := 0
	for 1<<bits < levels {
		bits++
	}
	pow2 := 1<<bits == levels && bits <= 8
	for k := 0; k < levels; k++ {
		if int(v) == (k*255+(levels-1)/2)/(levels-1) {
			return true
		}
		if pow2 {
			shifted := k << (8 - bits)
			if int(v) == shifted {
				return true
			}
			rep := shifted
			for sh := bits; sh < 8; sh += bits {
				rep |= shifted >> sh
			}
			if int(v) == rep {
				return true
			}
		}
	}
	return false
}

func init() {
	registerCheck(&checkDef{
		Name: checkStyle, Summary: "機種の決まり（spec の style）: 使える色・1 コマの色数・升目ごとの色数・RGB の段数・大きさ", Level: levelGate,
		Fix: "色はその機種の色キー（gb0 など）で選び直す。色数が多いなら部品のランプを 1 段減らすか、升目をまたぐ所で色を揃える",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			st := c.Style
			if st == nil {
				return nil
			}
			var out []violation
			bad := func(rule string, got float64, want checkres.Want, at *pxlib.Pt, f string, a ...any) {
				v := newViolation(checkStyle, levelGate, got, want, st.Label+": "+fmt.Sprintf(f, a...))
				v.Rule = rule
				if at != nil {
					v = v.at(*at)
				}
				out = append(out, v)
			}
			if st.MaxSize[0] > 0 && (g.W > st.MaxSize[0] || g.H > st.MaxSize[1]) {
				// 長い方の辺の超え（上限に対する割合で比べる）
				over := math.Max(float64(g.W)/float64(st.MaxSize[0]), float64(g.H)/float64(st.MaxSize[1]))
				bad("size", over, checkres.WantAtMost(1), nil, "%d×%d は大きすぎる（%d×%d まで）", g.W, g.H, st.MaxSize[0], st.MaxSize[1])
			}
			seen := map[pxlib.Key]bool{}
			for y := 0; y < g.H; y++ {
				for x := 0; x < g.W; x++ {
					k := g.At(x, y)
					if k == pxlib.Clear || seen[k] {
						continue
					}
					seen[k] = true
					if !st.allowsHex(c.HexOf[k]) {
						bad("color", 1, checkres.WantAtMost(0), &pxlib.Pt{X: x, Y: y}, "色 %s（%s）はこの機種で出せない", k, c.HexOf[k])
					}
				}
			}
			if st.MaxColors > 0 && len(seen) > st.MaxColors {
				bad("colors", float64(len(seen)), checkres.WantAtMost(float64(st.MaxColors)), nil, "%d 色使っている（%d 色まで）", len(seen), st.MaxColors)
			}
			if tw, th := st.Tile[0], st.Tile[1]; tw > 0 && th > 0 && st.MaxTileColors > 0 {
				for ty := 0; ty < g.H; ty += th {
					for tx := 0; tx < g.W; tx += tw {
						cell := map[pxlib.Key]bool{}
						for y := ty; y < min(ty+th, g.H); y++ {
							for x := tx; x < min(tx+tw, g.W); x++ {
								if k := g.At(x, y); k != pxlib.Clear {
									cell[k] = true
								}
							}
						}
						if len(cell) > st.MaxTileColors {
							bad("tile-colors", float64(len(cell)), checkres.WantAtMost(float64(st.MaxTileColors)), &pxlib.Pt{X: tx, Y: ty},
								"%d×%d の升目 (%d,%d) に %d 色（%d 色まで）", tw, th, tx, ty, len(cell), st.MaxTileColors)
						}
					}
				}
			}
			if pr := st.Palettes; pr != nil && pr.Count > 0 && pr.Size > 0 {
				out = append(out, paletteViolations(g, st.Label, pr)...)
			}
			return out
		},
	})
}

// colorSet は割り付けの単位 1 つ（升目か部品）の色の集合。
type colorSet struct {
	where string
	at    pxlib.Pt
	keys  []pxlib.Key // 並べ替え済み
}

// paletteViolations は 1 コマの色を pr.Count 本 × pr.Size 色に割り付ける（色の多い単位から順に、入る一番前の本へ入れる。
// first-fit decreasing で決定的）。入らなければ、下限（一番色の多い単位・色の総数 ÷ size）で入らないと言い切れる時は gate、
// 言い切れない時（貪欲法の取りこぼしかもしれない）は advice。
func paletteViolations(g *pxlib.Grid, label string, pr *paletteRule) []violation {
	units := map[string]map[pxlib.Key]bool{}
	firstAt := map[string]pxlib.Pt{}
	for y := 0; y < g.H; y++ {
		for x := 0; x < g.W; x++ {
			k := g.At(x, y)
			if k == pxlib.Clear {
				continue
			}
			var u string
			if pr.Tile[0] > 0 && pr.Tile[1] > 0 {
				u = fmt.Sprintf("升目 (%d,%d)", x/pr.Tile[0]*pr.Tile[0], y/pr.Tile[1]*pr.Tile[1])
			} else {
				u = "部品 " + g.SrcAt(x, y).Part
			}
			if units[u] == nil {
				units[u] = map[pxlib.Key]bool{}
				firstAt[u] = pxlib.Pt{X: x, Y: y}
			}
			units[u][k] = true
		}
	}
	var sets []colorSet
	all := map[pxlib.Key]bool{}
	for u, ks := range units {
		cs := colorSet{where: u, at: firstAt[u]}
		for k := range ks {
			cs.keys = append(cs.keys, k)
			all[k] = true
		}
		sort.Slice(cs.keys, func(i, j int) bool { return cs.keys[i] < cs.keys[j] })
		sets = append(sets, cs)
	}
	sort.Slice(sets, func(i, j int) bool {
		if len(sets[i].keys) != len(sets[j].keys) {
			return len(sets[i].keys) > len(sets[j].keys)
		}
		return sets[i].where < sets[j].where
	})
	var pals []map[pxlib.Key]bool
	var bad *colorSet
	for i := range sets {
		cs := &sets[i]
		placed := false
		for _, p := range pals {
			n := len(p)
			for _, k := range cs.keys {
				if !p[k] {
					n++
				}
			}
			if n <= pr.Size {
				for _, k := range cs.keys {
					p[k] = true
				}
				placed = true
				break
			}
		}
		if !placed && len(pals) < pr.Count && len(cs.keys) <= pr.Size {
			p := map[pxlib.Key]bool{}
			for _, k := range cs.keys {
				p[k] = true
			}
			pals = append(pals, p)
			placed = true
		}
		if !placed && bad == nil {
			bad = cs
		}
	}
	if bad == nil {
		return nil
	}
	biggest := len(sets[0].keys)
	need := (len(all) + pr.Size - 1) / pr.Size
	level, sure := levelAdvice, "割り付け方を変えれば入るかもしれない（下限は収まっている）"
	if biggest > pr.Size || need > pr.Count {
		level, sure = levelGate, fmt.Sprintf("一番色の多い単位 %d 色・色の総数 %d 色 → %d 本は要る", biggest, len(all), need)
	}
	// 要るパレットの本数（下限）と使える本数
	v := newViolation(checkStyle, level, float64(max(need, pr.Count+1)), checkres.WantAtMost(float64(pr.Count)),
		fmt.Sprintf("%s: パレット %d 本 × %d 色に割り付けられない（%s の %d 色が入る本が無い。%s）", label, pr.Count, pr.Size, bad.where, len(bad.keys), sure)).at(bad.at)
	v.Rule = "palette"
	return []violation{v}
}
