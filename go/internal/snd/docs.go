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

- 声（voices の 1 つ）の ops は「音源の op 1 つ → 効果の op を順に」。声は ` + "`at`" + ` ミリ秒の所に置き、` + "`pan`" + `（-1 左・0 真ん中・1 右）で振って声の順に足す。` + "`post`" + ` は足した後に順に掛ける効果の op。
- 書き出しはステレオ（` + "`channels`" + ` の既定は ` + "`stereo`" + `。` + "`mono`" + ` で今までどおり 1 本）。左右の振り方は真ん中で両方 1・振り切ると片方 0。効果は左右に 1 本ずつ同じ式で掛ける（normalize・reverb・delay・finish は左右を一緒に見る）。
- ` + "`style`" + ` は機種の縛り（bin/lint-rules/snd.json の styles: ` + "`gb`" + `・` + "`neo`" + `（チップの音色 + 今のミックス）・` + "`free`" + ` は縛りなし）。機種の外の手（reverb・delay・sidechain・sub・pan）は style の ` + "`breaks`" + ` にある物だけ書け、使えば report の ` + "`breaks`" + ` に「破った所」として残る。` + "`kind`" + `（ui・sfx・bgm）は音量の目安を選ぶ（normalize の既定）。
- ループ: song の op が譜面のループ点から決めるか、` + "`loop_start_ms`" + `。` + "`tempo`" + `（song は譜面の bpm）があれば輪が整数小節かを見る。
- 検査（左右を 1 本ずつ見る。音量は左右を足した LUFS で、ループする音は輪の 1 周）: gate = clip（±1 を超えた）・seam（継ぎ目）・bars（小節）・style（機種の外）。gate は「その op を外すと直る」op を原因として付ける。lint = loudness・peak・truepeak（4 倍に読み直したピーク）・head・tail・dc。advice = alias・breaks。
- 台本から呼べる物: ` + "`snd.write_spec(path, value)`" + `・` + "`snd.write_chip(path, value)`" + `（曲を譜面に。下の節）・` + "`snd.read_json(path)`" + `（作業場の .json を読むだけ）・` + "`op.<名前>(引数=…)`" + `・` + "`mus.*`" + `（曲を書く部品。下の節）・` + "`math`" + `（正しく丸めた値）。箱の決まりは px の台本と同じ（starbox）。

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
	b.WriteString(chipMarkdown())
	return b.String()
}

// chipMarkdown は譜面（chip.json）の欄・段のコマンド・楽器の表・台本の mus と write_chip の節。
func chipMarkdown() string {
	var b strings.Builder
	b.WriteString(`
## 譜面（chip.json）

song の op が読む譜面。形は docs/chip.schema.json。今の形（phrase 16 段 → chain → rows・5 本のチャンネル）はそのまま読め、足した欄は書かなければ今までどおり。

| 欄 | 中身 |
|---|---|
`)
	for _, f := range chipFields {
		fmt.Fprintf(&b, "| `%s` | %s |\n", f.Key, f.Summary)
	}
	b.WriteString("\n段の文字は `音 楽器 v音量 コマンド…`（`C#5 lead v12 DLY 2 VSL -1`。`OFF` は離す）。コマンドは 1 段に並べて書ける:\n\n| コマンド | 中身 |\n|---|---|\n")
	for _, c := range stepCmds {
		fmt.Fprintf(&b, "| `%s` | %s |\n", c.Word, c.Summary)
	}
	b.WriteString("\n楽器は今の rows（1 行に全部）か、表の形（表ごとに長さ・ループ・離した後を持つ）:\n\n| 表 | 中身 |\n|---|---|\n")
	for _, m := range macroFields {
		fmt.Fprintf(&b, "| `%s` | %s |\n", m.Key, m.Summary)
	}
	b.WriteString("\n## 台本で曲を書く（mus と snd.write_chip）\n\n段の並び（part）は Starlark の list。`+` でつなぎ、`*` でくり返し、`[a:b]` で切り出す。\n\n| 関数 | 中身 |\n|---|---|\n")
	for _, f := range musFuncs {
		fmt.Fprintf(&b, "| `%s` | %s |\n", f.Sig, f.Summary)
	}
	b.WriteString("\n`snd.write_chip(path, value)` は value の part を 16 段ずつ phrase にまとめ（同じ中身は 1 つ）、チャンネルごとの chain と rows を作って譜面を書く（build ではメモリの中だけ・gen ではファイル）。返すのは path（`op.song(chip = …)` に渡す）。value の鍵:\n\n| 鍵 | 中身 |\n|---|---|\n")
	for _, w := range writeChipKeys {
		fmt.Fprintf(&b, "| `%s` | %s |\n", w.Key, w.Summary)
	}
	return b.String()
}

// chipFields は譜面の欄（docs と schema に出す）。
var chipFields = []struct{ Key, Summary string }{
	{"bpm", "速さ（4 分音符/分。既定 120）"},
	{"ticks", "1 段の tick（既定 6）"},
	{"groove", "段ごとの tick の並び（[7, 5] で跳ねる。平均が拍の速さを決める・長さは 16 を割り切る）"},
	{"loop", "ループの頭の rows の行（無ければループしない）"},
	{"gain", "全体の倍率"},
	{"mix", "今の形の 5 本のチャンネルの倍率（channels を書かない時だけ）"},
	{"channels", "チャンネルの並び [{name, part（pulse・triangle・noise・wave）, vol, pan（-1〜1）, cents（デチューン）, sub（1 オクターブ下のサイン。機種の外）, duck（サイドチェインで沈める）, send: {reverb, delay}}]。rows の鍵はこの名前"},
	{"fx", "機種の外の厚み {reverb: {room, damp, wet, predelay_ms}, delay: {steps（段）, feedback, wet, pingpong, lowpass}, sidechain: {key（合図の楽器の名前の並び）, depth_db, release_ms}}"},
	{"instruments", "楽器（*.instrument.json と同じ形。譜面の方が勝つ）"},
	{"waves", "波形メモリの形（名前 → 32 段 × 0〜15）"},
	{"phrases", "名前 → 16 段の段の文字"},
	{"chains", "名前 → phrase の並び（\"名前 +半音\" で移調）"},
	{"rows", "曲の並び（行ごとに {チャンネル: chain}）"},
}

// macroFields は楽器の表の形の欄。
var macroFields = []struct{ Key, Summary string }{
	{"vol", "音量 0〜15 の表（\"15 13 12 | 11 10 / 6 3 0\": | の後をループ・/ の後は離した後に流す）"},
	{"arp", "音程（半音）の表。arp_fixed: true なら音の高さそのもの（太鼓）"},
	{"pitch", "音程のずれ（セント）の表"},
	{"duty", "デューティ（12・25・50・75）・波形の名前・雑音（long・short）の表"},
	{"vib", "\"hz cents 遅れの tick\"（遅れてかかるビブラート）"},
	{"speed", "表を何 tick ごとに進めるか（既定 1）"},
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
			"channels":      map[string]any{"enum": []string{"stereo", "mono"}, "default": "stereo", "description": "書き出しのチャンネル"},
			"tempo": map[string]any{"type": "object", "additionalProperties": false, "required": []string{"bpm"},
				"properties": map[string]any{"bpm": map[string]any{"type": "number", "exclusiveMinimum": 0},
					"beats_per_bar": map[string]any{"type": "integer", "minimum": 1, "default": 4}}},
			"voices": map[string]any{"type": "array", "minItems": 1, "items": map[string]any{
				"type": "object", "additionalProperties": false, "required": []string{"ops"},
				"properties": map[string]any{
					"id":  map[string]any{"type": "string"},
					"at":  map[string]any{"type": "number", "minimum": 0, "description": "置く所（ミリ秒）"},
					"pan": map[string]any{"type": "number", "minimum": -1, "maximum": 1, "description": "左右（-1 左・0 真ん中・1 右）"},
					"ops": map[string]any{"type": "array", "minItems": 1, "items": map[string]any{"oneOf": ops}},
				}}},
			"post": map[string]any{"type": "array", "items": map[string]any{"oneOf": fx}},
		},
	}
}

func writeDocs(out, errOut *strings.Builder, engineRoot string) int {
	data, _ := json.MarshalIndent(schema(), "", "  ")
	chipData, _ := json.MarshalIndent(chipSchema(), "", "  ")
	files := map[string][]byte{
		filepath.Join(engineRoot, "docs", "snd-ops.md"):         []byte(opsMarkdown()),
		filepath.Join(engineRoot, "docs", "sndsrc.schema.json"): append(data, '\n'),
		filepath.Join(engineRoot, "docs", "chip.schema.json"):   append(chipData, '\n'),
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

// chipSchema は譜面（chip.json）の JSON Schema（欄の説明は chipFields・macroFields）。
func chipSchema() map[string]any {
	desc := map[string]string{}
	for _, f := range chipFields {
		desc[f.Key] = f.Summary
	}
	mdesc := map[string]string{}
	for _, m := range macroFields {
		mdesc[m.Key] = m.Summary
	}
	str := func(k string) map[string]any { return map[string]any{"type": "string", "description": mdesc[k]} }
	table := func(k string) map[string]any {
		return map[string]any{"description": mdesc[k], "oneOf": []any{map[string]any{"type": "string"},
			map[string]any{"type": "array", "items": map[string]any{"type": []string{"number", "string"}}}}}
	}
	inst := map[string]any{"type": "object", "properties": map[string]any{
		"speed": map[string]any{"type": "integer", "minimum": 1, "description": mdesc["speed"]},
		"rows":  map[string]any{"type": "array", "description": "今の形の表（1 行に vol・pitch・cents・wave・cmd）"},
		"vol":   table("vol"), "arp": table("arp"), "pitch": table("pitch"), "duty": table("duty"), "vib": str("vib"),
		"arp_fixed": map[string]any{"type": "boolean"}, "note": map[string]any{"type": "string"},
	}}
	num := func(k string) map[string]any { return map[string]any{"type": "number", "description": desc[k]} }
	return map[string]any{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"title":   "chip（song の op が読む譜面）",
		"type":    "object",
		"properties": map[string]any{
			"version": map[string]any{"type": "integer"}, "note": map[string]any{"type": "string"},
			"bpm": num("bpm"), "gain": num("gain"),
			"ticks":  map[string]any{"type": "integer", "minimum": 1, "description": desc["ticks"]},
			"loop":   map[string]any{"type": "integer", "description": desc["loop"]},
			"groove": map[string]any{"type": "array", "items": map[string]any{"type": "integer", "minimum": 1}, "description": desc["groove"]},
			"mix":    map[string]any{"type": "object", "description": desc["mix"]},
			"channels": map[string]any{"type": "array", "description": desc["channels"], "items": map[string]any{
				"type": "object", "additionalProperties": false, "required": []string{"name", "part"},
				"properties": map[string]any{
					"name": map[string]any{"type": "string"}, "part": map[string]any{"enum": []string{"pulse", "triangle", "noise", "wave"}},
					"vol": map[string]any{"type": "number", "minimum": 0}, "pan": map[string]any{"type": "number", "minimum": -1, "maximum": 1},
					"cents": map[string]any{"type": "number"}, "sub": map[string]any{"type": "number", "minimum": 0},
					"duck": map[string]any{"type": "boolean"}, "note": map[string]any{"type": "string"},
					"send": map[string]any{"type": "object", "additionalProperties": false, "properties": map[string]any{
						"reverb": map[string]any{"type": "number", "minimum": 0}, "delay": map[string]any{"type": "number", "minimum": 0}}},
				}}},
			"fx":          map[string]any{"type": "object", "description": desc["fx"]},
			"instruments": map[string]any{"type": "object", "additionalProperties": inst, "description": desc["instruments"]},
			"waves":       map[string]any{"type": "object", "description": desc["waves"]},
			"phrases": map[string]any{"type": "object", "description": desc["phrases"],
				"additionalProperties": map[string]any{"type": "array", "maxItems": phraseSteps, "items": map[string]any{"type": "string"}}},
			"chains": map[string]any{"type": "object", "description": desc["chains"],
				"additionalProperties": map[string]any{"type": "array", "items": map[string]any{"type": "string"}}},
			"rows": map[string]any{"type": "array", "description": desc["rows"], "items": map[string]any{"type": "object"}},
		},
	}
}
