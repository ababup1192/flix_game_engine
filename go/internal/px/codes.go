package px

// px の code の表（checkres に載せる）。code は px.<検査>[.<規則>][.<測り方>]（violation.code）。
// 表に無い code の違反は result で panic する（テストが止める）。docs/check-codes.md はこの表から書き出す。

import (
	"github.com/ababup1192/flix_game_engine/go/internal/checkres"
)

var pxCodes = []checkres.Code{
	{Name: "px.sprite.orphan", Level: levelGate, Levels: []level{levelLint}, Metric: "orphan_px", Unit: "px", Op: checkres.AtMost, Rule: "sprite.json", Summary: "周り 8 方向が透明の 1 画素（タイルは 3×3 に並べて見る）"},
	{Name: "px.sprite.connect", Level: levelLint, Metric: "blobs", Unit: "count", Op: checkres.AtMost, Rule: "sprite.json minConnectCells", Summary: "絵が離れた塊に分かれている（塊の数）"},
	{Name: "px.sprite.jaggy", Level: levelLint, Metric: "jaggy_spots", Unit: "px", Op: checkres.AtMost, Rule: "sprite.json jaggyMinCount", Summary: "輪郭のがたつき（段の長さが乱れた所の数）"},
	{Name: "px.sprite.banding", Level: levelLint, Levels: []level{levelAdvice}, Metric: "ring_px", Unit: "px", Op: checkres.AtMost, Rule: "px.json bandingRingMin", Summary: "輪郭の内側 1px の縁取りだけに使う色（輪をほぼ一周する時だけ lint）"},
	{Name: "px.sprite.corner", Level: levelAdvice, Metric: "double_corner_px", Unit: "px", Op: checkres.AtMost, Summary: "1px の線の L 字の角に 2 重に乗った画素"},
	{Name: "px.sprite.silhouette.sparse", Level: levelLint, Metric: "bbox_fill", Unit: "ratio", Op: checkres.AtLeast, Rule: "sprite.json silhouetteMinOcc", Summary: "シルエットが外接箱に対してスカスカ"},
	{Name: "px.sprite.silhouette.thin", Level: levelLint, Metric: "short_side", Unit: "px", Op: checkres.AtLeast, Summary: "シルエットが細長すぎる（短い辺 2px 以下で長い辺 8px 以上）"},
	{Name: "px.sprite.palette.delta-e", Level: levelLint, Metric: "delta_e", Unit: "ΔE", Op: checkres.AtLeast, Rule: "sprite.json deltaEMin", Summary: "legend の 2 色が近すぎる"},
	{Name: "px.sprite.palette.colors", Level: levelLint, Metric: "colors", Unit: "count", Op: checkres.AtMost, Rule: "sprite.json maxColors・maxColorsBig", Summary: "1 スプライトの色数が目安を超える"},
	{Name: "px.sprite.structure", Level: levelGate, Metric: "broken", Unit: "count", Op: checkres.AtMost, Summary: "sprite.json の形の誤り（rows・legend・anchor・空のコマ・同じコマ）"},
	{Name: "px.flat-run.repeat", Level: levelAdvice, Metric: "same_runs", Unit: "count", Op: checkres.AtMost, Rule: "px.json flatRunRepeat", Summary: "同じ長さの段が続く（直線に読まれる）"},
	{Name: "px.flat-run.straight", Level: levelAdvice, Metric: "run_px", Unit: "px", Op: checkres.AtMost, Rule: "px.json flatRunStraight・flatRunPer", Summary: "曲線の中の長すぎる直線"},
	{Name: "px.flat-run.poly", Level: levelAdvice, Metric: "run_kinds", Unit: "count", Op: checkres.AtMost, Summary: "poly の辺の段の長さが 3 種類以上に散る"},
	{Name: "px.run-monotone", Level: levelLint, Metric: "turns", Unit: "count", Op: checkres.AtMost, Summary: "曲線の段の長さが増減する（3-2-1 は良い・1-2-1-2 は不可）"},
	{Name: "px.ground-contrast", Level: levelLint, Metric: "edge_ground_dL", Unit: "L", Op: checkres.AtLeast, Rule: "px.json groundContrastMin", Summary: "外周と地の色の明るさ（Oklab の L）の差の平均"},
	{Name: "px.pillow", Level: levelAdvice, Metric: "lit_dark_edge_dL", Unit: "L", Op: checkres.AtLeast, Rule: "px.json pillowSideGap", Summary: "縁を一様に暗くした陰（光の側と影の側の縁の明るさの差）"},
	{Name: "px.light-dir", Level: levelAdvice, Metric: "bright_toward_light", Unit: "dot", Op: checkres.AtLeast, Summary: "明るい段の重心の向きと光の向きの内積（負なら光と反対）"},
	{Name: "px.black-outline", Level: levelAdvice, Metric: "edge_colors", Unit: "count", Op: checkres.AtLeast, Rule: "px.json blackOutlineMaxSize", Summary: "小さい絵の外の縁が 1 色の最暗のまま一周"},
	{Name: "px.value-sep", Level: levelLint, Metric: "part_dL", Unit: "L", Op: checkres.AtLeast, Rule: "px.json valueSepMin か contrast の min", Summary: "contrast で測った部品と相手の明るさの差"},
	{Name: "px.ramp-order", Level: levelLint, Metric: "step_dL", Unit: "L", Op: checkres.AtLeast, Rule: "px.json rampMinGap", Summary: "ランプの隣の段の明るさの差（暗 → 明に単調）"},
	{Name: "px.seam.x", Level: levelLint, Metric: "edge_dL", Unit: "L", Op: checkres.AtMost, Rule: "px.json seamRatio", Summary: "タイルの左右の端の差（内側の差の seamRatio 倍か、内側の一番強い線まで）"},
	{Name: "px.seam.y", Level: levelLint, Metric: "edge_dL", Unit: "L", Op: checkres.AtMost, Rule: "px.json seamRatio", Summary: "タイルの上下の端の差"},
	{Name: "px.anim.pop", Level: levelLint, Metric: "swap_share", Unit: "ratio", Op: checkres.AtMost, Rule: "anim.json maxPopShare", Summary: "隣のコマでシルエットが入れ替わる割合"},
	{Name: "px.anim.loop", Level: levelLint, Metric: "swap_share", Unit: "ratio", Op: checkres.AtMost, Rule: "anim.json maxPopShare", Summary: "最後 → 最初のコマで入れ替わる割合（輪が閉じない）"},
	{Name: "px.anim.area", Level: levelLint, Metric: "area_drift", Unit: "ratio", Op: checkres.AtMost, Rule: "anim.json maxAreaDrift", Summary: "1 コマ目に対する面積のずれ"},
	{Name: "px.anim.ground", Level: levelLint, Metric: "float_px", Unit: "px", Op: checkres.AtMost, Rule: "anim.json footTolerance", Summary: "足が地面から浮く"},
	{Name: "px.anim.bob", Level: levelLint, Metric: "bob_px", Unit: "px", Op: checkres.AtMost, Rule: "anim.json maxBob", Summary: "頭の上下動"},
	{Name: "px.flicker", Level: levelLint, Metric: "flicker_px", Unit: "px", Op: checkres.AtMost, Summary: "コマの間で周りが動かないのに色だけ変わる画素"},
	{Name: "px.margin", Level: levelAdvice, Metric: "touching_sides", Unit: "count", Op: checkres.AtMost, Summary: "動く絵が格子の左・右・上の縁に触れる"},
	{Name: "px.ground-contrast.highlight", Level: levelAdvice, Metric: "highlight_minus_ground_L", Unit: "L", Op: checkres.AtLeast, Rule: "value-structure §4", Summary: "地が絵の最明色より暗い（絵の最明色の L − 地の L）"},
	{Name: "px.ground-contrast.chroma", Level: levelAdvice, Metric: "bright_ground_chroma", Unit: "C", Op: checkres.AtMost, Rule: "px.json groundBrightL・groundBrightChromaMax", Summary: "明るい地（L ≥ groundBrightL）の彩度（Oklch の C）"},
	{Name: "px.highlight-reserve.area", Level: levelAdvice, Metric: "brightest_share", Unit: "ratio", Op: checkres.AtMost, Rule: "px.json highlightMaxShare", Summary: "最明色が描いた画素に占める割合（ハイライト専用）"},
	{Name: "px.highlight-reserve.inside", Level: levelAdvice, Metric: "brightest_inside_share", Unit: "ratio", Op: checkres.AtMost, Rule: "px.json highlightInsideMax", Summary: "最明色の画素のうち面の中（四方が同じ色）にある割合"},
	{Name: "px.ramp-hue.step", Level: levelAdvice, Metric: "max_hue_step", Unit: "deg", Op: checkres.AtMost, Rule: "px.json rampHueMaxStep", Summary: "ランプの隣の段の色相の差の最大"},
	{Name: "px.ramp-hue.turn", Level: levelAdvice, Metric: "hue_turns", Unit: "count", Op: checkres.AtMost, Summary: "ランプの色相の回る向きが変わる回数"},
	{Name: "px.ramp-hue.flat", Level: levelAdvice, Metric: "hue_total", Unit: "deg", Op: checkres.AtLeast, Rule: "px.json rampHueMinTotal", Summary: "ランプが暗 → 明で回る色相の合計（平板）"},
	{Name: "px.ramp-chroma.peak", Level: levelAdvice, Metric: "peak_offset", Unit: "steps", Op: checkres.AtMost, Rule: "px.json rampChromaPeakSlack", Summary: "彩度の一番高い段の真ん中からのずれ（山の形）"},
	{Name: "px.ramp-chroma.bright", Level: levelAdvice, Metric: "bright_s", Unit: "S", Op: checkres.AtMost, Rule: "px.json rampBrightV・rampBrightSMax", Summary: "明るい段（HSV の V ≥ rampBrightV）の S の最大（高明度 × 高彩度）"},
	{Name: "px.value-blobs.count", Level: levelAdvice, Metric: "value_masses", Unit: "count", Op: checkres.InRange, Rule: "px.json valueBlobsMin・valueBlobsMax・valueBlobsMinShare", Summary: "明るさ 3 段の大きな塊の数（明暗の骨格）"},
	{Name: "px.value-blobs.cover", Level: levelAdvice, Metric: "mass_cover", Unit: "ratio", Op: checkres.AtLeast, Rule: "px.json valueBlobsCoverMin", Summary: "大きな塊が描いた画素を覆う割合"},
	{Name: "px.tile-variant-edge", Level: levelAdvice, Metric: "edge_diff_px", Unit: "px", Op: checkres.AtMost, Rule: "px.json tileVariantEdge", Summary: "タイルの変種の縁が元の種のコマと違う画素"},
	{Name: "px.outer-aa", Level: levelAdvice, Metric: "outer_aa_px", Unit: "px", Op: checkres.AtMost, Rule: "px.json outerAAMax", Summary: "透明に接する外周の段の角の中間色の 1px（全域で避ける）"},
	{Name: "px.style.size", Level: levelGate, Metric: "size_over", Unit: "ratio", Op: checkres.AtMost, Rule: "px.json styles.maxSize", Summary: "機種の最大の大きさに対する長い辺の割合"},
	{Name: "px.style.color", Level: levelGate, Metric: "outside_colors", Unit: "count", Op: checkres.AtMost, Rule: "px.json styles.colors・channelLevels", Summary: "機種で出せない色"},
	{Name: "px.style.colors", Level: levelGate, Metric: "colors", Unit: "count", Op: checkres.AtMost, Rule: "px.json styles.maxColors", Summary: "1 コマの色数"},
	{Name: "px.style.tile-colors", Level: levelGate, Metric: "tile_colors", Unit: "count", Op: checkres.AtMost, Rule: "px.json styles.maxTileColors", Summary: "升目ごとの色数"},
	{Name: "px.style.palette", Level: levelGate, Levels: []level{levelAdvice}, Metric: "palettes_needed", Unit: "count", Op: checkres.AtMost, Rule: "pxstyle palettes", Summary: "パレット N 本 × M 色に割り付けられない（下限で言い切れない時は advice）"},
}

func init() {
	for _, k := range []gateKind{gateNoEntry, gateBadStyle, gateNoColor, gateDenied, gateOutside, gateUnreadable} {
		pxCodes = append(pxCodes, checkres.Code{Name: "px.gate." + string(k), Level: levelGate, Metric: "bad_colors", Unit: "count", Op: checkres.AtMost,
			Rule: "<名前>.colorgate.json", Summary: "色の門: " + gateKindSummary[k]})
	}
	for _, c := range pxCodes {
		checkres.Register(c)
	}
}

var gateKindSummary = map[gateKind]string{
	gateNoEntry: "files に無い冊", gateBadStyle: "styles に無い画風", gateNoColor: "色票に無い色の名前",
	gateDenied: "どの画風でも使わない色", gateOutside: "画風の色の外", gateUnreadable: "読めない冊",
}

// result は違反を外へ出す形（checkres.Result）にする。where の画素は rules の maxCells まで。
// 検査は外れた時だけ違反を出すので、測った値が境目ちょうどで pass に見える時（> と >= の違い）は fail のまま出す。
func (v violation) result(rules *checkres.Rules) checkres.Result {
	r := checkres.New(v.code(), v.Level, checkres.Measure{Got: v.Got, Want: v.Want}, rules, v.Msg)
	if r.Status == checkres.Pass {
		r.Status = checkres.Fail
	}
	r.Where.Sprite, r.Where.Frame = v.Sprite, v.Frame
	if v.HasAt {
		r.Where.SetAt(v.X, v.Y)
	}
	if len(v.Cells) > 0 {
		cells := make([]checkres.Pt, len(v.Cells))
		for i, p := range v.Cells {
			cells[i] = checkres.Pt{X: p.X, Y: p.Y}
		}
		r.Where.SetCells(cells, rules.MaxCells)
	}
	r.Cause.Op, r.Cause.Script = v.Op.String(), v.Script
	hint := v.Fix
	if hint == "" { // px check の道（runCheck を通らない sprite の規則）でも直し方の既定を入れる
		hint = spriteFix[v.Rule]
		if v.Check != checkSprite {
			if ck, ok := checks[v.Check]; ok {
				hint = ck.Fix
			}
		}
	}
	r.Fix = checkres.Fix{Hint: hint, Try: v.Tries}
	return r
}
