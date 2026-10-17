package pxlib

// sprite.json の文字格子を、コマごとに拡大した PNG に描く（carve-render の中身）。

import (
	"fmt"
	"path/filepath"
	"strings"
)

// RenderDoc は 1 つの sprite.json を PNG に描き、書いたパスを返す。
// 色は legend の値（#rrggbb か {"hex": …}）か、Doc の中の "palette" の名前（"@名前" も可）から引く。
// 引けない字と '.' は透明。1 辺が 48 以下なら 8 倍、それより大きければ 4 倍。
func RenderDoc(path, outDir string) ([]string, error) {
	doc, err := LoadOrdered(path)
	if err != nil {
		return nil, err
	}
	plain, _ := Plain(doc).(map[string]any)
	palette := map[string]string{}
	if obj, ok := plain["palette"].(map[string]any); ok {
		for name, v := range obj {
			if hex := HexOfValue(v); hex != "" {
				palette[name] = hex
			}
		}
	}
	legend := map[string]RGBA{}
	if obj, ok := plain["legend"].(map[string]any); ok {
		for char, v := range obj {
			resolved := HexOfValue(v)
			if s, ok := v.(string); ok && resolved == "" {
				resolved = palette[strings.TrimPrefix(s, "@")]
			}
			if c, ok := RGBAOfValue(resolved); ok {
				legend[char] = c
			}
		}
	}

	base := strings.Replace(filepath.Base(path), ".sprite.json", "", 1)
	var written []string
	sprites, ok := doc.GetOr("sprites", nil).(*Obj)
	if !ok {
		return written, nil
	}
	names, specs := sprites.Items()
	for i, spriteName := range names {
		spec, isObj := specs[i].(*Obj)
		if strings.HasPrefix(spriteName, "//") || !isObj {
			continue
		}
		frames, isObj := spec.GetOr("frames", nil).(*Obj)
		if !isObj {
			continue
		}
		frameNames, frameVals := frames.Items()
		for j, frameName := range frameNames {
			list, isList := frameVals[j].([]any)
			if !isList {
				continue
			}
			var rows [][]rune
			width := 0
			for _, r := range list {
				s, _ := r.(string)
				rows = append(rows, []rune(s))
				width = max(width, len([]rune(s)))
			}
			height := len(rows)
			if width == 0 || height == 0 {
				continue
			}
			scale := 4
			if max(width, height) <= 48 {
				scale = 8
			}
			out := make([][]RGBA, 0, height*scale)
			for _, row := range rows {
				line := make([]RGBA, 0, width*scale)
				for x := 0; x < width; x++ {
					var px RGBA
					if x < len(row) {
						px = legend[string(row[x])]
					}
					for range scale {
						line = append(line, px)
					}
				}
				for range scale {
					out = append(out, line)
				}
			}
			file := filepath.Join(outDir, fmt.Sprintf("%s__%s__%s.png", base, spriteName, frameName))
			if err := WritePNG(file, ImageOfRows(out)); err != nil {
				return written, err
			}
			written = append(written, file)
		}
	}
	return written, nil
}
