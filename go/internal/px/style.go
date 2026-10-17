package px

// 機種の決まり（色数と解像度の縛り）。pxsrc の一番外に "style": "gb4" と書くと、
// bin/lint-rules/px.json の styles から引いて、色の集合を色票に足し（"gb0" などの色キーで描ける）、
// ramp_pick と depth_fade の選ぶ色をその集合に絞り、検査 style（gate）で縛りを見る。
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
	name          string
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
		n := float64(st.ChannelLevels - 1)
		for i := 0; i < 3; i++ {
			v := float64(c[i])
			q := math.Round(math.Round(v/255*n) * 255 / n)
			if math.Abs(q-v) > 1 {
				return false
			}
		}
	}
	return true
}

func init() {
	registerCheck(&checkDef{
		Name: checkStyle, Summary: "機種の決まり（spec の style）: 使える色・1 コマの色数・升目ごとの色数・RGB の段数・大きさ", Level: levelGate,
		Fix: "色はその機種の色キー（gb0 など）か ramp_pick で選び直す。色数が多いなら部品のランプを 1 段減らすか、升目をまたぐ所で色を揃える",
		Run: func(g *pxlib.Grid, c *checkCtx) []violation {
			st := c.Style
			if st == nil {
				return nil
			}
			var out []violation
			bad := func(x, y int, has bool, f string, a ...any) {
				out = append(out, violation{Check: checkStyle, Level: levelGate, X: x, Y: y, HasAt: has, Msg: st.Label + ": " + fmt.Sprintf(f, a...)})
			}
			if st.MaxSize[0] > 0 && (g.W > st.MaxSize[0] || g.H > st.MaxSize[1]) {
				bad(0, 0, false, "%d×%d は大きすぎる（%d×%d まで）", g.W, g.H, st.MaxSize[0], st.MaxSize[1])
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
						bad(x, y, true, "色 %s（%s）はこの機種で出せない", k, c.HexOf[k])
					}
				}
			}
			if st.MaxColors > 0 && len(seen) > st.MaxColors {
				bad(0, 0, false, "%d 色使っている（%d 色まで）", len(seen), st.MaxColors)
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
							bad(tx, ty, true, "%d×%d の升目 (%d,%d) に %d 色（%d 色まで）", tw, th, tx, ty, len(cell), st.MaxTileColors)
						}
					}
				}
			}
			return out
		},
	})
}
