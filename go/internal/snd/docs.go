package snd

// docs/snd-ops.md と docs/sndsrc.schema.json は op の登録（op.go の opDef）から作る（手で書かない）。

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/opreg"
)

func opsText() string {
	var b strings.Builder
	for _, d := range allOps() {
		kind := "効果"
		if d.source() {
			kind = "音源"
		}
		fmt.Fprintf(&b, "%-9s %s  %s\n          引数: %s\n          例: %s\n", d.Name, kind, d.Summary, opreg.Names(d.Params), d.Example)
	}
	return b.String()
}

func opsMarkdown() string {
	var b strings.Builder
	b.WriteString(`# snd の op（fge snd ops --md が op の登録から作る。手で直さない）

音 1 本の指定は ` + "`<名前>.sndsrc.json`" + `（形は docs/sndsrc.schema.json）。繰り返しは台本 ` + "`<名前>.snd.star`" + ` で書く。

- 声（voices の 1 つ）の ops は「音源の op 1 つ → 効果の op を順に」。声は ` + "`at`" + ` ミリ秒の所に置き、声の順に足す。` + "`post`" + ` は足した後に順に掛ける効果の op。
- ` + "`style`" + ` は機種の縛り（bin/lint-rules/snd.json の styles。` + "`free`" + ` は縛りなし）。` + "`kind`" + `（ui・sfx・bgm）は音量の目安を選ぶ。
- ループ: song の op が譜面のループ点から決めるか、` + "`loop_start_ms`" + `。` + "`tempo`" + `（song は譜面の bpm）があれば輪が整数小節かを見る。
- 検査: gate = clip（±1 を超えた）・seam（継ぎ目）・bars（小節）・style（機種の外）。gate は「その op を外すと直る」op を原因として付ける。lint = loudness・peak・head・tail・dc。advice = alias。
- 台本から呼べる物: ` + "`snd.write_spec(path, value)`" + `・` + "`snd.read_json(path)`" + `（作業場の .json を読むだけ）・` + "`op.<名前>(引数=…)`" + `・` + "`math`" + `（正しく丸めた値）。箱の決まりは px の台本と同じ（starbox）。

| op | 種類 | 何をするか | 機種 |
|---|---|---|---|
`)
	for _, d := range allOps() {
		kind := "効果"
		if d.source() {
			kind = "音源"
		}
		fmt.Fprintf(&b, "| `%s` | %s | %s | %s |\n", d.Name, kind, d.Summary, d.Machine)
	}
	for _, d := range allOps() {
		fmt.Fprintf(&b, "\n## %s\n\n%s\n\n例: `%s`\n\n%s", d.Name, d.Summary, d.Example, opreg.MarkdownParams(d.Params))
	}
	return b.String()
}

func schema() map[string]any {
	var ops, fx []any
	for _, d := range allOps() {
		one := map[string]any{"type": "object", "additionalProperties": false, "minProperties": 1, "maxProperties": 1,
			"description": d.Summary, "properties": map[string]any{d.Name: opreg.SchemaOf(d.Params)}}
		ops = append(ops, one)
		if !d.source() {
			fx = append(fx, one)
		}
	}
	return map[string]any{
		"$schema":              "https://json-schema.org/draft/2020-12/schema",
		"title":                "sndsrc（音 1 本の指定）",
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"target", "voices"},
		"properties": map[string]any{
			"version":       map[string]any{"type": "integer"},
			"note":          map[string]any{"type": "string"},
			"style":         map[string]any{"type": "string", "description": "機種（bin/lint-rules/snd.json の styles の名前か .json の Doc）", "default": "free"},
			"kind":          map[string]any{"enum": kinds, "default": "sfx"},
			"rate":          map[string]any{"type": "integer", "minimum": 8000, "maximum": 96000, "default": 22050},
			"target":        map[string]any{"type": "string", "pattern": "\\.wav$", "description": "書き出す WAV（assets/ の外）"},
			"loop_start_ms": map[string]any{"type": "number", "minimum": 0},
			"tempo": map[string]any{"type": "object", "additionalProperties": false, "required": []string{"bpm"},
				"properties": map[string]any{"bpm": map[string]any{"type": "number", "exclusiveMinimum": 0},
					"beats_per_bar": map[string]any{"type": "integer", "minimum": 1, "default": 4}}},
			"voices": map[string]any{"type": "array", "minItems": 1, "items": map[string]any{
				"type": "object", "additionalProperties": false, "required": []string{"ops"},
				"properties": map[string]any{
					"id":  map[string]any{"type": "string"},
					"at":  map[string]any{"type": "number", "minimum": 0, "description": "置く所（ミリ秒）"},
					"ops": map[string]any{"type": "array", "minItems": 1, "items": map[string]any{"oneOf": ops}},
				}}},
			"post": map[string]any{"type": "array", "items": map[string]any{"oneOf": fx}},
		},
	}
}

func writeDocs(out, errOut *strings.Builder, engineRoot string) int {
	data, _ := json.MarshalIndent(schema(), "", "  ")
	files := map[string][]byte{
		filepath.Join(engineRoot, "docs", "snd-ops.md"):         []byte(opsMarkdown()),
		filepath.Join(engineRoot, "docs", "sndsrc.schema.json"): append(data, '\n'),
	}
	for p, d := range files {
		if err := os.WriteFile(p, d, 0o644); err != nil {
			fmt.Fprintf(errOut, "snd: %v\n", err)
			return 1
		}
		fmt.Fprintf(out, "書いた: %s\n", p)
	}
	return 0
}
