package main

import (
	"encoding/json"
	"fmt"
	"path"
	"path/filepath"
	"strings"
)

// webStripExts は動く時に読まない制作の元ファイル。既定で束から外す。
var webStripExts = map[string]bool{
	".blend": true, ".blend1": true, ".psd": true, ".kra": true, ".aseprite": true, ".ase": true, ".xcf": true,
}

// webNoticeExts は束に残すが、起動に入る量を知らせる形。
// WhyNot: 既定で外さない — 字の一覧・クレジット・台本を .txt で読むゲームがあり、起動の確かめはタイトルまでしか見ないので、外して壊れても気づけない。
var webNoticeExts = map[string]bool{".md": true, ".txt": true}

// isWebStripDefault は rel が既定で外す形か（schema は Studio とエディタだけが読む）。
func isWebStripDefault(rel string) bool {
	lower := strings.ToLower(rel)
	return strings.HasSuffix(lower, ".schema.json") || webStripExts[path.Ext(lower)]
}

type webKeepSettings struct {
	Keep []string `json:"keep"`
}

// resolveWebKeep は project.json の web.keep（既定で外す形のうち、束に戻す物の glob）。
func resolveWebKeep(raw json.RawMessage) ([]webGlob, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var s webKeepSettings
	if err := json.Unmarshal(raw, &s); err != nil {
		return nil, fmt.Errorf("project.json の web.keep を読めない: %v\n  次: glob の字の配列にする（例 [\"assets/editor.schema.json\"]）", err)
	}
	var globs []webGlob
	for _, g := range s.Keep {
		wg, err := compileWebGlob(g)
		if err != nil {
			return nil, fmt.Errorf("project.json の web.keep: %v", err)
		}
		globs = append(globs, wg)
	}
	return globs, nil
}

// webStripPlan は既定で外した物と、残したが知らせる物。大きさはゲームの元のファイルで数える。
type webStripPlan struct {
	Stripped      []string
	StrippedBytes int64
	Noticed       []string
	NoticedBytes  int64
}

// planWebStrip は files（web.embed と web.omit を当てる前の束）から既定で外す物を選ぶ。
// web.embed・web.omit に当たる物はそちらが扱うので数えない。当たる物の無い web.keep の glob は誤り。
// WhyNot: web.omit の後で選ぶ — テンプレートとゲームに残る web.omit の "assets/*.schema.json" が、先に外すと何にも当たらず誤りになる。
func planWebStrip(game string, files []string, keep []webGlob, embed webEmbedPlan) (webStripPlan, error) {
	var plan webStripPlan
	hidden := map[string]bool{}
	for _, rel := range append(append([]string{}, embed.Embedded...), embed.Omitted...) {
		hidden[rel] = true
	}
	hit := map[string]bool{}
	for _, rel := range files {
		for _, g := range keep {
			if g.match(rel) {
				hit[g.Pattern] = true
			}
		}
		if hidden[rel] || rel == "project.json" {
			continue
		}
		size := fileSize(filepath.Join(game, filepath.FromSlash(rel)))
		switch {
		case isWebStripDefault(rel) && !matchAny(keep, rel):
			plan.Stripped = append(plan.Stripped, rel)
			plan.StrippedBytes += size
		case webNoticeExts[strings.ToLower(path.Ext(rel))]:
			plan.Noticed = append(plan.Noticed, rel)
			plan.NoticedBytes += size
		}
	}
	for _, g := range keep {
		if !hit[g.Pattern] {
			return plan, fmt.Errorf("project.json の web.keep の %q に当たるファイルが assets/ の下に無い。\n  次: ゲームの根からの道に直す（例 assets/editor.schema.json）", g.Pattern)
		}
	}
	return plan, nil
}

// without は files から外す物を抜く。
func (plan webStripPlan) without(files []string) []string {
	if len(plan.Stripped) == 0 {
		return files
	}
	drop := map[string]bool{}
	for _, rel := range plan.Stripped {
		drop[rel] = true
	}
	kept := []string{}
	for _, rel := range files {
		if !drop[rel] {
			kept = append(kept, rel)
		}
	}
	return kept
}
