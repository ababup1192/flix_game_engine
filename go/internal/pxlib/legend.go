package pxlib

import (
	"path/filepath"
	"sort"
	"strings"
)

// LegendColorsOf はドット絵 (*.sprite.json) の legend を 文字 → RGBA に解き、
// 解けなかった色名 (文字=名前) を並べて返す。sil と rounds が共有する。
//
// 色名の出どころは 3 つ (後ろほど強い): gameDir の下の *.theme.json / doc の paletteFile / doc の palette。
// 解けない文字は塗らない (palette サブコマンドの縄張り)。
func LegendColorsOf(gameDir string, doc map[string]any) (map[string]RGBA, []string) {
	names := map[string]RGBA{}
	for _, rel := range WalkJSON(gameDir, SpriteExcludedDirs) {
		if strings.HasSuffix(rel, ".theme.json") {
			for k, v := range ColorMapOf(ReadJSON(filepath.Join(gameDir, rel))) {
				names[k] = v
			}
		}
	}
	if ref, ok := doc["paletteFile"].(string); ok {
		for k, v := range ColorMapOf(ReadJSON(filepath.Join(gameDir, ref))) {
			names[k] = v
		}
	}
	for k, v := range ColorMapOf(doc["palette"]) {
		names[k] = v
	}

	colors := map[string]RGBA{}
	var unresolved []string
	legend, _ := AsObject(doc["legend"])
	for char, value := range legend {
		if direct, ok := RGBAOfValue(value); ok {
			colors[char] = direct
			continue
		}
		if s, ok := value.(string); ok {
			name := strings.TrimPrefix(s, "@")
			if got, ok := names[name]; ok {
				colors[char] = got
				continue
			}
			unresolved = append(unresolved, char+"="+name)
			continue
		}
		unresolved = append(unresolved, char)
	}
	sort.Strings(unresolved)
	return colors, unresolved
}
