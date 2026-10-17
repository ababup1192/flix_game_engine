package main

// palette — ドット絵 (*.sprite.json) の legend の意味色キーが Studio から解けるか検査する
// ゲート。

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

func paletteNamesOf(gameDir string, doc map[string]any) map[string]bool {
	names := map[string]bool{}
	if ref, ok := doc["paletteFile"].(string); ok {
		for n := range pxlib.ColorNamesOf(pxlib.LoadJSON(filepath.Join(gameDir, ref))) {
			names[n] = true
		}
	}
	for n := range pxlib.ColorNamesOf(doc["palette"]) {
		names[n] = true
	}
	return names
}

type legendMiss struct {
	char  string
	value string
}

func unresolvedOf(doc map[string]any, names map[string]bool) []legendMiss {
	legend, ok := pxlib.AsObject(doc["legend"])
	if !ok {
		return nil
	}
	chars := make([]string, 0, len(legend))
	for c := range legend {
		chars = append(chars, c)
	}
	sort.Strings(chars)
	var bad []legendMiss
	for _, char := range chars {
		value, ok := legend[char].(string)
		if !ok {
			continue
		}
		if pxlib.IsHexColor(value) {
			continue
		}
		name := strings.TrimPrefix(value, "@")
		if !names[name] {
			bad = append(bad, legendMiss{char, value})
		}
	}
	return bad
}

// paletteResult は --json 用のまとめ。
type paletteResult struct {
	Problems []string `json:"problems"`
	Docs     int      `json:"docs"`
	Keys     int      `json:"keys"`
	Exit     int      `json:"exit"`
}

func runPalette(out *strings.Builder, root string, asJSON bool) int {
	var problems []string
	docCount, keyCount := 0, 0

	for _, game := range pxlib.GameDirsOf(root, func() bool { return pxlib.HasDir(filepath.Join(root, "assets")) }) {
		gameDir := filepath.Join(root, game)
		jsonPaths := pxlib.WalkJSON(gameDir, pxlib.PaletteExcludedDirs)
		var spritePaths []string
		for _, p := range jsonPaths {
			if strings.HasSuffix(p, ".sprite.json") {
				spritePaths = append(spritePaths, p)
			}
		}
		if len(spritePaths) == 0 {
			continue
		}
		themes := map[string]bool{}
		for _, rel := range jsonPaths {
			if strings.HasSuffix(rel, ".theme.json") {
				for n := range pxlib.ColorNamesOf(pxlib.LoadJSON(filepath.Join(gameDir, rel))) {
					themes[n] = true
				}
			}
		}
		for _, rel := range spritePaths {
			doc, ok := pxlib.AsObject(pxlib.LoadJSON(filepath.Join(gameDir, rel)))
			if !ok {
				problems = append(problems, fmt.Sprintf("%s/%s: JSON として読めない", game, rel))
				continue
			}
			docCount++
			if legend, ok := pxlib.AsObject(doc["legend"]); ok {
				keyCount += len(legend)
			}
			names := map[string]bool{}
			for n := range themes {
				names[n] = true
			}
			for n := range paletteNamesOf(gameDir, doc) {
				names[n] = true
			}
			for _, miss := range unresolvedOf(doc, names) {
				problems = append(problems, fmt.Sprintf(
					"%s/%s: legend '%s' の \"%s\" がどの色票にも無い"+
						" (*.theme.json のトップレベル / paletteFile / inline palette)",
					game, rel, miss.char, miss.value))
			}
		}
	}

	exit := 0
	if len(problems) > 0 {
		exit = 1
	}
	if asJSON {
		emitJSON(out, paletteResult{orEmpty(problems), docCount, keyCount, exit})
		return exit
	}
	if exit == 1 {
		for _, line := range problems {
			fmt.Fprintln(out, line)
		}
		fmt.Fprintf(out, "NG: %d 個の意味色キーが解けない (sprite Doc %d 件を検査)\n",
			len(problems), docCount)
		return 1
	}
	fmt.Fprintf(out, "OK: sprite Doc %d 件・legend %d キーすべて色票で解ける\n", docCount, keyCount)
	return 0
}
