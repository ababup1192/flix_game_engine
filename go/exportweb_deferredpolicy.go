package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// project.json の web.deferredPolicy（後回しの物が届く前に使われた時の扱い）。行の先勝ち。
// match は後回しの道の glob か font:<名前>。onMissing は絵とフォントが wait・placeholder、音が wait・skip。group は押した時の待ちで一緒に待つ組。
type webDeferredPolicyRow struct {
	Match     string `json:"match"`
	OnMissing string `json:"onMissing,omitempty"`
	Group     string `json:"group,omitempty"`
	// Why は絵を placeholder にする理由（絵の placeholder には必須）。
	Why string `json:"why,omitempty"`
}

type webDeferredPolicySettings struct {
	DeferredPolicy []webDeferredPolicyRow `json:"deferredPolicy"`
}

// webDeferredPolicy は読んだ行と、glob の行の照合器（font: の行は nil）。
type webDeferredPolicy struct {
	Rows  []webDeferredPolicyRow
	globs []*webGlob
}

func resolveWebDeferredPolicy(raw json.RawMessage) (webDeferredPolicy, error) {
	var pol webDeferredPolicy
	if len(raw) == 0 || string(raw) == "null" {
		return pol, nil
	}
	var web struct {
		DeferredPolicy json.RawMessage `json:"deferredPolicy"`
	}
	var s webDeferredPolicySettings
	err := json.Unmarshal(raw, &web)
	if err == nil && len(web.DeferredPolicy) > 0 {
		// WhyNot: 欄の書き違い（grop など）を黙って通さない — 行が当たっても扱いが効かず、気付けない。
		dec := json.NewDecoder(bytes.NewReader(web.DeferredPolicy))
		dec.DisallowUnknownFields()
		err = dec.Decode(&s.DeferredPolicy)
	}
	if err != nil {
		return pol, fmt.Errorf("project.json の web.deferredPolicy を読めない: %v\n  次: { \"match\": \"<glob か font:名前>\", \"onMissing\": \"wait\", \"group\": \"start\" } の並びにする", err)
	}
	for _, row := range s.DeferredPolicy {
		if row.Match == "" {
			return pol, fmt.Errorf("project.json の web.deferredPolicy に match の無い行がある。\n  次: 後回しの道の glob か font:名前を書く")
		}
		if row.OnMissing == "" && row.Group == "" {
			return pol, fmt.Errorf("project.json の web.deferredPolicy の %q に onMissing も group も無い（先勝ちなので後ろの行を黙って隠す）。\n  次: どちらかを書くか行を消す", row.Match)
		}
		switch row.OnMissing {
		case "", "wait", "placeholder", "skip":
		default:
			return pol, fmt.Errorf("project.json の web.deferredPolicy の %q の onMissing %q を知らない。\n  次: wait・placeholder（絵とフォント）・skip（音）のどれかにする", row.Match, row.OnMissing)
		}
		if strings.HasPrefix(row.Match, "font:") {
			pol.globs = append(pol.globs, nil)
		} else {
			g, err := compileWebGlob(row.Match)
			if err != nil {
				return pol, fmt.Errorf("project.json の web.deferredPolicy: %v", err)
			}
			pol.globs = append(pol.globs, &g)
		}
		pol.Rows = append(pol.Rows, row)
	}
	return pol, nil
}

// webDeferredKindOf は後回しの道 1 本の種類（onMissing の読み替えに使う）。
func webDeferredKindOf(rel string, b *webBundle) string {
	if strings.HasSuffix(rel, ".fontatlas") {
		return "font"
	}
	for _, s := range b.Sounds {
		if s.Path == rel {
			return "sound"
		}
	}
	for _, img := range b.Images {
		if img == rel {
			return "image"
		}
	}
	return "file"
}

// onMissingFits は onMissing がその種類に使える値か（files は届く前に使っても待たないので wait 以外は効かない）。
func onMissingFits(kind, onMissing string) bool {
	switch {
	case onMissing == "" || onMissing == "wait":
		return true
	case kind == "file":
		return false
	case kind == "sound":
		return onMissing == "skip"
	default:
		return onMissing == "placeholder"
	}
}

// applyWebDeferredPolicy は後回しの項目に、当たった最初の行の onMissing と group を書く。
// 誤り: 行の onMissing が、その行に当たった物の種類に使えない値（種類ごとに道を並べて言う）。知らせ: どの項目にも当たらない行。
// WhyNot: 種類の混ざる glob に片方の種類の値を書いた時に、使える物にだけ当てて黙らない — 音に placeholder を書いたつもりの行が、何も効かないまま残る。
func applyWebDeferredPolicy(entries []webDeferredEntry, pol webDeferredPolicy, b *webBundle) ([]webDeferredEntry, []string, error) {
	if len(pol.Rows) == 0 {
		return entries, nil, nil
	}
	used := make([]bool, len(pol.Rows))
	misfits := map[int]map[string][]string{}
	out := make([]webDeferredEntry, len(entries))
	for i, e := range entries {
		out[i] = e
		kind := webDeferredKindOf(e.Path, b)
		for r, row := range pol.Rows {
			if !policyRowMatches(row, pol.globs[r], e, kind) {
				continue
			}
			used[r] = true
			if !onMissingFits(kind, row.OnMissing) {
				if misfits[r] == nil {
					misfits[r] = map[string][]string{}
				}
				misfits[r][kind] = append(misfits[r][kind], e.Path)
			}
			out[i].OnMissing = row.OnMissing
			out[i].Group = row.Group
			break
		}
	}
	if len(misfits) > 0 {
		rows := make([]int, 0, len(misfits))
		for r := range misfits {
			rows = append(rows, r)
		}
		sort.Ints(rows)
		r := rows[0]
		var parts []string
		for _, kind := range []string{"image", "font", "sound", "file"} {
			if paths := misfits[r][kind]; len(paths) > 0 {
				parts = append(parts, fmt.Sprintf("%s: %s", kind, strings.Join(paths, "・")))
			}
		}
		return nil, nil, fmt.Errorf("project.json の web.deferredPolicy の %q の onMissing %q が、当たった物の種類に使えない（%s）。\n  次: 絵とフォントは wait か placeholder・音は wait か skip。種類ごとに行を分ける", pol.Rows[r].Match, pol.Rows[r].OnMissing, strings.Join(parts, " / "))
	}
	var warnings []string
	for r, ok := range used {
		if !ok {
			warnings = append(warnings, fmt.Sprintf("web.deferredPolicy の %q はどの後回しの物にも当たらない（効かない行）", pol.Rows[r].Match))
		}
	}
	return out, warnings, nil
}

func policyRowMatches(row webDeferredPolicyRow, g *webGlob, e webDeferredEntry, kind string) bool {
	if g == nil {
		if kind != "font" {
			return false
		}
		want := strings.TrimPrefix(row.Match, "font:")
		for _, n := range e.Names {
			if n == want {
				return true
			}
		}
		return false
	}
	return g.match(e.Path)
}

// placeholderImageRowsWithoutWhy は、後回しの絵に placeholder を当てているのに why の無い行の match（並びは行の順）。
// WhyNot: 絵の placeholder を理由なしで通さない — 待ちが消えて門の秒は減るが、押した後に黒いコマで先へ進む（人の要件に反する）。
func placeholderImageRowsWithoutWhy(entries []webDeferredEntry, pol webDeferredPolicy, b *webBundle) []string {
	hit := make([]bool, len(pol.Rows))
	for _, e := range entries {
		kind := webDeferredKindOf(e.Path, b)
		for r, row := range pol.Rows {
			if !policyRowMatches(row, pol.globs[r], e, kind) {
				continue
			}
			if kind == "image" && row.OnMissing == "placeholder" && strings.TrimSpace(row.Why) == "" {
				hit[r] = true
			}
			break
		}
	}
	var out []string
	for r, ok := range hit {
		if ok {
			out = append(out, pol.Rows[r].Match)
		}
	}
	return out
}
