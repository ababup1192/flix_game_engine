package px

// op の登録から作る文書: 端末の早見表・docs/px-ops.md・docs/pxsrc.schema.json・docs/colorgate.schema.json。
// 手で書かない（ずれたら fge px ops --check・fge px schema --check で落ちる。作り直すのは fge px ops --md・fge px schema --write）。

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

const generatedNote = "生成物（bin/fge px ops --md）。直すのは go/internal/px の Op の構造体。"

// opsTable は端末向けの 1 op 1 行の表。
func opsTable() string {
	var b strings.Builder
	for _, op := range allOps() {
		fmt.Fprintf(&b, "%-14s %s\n", op.Name, op.Summary)
	}
	b.WriteString("（引数は fge px help <op>・書式は docs/pxsrc.schema.json）\n")
	return b.String()
}

// opHelp は op 1 つの説明。
func opHelp(op *opDef) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s — %s\n技法: %s\n仕上げ: %s\n例: %s\n", op.Name, op.Summary, op.Technique, op.Finish, op.Example)
	if len(op.Checks) > 0 {
		fmt.Fprintf(&b, "検査（部品の範囲で自動）: %s\n", refsText(op.Checks, "・"))
	}
	if op.Whole {
		b.WriteString("格子全体に描く（部品の at・use の at でずらせない）\n")
	}
	b.WriteString("引数:\n")
	if len(op.Params) == 0 {
		b.WriteString("  （無し。{} と書く）\n")
	}
	for _, p := range op.Params {
		fmt.Fprintf(&b, "  %-12s %-8s %s%s\n", p.Name, p.Type, p.Summary, defaultText(p))
	}
	return b.String()
}

func defaultText(p param) string {
	if r := rangeText(p); r != "" {
		return "（" + r + "）" + defaultOnly(p)
	}
	return defaultOnly(p)
}

func defaultOnly(p param) string {
	if p.Required {
		return "（必須）"
	}
	if p.Default == nil {
		return ""
	}
	data, _ := json.Marshal(p.Default)
	return "（省くと " + string(data) + "）"
}

func mdCell(s string) string { return strings.ReplaceAll(s, "|", "\\|") }

// opsMarkdown は docs/px-ops.md の中身（技法 → op → 仕上げの早見表と、op ごとの引数）。
func opsMarkdown() string {
	var b strings.Builder
	b.WriteString("# fge px の op（技法 → op → 仕上げ）\n\n")
	b.WriteString("<!-- " + generatedNote + " -->\n\n")
	b.WriteString("指定（`<名前>.pxsrc.json`）の部品の `ops` に、上から順に当てる。書式は `docs/pxsrc.schema.json`、1 つの説明は `bin/fge px help <op>`。\n\n")
	b.WriteString("## 早見表（描く物・技法 → op → 仕上げ）\n\n")
	b.WriteString("| 描く物・技法 | op（→ は順に当てる・/ はどれか） | 仕上げ・検査 |\n|---|---|---|\n")
	for _, r := range quickRows {
		fmt.Fprintf(&b, "| %s | %s | %s |\n", mdCell(r.What), quickOps(r), mdCell(quickFinish(r)))
	}
	b.WriteString("\n既定値はどれも仮置き（見本 10 題と作品 5 作の大きい見比べで決め直す）。強さは各 op の引数で選び、使わない技法は書かない。\n")
	b.WriteString("\n## op の一覧\n\n| 技法 | op | 何をするか | 仕上げ・検査 |\n|---|---|---|---|\n")
	var quiet []string
	for _, op := range allOps() {
		if op.Quiet {
			quiet = append(quiet, "`"+op.Name+"`")
			continue
		}
		fmt.Fprintf(&b, "| %s | `%s` | %s | %s |\n", mdCell(op.Technique), op.Name, mdCell(op.Summary), mdCell(op.Finish))
	}
	fmt.Fprintf(&b, "\nほかの op（16px 前後の見比べで差が出なかった物。既定にしない。使う時は `bin/fge px help <op>`）: %s\n", strings.Join(quiet, "・"))
	b.WriteString("\n## 動きのコマ数の目安\n\n待機 4〜8・歩き 6〜8・走り 4〜8・攻撃 8〜12・倒れ 6〜8（攻撃は少なすぎても多すぎても締まらない。frames は「始めの姿勢 → 順に起きること → 終わり方」の順に並べる）。\n")
	b.WriteString("\n## 材質（部品の `material`）\n\n手順を覚えずに `\"material\": \"metal\"` と書く。中身は既存の op の並びで、部品の `ops` の前に差し込む。\n\n")
	b.WriteString("| 材質 | 何をするか | 引数 | 技法 | 仕上げ |\n|---|---|---|---|---|\n")
	for _, m := range allMaterials() {
		var ps []string
		for _, p := range m.Params {
			ps = append(ps, "`"+p.Name+"` "+p.Summary+defaultText(p))
		}
		fmt.Fprintf(&b, "| `%s` | %s | %s | %s | %s |\n", m.Name, mdCell(m.Summary), mdCell(strings.Join(ps, "・")), mdCell(m.Technique), mdCell(m.Finish))
	}
	b.WriteString("\n## 歩きの姿勢（frames の `pose`）\n\n右を向いた横向き 1 方向のコマを作る（4 方向は carve と adopt）。役は `roles` で部品 id に当てる。角度は度・正で時計回り。\n\n")
	b.WriteString("| 姿勢 | 役ごとの動き |\n|---|---|\n")
	for _, name := range poseNames() {
		var ms []string
		for _, role := range poseRoleNames() {
			if mv, ok := poses[name][role]; ok {
				ms = append(ms, fmt.Sprintf("%s 回転 %g・ずらし [%d, %d]", role, mv.Rotate, mv.At[0], mv.At[1]))
			}
		}
		fmt.Fprintf(&b, "| `%s` | %s |\n", name, strings.Join(ms, "・"))
	}
	b.WriteString(starMarkdown())
	b.WriteString("\n## 引数\n")
	for _, op := range allOps() {
		if op.Quiet {
			continue
		}
		fmt.Fprintf(&b, "\n### `%s`\n\n例: `%s`\n\n", op.Name, op.Example)
		if op.Whole {
			b.WriteString("格子全体に描く（部品の `at`・`use` の `at` でずらせない）。\n\n")
		}
		if len(op.Checks) > 0 {
			fmt.Fprintf(&b, "部品を描き終えたら、その範囲で検査 %s を回す。\n\n", "`"+refsText(op.Checks, "`・`")+"`")
		}
		if len(op.Params) == 0 {
			b.WriteString("引数は無い（`{}` と書く）。\n")
			continue
		}
		b.WriteString("| 引数 | 型 | 説明 |\n|---|---|---|\n")
		for _, p := range op.Params {
			fmt.Fprintf(&b, "| `%s` | %s | %s%s |\n", p.Name, p.Type, mdCell(p.Summary), mdCell(defaultText(p)))
		}
	}
	b.WriteString("\n## 形\n\n部品の `shape` と op の `shape` に書く。鍵 1 つで種類を決め、ほかの鍵は種類ごとの引数。\n\n")
	b.WriteString("座標の決まり: 形は画素 (x, y) の中心 (x+0.5, y+0.5) で中か外かを見る。`disk` の中心が整数なら画素の角（偶数の幅の丸）・+0.5 で画素の真ん中（奇数の幅）。`rect` [x, y, w, h] は x..x+w-1・y..y+h-1 の画素。部品の `pivot` は逆に整数が画素の中心・.5 が境目。\n\n")
	b.WriteString("| 形 | 値 | ほかの鍵 | 何か |\n|---|---|---|---|\n")
	for _, k := range allShapes() {
		var extra []string
		for _, p := range k.Extra {
			extra = append(extra, "`"+p.Name+"` "+p.Summary+defaultText(p))
		}
		fmt.Fprintf(&b, "| `%s` | %s | %s | %s |\n", k.Name, mdCell(k.Main.Summary), mdCell(strings.Join(extra, "・")), mdCell(k.Summary))
	}
	b.WriteString(styleMarkdown())
	b.WriteString("\n## 検査\n\n| 検査 | 重さ | 何を見るか |\n|---|---|---|\n")
	for _, c := range allChecks() {
		fmt.Fprintf(&b, "| `%s` | %s | %s |\n", c.Name, c.Level, mdCell(c.Summary))
	}
	return b.String()
}

// quickRow は早見表の 1 行（描く物・技法 → op）。Chain なら上から順に当てる並び、でなければどれか 1 つ。
// 仕上げは op の Finish から取る（材質は下の材質の表）。
type quickRow struct {
	What  string
	Ops   []string
	Chain bool
}

// quickRows は早見表の上の段（20 行まで。差が出ない・使われない行は外す。技法カード 1 節と早見表の案 3 節から）。
var quickRows = []quickRow{
	{"光と陰（小物の面）", []string{"directional"}, false},
	{"丸い体・キャラ", []string{"shade_parts"}, false},
	{"手前の物が落とす影", []string{"shade_mask"}, false},
	{"1px の線・ひげ・髪の線", []string{"line"}, false},
	{"金属・石・木・布・葉", []string{"material"}, false},
	{"空・斜面の階調・境目のディザ", []string{"gradient_fill"}, false},
	{"色票に無い中間の色", []string{"dither_pair"}, false},
	{"葉・石の斑・草のタイル", []string{"scatter_clusters"}, false},
	{"揺れ・呼吸・弾み（on の子も付いていく）・なびく旗（形 flag の t をコマで進める）", []string{"sway", "shape:flag"}, false},
	{"水・滝・流れ（波頭を 1px ずつ流す）", []string{"wave_shift"}, false},
	{"煉瓦・瓦・石積みの目地（段ごとに半分ずらす。一人称・遠近の壁は quad）", []string{"courses"}, false},
	{"葉の玉を重ねた木・茂み・鉢植え", []string{"canopy"}, false},
	{"字・表・窓の枠・体力のバー（ラベル・HUD・メニュー。5x7・太字 bold6x8。階調と縁は形 text に塗る）", []string{"text", "table", "frame", "bar", "shape:text"}, false},
	{"光のにじみ（窓・街灯・夕日・ネオン。加算の層は 0 段で fill してから）", []string{"glow"}, false},
	{"縦横のスクロール（雲・雨・海の光。写しを並べてループ）", []string{"part:scroll", "gradient_fill"}, true},
	{"同じ形を並べる・写す（弾の輪・編隊・鋲・左右対称の機体・影）", []string{"shape:polar", "shape:array", "shape:poly", "shape:translate"}, false},
	{"機種のパレットの本数・縦長の画素（16 色 × 4 本・PC-88 の [1, 2]）", []string{"style:palettes", "style:pixel"}, false},
}

// quickNames は早見表の op でない名前（形・部品の鍵・機種の決まり）の読み方。
var quickNames = map[string]string{
	"part:scroll":    "部品の `scroll`",
	"style:palettes": "style の `palettes`",
	"style:pixel":    "style の `pixel`",
}

func quickOps(r quickRow) string {
	sep := " / "
	if r.Chain {
		sep = " → "
	}
	var names []string
	for _, n := range r.Ops {
		switch {
		case quickNames[n] != "":
			names = append(names, quickNames[n])
		case strings.HasPrefix(n, "shape:"):
			names = append(names, "形 `"+strings.TrimPrefix(n, "shape:")+"`")
		default:
			names = append(names, "`"+n+"`")
		}
	}
	return strings.Join(names, sep)
}

// quickFinish は行の op の Finish を重ねずにつなぐ（— は飛ばす）。
func quickFinish(r quickRow) string {
	seen := map[string]bool{}
	var out []string
	for _, name := range r.Ops {
		f := "材質ごと（下の材質の表）"
		if op, ok := lookupOp(name); ok {
			f = op.Finish
		} else if strings.Contains(name, ":") {
			f = "—"
		}
		if f != "—" && !seen[f] {
			seen[f] = true
			out = append(out, f)
		}
	}
	if len(out) == 0 {
		return "—"
	}
	return strings.Join(out, " / ")
}

func materialNames() string {
	var names []string
	for _, m := range allMaterials() {
		names = append(names, m.Name)
	}
	return strings.Join(names, "・")
}

func materialEnum() []any {
	var out []any
	for _, m := range allMaterials() {
		out = append(out, m.Name)
	}
	return out
}

// --- スキーマ -------------------------------------------------------------

func obj(kv ...any) *pxlib.Obj {
	o := pxlib.NewObj()
	for i := 0; i+1 < len(kv); i += 2 {
		o.Set(kv[i].(string), kv[i+1])
	}
	return o
}

func list(v ...any) []any { return v }

func ref(name string) *pxlib.Obj { return obj("$ref", "#/definitions/"+name) }

func numArray(n int) *pxlib.Obj {
	return obj("type", "array", "items", obj("type", "number"), "minItems", json.Number(fmt.Sprint(n)), "maxItems", json.Number(fmt.Sprint(n)))
}

func intArray(n int) *pxlib.Obj {
	return obj("type", "array", "items", obj("type", "integer"), "minItems", json.Number(fmt.Sprint(n)), "maxItems", json.Number(fmt.Sprint(n)))
}

func count(n int) json.Number { return json.Number(fmt.Sprint(n)) }

// withLen は配列の長さの範囲を足す。
func withLen(s *pxlib.Obj, p param) *pxlib.Obj {
	if p.Min > 0 {
		s.Set("minItems", count(p.Min))
	}
	if p.Max > 0 {
		s.Set("maxItems", count(p.Max))
	}
	return s
}

func jsonValue(v any) any {
	switch t := v.(type) {
	case float64:
		return json.Number(strconv.FormatFloat(t, 'g', -1, 64))
	case []any:
		out := make([]any, len(t))
		for i, e := range t {
			out[i] = jsonValue(e)
		}
		return out
	}
	return v
}

func paramSchema(p param) *pxlib.Obj {
	var s *pxlib.Obj
	switch p.Type {
	case tNumber:
		s = obj("type", "number")
	case tInt:
		s = obj("type", "integer")
	case tString:
		s = obj("type", "string")
	case tBool:
		s = obj("type", "boolean")
	case tColor:
		s = ref("color")
	case tPoint:
		s = intArray(2)
	case tPair:
		s = numArray(2)
	case tPoints:
		s = withLen(obj("type", "array", "items", intArray(2)), p)
	case tNums:
		s = numArray(p.Len)
		if p.Len < 0 {
			s = withLen(obj("type", "array", "items", obj("type", "number")), p)
		}
	case tVecs:
		s = withLen(obj("type", "array", "items", numArray(2)), p)
	case tShape:
		s = ref("shape")
	case tShapes:
		s = withLen(obj("type", "array", "items", ref("shape")), p)
	case tRows:
		s = withLen(obj("type", "array", "items", obj("type", "string")), p)
	case tColorMap:
		s = obj("type", "object", "additionalProperties", ref("color"))
	case tAxis:
		s = obj("enum", list("x", "y"))
	case tCircles:
		s = withLen(obj("type", "array", "items", numArray(3)), p)
	case tCells:
		cell := obj("oneOf", list(obj("type", "string"),
			obj("type", "array", "items", list(obj("type", "string"), ref("color")), "minItems", json.Number("2"), "maxItems", json.Number("2"))))
		s = withLen(obj("type", "array", "items", obj("type", "array", "items", cell)), p)
	}
	out := obj("description", p.Summary)
	keys, vals := s.Items()
	for i, k := range keys {
		out.Set(k, vals[i])
	}
	if p.Lo != nil {
		out.Set("minimum", json.Number(strconv.FormatFloat(*p.Lo, 'g', -1, 64)))
	}
	if p.Hi != nil {
		out.Set("maximum", json.Number(strconv.FormatFloat(*p.Hi, 'g', -1, 64)))
	}
	if !p.Required && p.Default != nil {
		out.Set("default", jsonValue(p.Default))
	}
	return out
}

func opSchema(op *opDef) *pxlib.Obj {
	props := pxlib.NewObj()
	var req []any
	for _, p := range op.Params {
		props.Set(p.Name, paramSchema(p))
		if p.Required {
			req = append(req, p.Name)
		}
	}
	args := obj("type", "object", "additionalProperties", false, "properties", props)
	if len(req) > 0 {
		args.Set("required", req)
	}
	return obj("type", "object", "description", op.Summary, "additionalProperties", false,
		"required", list(op.Name), "properties", obj(op.Name, args))
}

// specSchema は docs/pxsrc.schema.json の中身。
func specSchema() string {
	var ops []any
	for _, op := range allOps() {
		ops = append(ops, opSchema(op))
	}
	var shapes []any
	for _, k := range allShapes() {
		props := obj(k.Name, paramSchema(k.Main))
		req := list(k.Name)
		for _, p := range k.Extra {
			props.Set(p.Name, paramSchema(p))
			if p.Required {
				req = append(req, p.Name)
			}
		}
		shapes = append(shapes, obj("type", "object", "description", k.Summary, "additionalProperties", false,
			"required", req, "properties", props))
	}
	shapes = append(shapes, obj("type", "string", "description", "shapes の名前（{\"ref\": 名前} の短い書き方）"))
	shape := obj("description", "形（符号付き距離。画素の中心が内側なら塗る）。shapes の名前の文字列でも書ける", "oneOf", shapes)
	color := obj("type", "string", "description",
		"色: ink・shade・mid・light（部品のランプの 0〜3 段）・ramp[i]（ramp[-1] は一番明るい段）・gloss（light.gloss）・色キー・\"\"（透明）")
	part := obj("type", "object", "additionalProperties", false, "required", list("id"),
		"properties", obj(
			"id", obj("type", "string", "pattern", "^[A-Za-z][A-Za-z0-9_]*$", "description", "部品の名前（コマの patch と違反の場所で使う）"),
			"on", obj("type", "string", "description", "親の部品 id（この部品より前の列にある物）"),
			"clip", obj("type", "boolean", "description", "true で親の塊の中だけに描く（on と組）"),
			"shape", ref("shape"),
			"ramp", obj("type", "string", "description", "ramps の名前（省くとスプライトの ramp）"),
			"at", obj("description", "部品をずらす量 [dx, dy]", "type", "array", "items", obj("type", "integer"), "minItems", json.Number("2"), "maxItems", json.Number("2")),
			"ops", obj("type", "array", "items", ref("op"), "description", "上から順に当てる op"),
			"note", obj("type", "string"),
			"material", obj("description", "材質のレシピ（"+materialNames()+"）。名前か {名前: {引数}}。ops の前に op の並びを差し込む",
				"oneOf", list(obj("enum", materialEnum()), obj("type", "object", "minProperties", json.Number("1"), "maxProperties", json.Number("1")))),
			"rotate", obj("type", "number", "description", "部品を回す角度（度。正で時計回り。rotsprite の考え方で色を足さない）"),
			"emissive", obj("type", "boolean", "description", "true で自分で光る部品（窓の灯り・炎・画面）。光の向きの検査 light-dir・pillow の対象から外す"),
			"scroll", obj("description", "縦横のスクロール: 形を period おきに写して格子を埋め、コマ i で at に speed·i を足す（period の既定は speed × コマ数でループが継ぎ目なく閉じる）。写しを 1 つずつ塗るなら gradient_fill の per: component",
				"type", "object", "additionalProperties", false, "required", list("speed"), "properties", obj(
					"speed", obj("description", "1 コマにずらす画素 [dx, dy]", "type", "array", "items", obj("type", "integer"), "minItems", json.Number("2"), "maxItems", json.Number("2")),
					"period", obj("description", "写しの間隔 [px, py]（0 はその向きに写さない。省くと speed × コマ数）", "type", "array", "items", obj("type", "integer", "minimum", json.Number("0")), "minItems", json.Number("2"), "maxItems", json.Number("2")))),
			"pivot", obj("description", "回す中心の画素 [x, y]（整数は画素の中心・.5 は画素の境目。省くと塊の上の真ん中）", "type", "array", "items", obj("type", "number", "multipleOf", json.Number("0.5")), "minItems", json.Number("2"), "maxItems", json.Number("2")),
		))
	spriteS := obj("type", "object", "additionalProperties", false, "required", list("size", "parts"),
		"properties", obj(
			"note", obj("type", "string"),
			"size", obj("description", "[w, h]", "type", "array", "items", obj("type", "integer", "minimum", json.Number("1"), "maximum", json.Number(strconv.Itoa(maxGrid))), "minItems", json.Number("2"), "maxItems", json.Number("2")),
			"anchor", obj("description", "足元などの基準点 [x, y]（省くと base のまま）", "type", "array", "items", obj("type", "integer"), "minItems", json.Number("2"), "maxItems", json.Number("2")),
			"ramp", obj("type", "string", "description", "部品の既定のランプ（ramps の名前）"),
			"parts", obj("type", "array", "items", ref("part"), "minItems", json.Number("1"), "description", "部品の平らな列。列の順が重ねる順"),
			"post", obj("type", "array", "items", ref("op"), "description", "全部の部品を描いた後に格子全体へ当てる op"),
			"frames", obj("type", "object", "minProperties", json.Number("1"),
				"description", "コマ名 → 部品 id を鍵にした JSON Merge Patch（1 枚絵は省ける = {\"f0\": {}}・変えないコマは {}・null で部品を外す・shape は丸ごと替わる）。on の子は親の at と動きに付いていく。{\"pose\": 姿勢, \"flip\": true, \"parts\": {id: patch}} で歩きの姿勢（"+strings.Join(poseNames(), "・")+"。flip は手前と奥の手足を入れ替えた逆の姿勢）から作る。並べる順は「始めの姿勢 → 順に起きること → 終わり方（待機へ戻る・ループ・倒れる）」",
				"additionalProperties", obj("type", "object", "additionalProperties", obj("type", list("object", "null", "string", "boolean")))),
			"variants", obj("type", "object", "additionalProperties", false, "required", list("seeds"), "description", "変種: seed ごとにコマを <コマ名>_v<seed> で書き出す（散らす op は seed だけで決まる）",
				"properties", obj("seeds", obj("type", "array", "items", obj("type", "integer", "minimum", json.Number("0")), "minItems", json.Number("1")))),
			"roles", obj("type", "object", "description", "歩きの姿勢の役 → 部品 id（"+strings.Join(poseRoleNames(), "・")+"。省くと役と同じ id の部品）", "additionalProperties", obj("type", "string")),
			"anim", obj("type", "boolean", "description", "コマ列の検査 anim を回すか（省くと動きの op・pose・rotate があれば回す）"),
		))
	root := obj(
		"$schema", "http://json-schema.org/draft-07/schema#",
		"title", "ドット絵の指定 (*.pxsrc.json)",
		"description", "fge px build が読む。"+generatedNote,
		"type", "object",
		"additionalProperties", false,
		"required", list("version", "target", "sprites"),
		"properties", obj(
			"version", obj("const", json.Number(fmt.Sprint(specVersion))),
			"title", obj("type", "string", "label", "名前"),
			"note", obj("type", "string", "label", "メモ", "description", "いじると何が変わるか"),
			"target", obj("type", "string", "description", "書き出す sprite.json（atelier/ の下。assets/ は不可）"),
			"base", obj("type", "string", "description", "差し替える元の sprite.json（省くと target）"),
			"palette", obj("type", "string", "description", "色票の Doc（base が無いときの paletteFile）"),
			"gate", obj("type", "string", "description", "色の門の Doc（*.colorgate.json）。外れたら書き出さない"),
			"indent", obj("description", "書き出す字下げ（\"tab\" か空白の数。省くと base の字面に合わせる）", "oneOf", list(obj("const", "tab"), obj("type", "integer", "minimum", json.Number("1"), "maximum", json.Number("8")))),
			"style", obj("type", "string", "description", "機種の決まり（bin/lint-rules/px.json の styles: gb4・nes・snes・pc98・modern など。か *.pxstyle.json）。色の集合・色数・升目の色数・RGB の段数を検査 style で縛る。色の門（gate）の画風の上に乗る縛りで、門の画風は外さない"),
			"light", obj("type", "object", "additionalProperties", false, "description", "光（Doc に 1 か所だけ。op はここを読む）",
				"properties", obj(
					"dir", obj("type", "array", "items", obj("type", "number"), "minItems", json.Number("2"), "maxItems", json.Number("3"), "description", "光の来る向き [x, y] か [x, y, 高さ]（左上は [-1, -1]）", "default", list(json.Number("-1"), json.Number("-1"))),
					"gloss", obj("type", "string", "description", "つやの色キー（色の名前 gloss）"),
					"ground", obj("type", "string", "description", "絵を置く地の色（色キーか #rrggbb。見本の地と ground-contrast の検査）"),
					"note", obj("type", "string"),
				)),
			"ramps", obj("type", "object", "description", "名前 → 色キーの並び（暗 → 明）", "additionalProperties", obj("type", "array", "items", obj("type", "string"), "minItems", json.Number("1"))),
			"shapes", obj("type", "object", "description", "名前 → 形（{\"ref\": 名前} で引く）", "additionalProperties", ref("shape")),
			"macros", obj("type", "object", "description", "名前 → op の列（op use で差し込む）", "additionalProperties", obj("type", "array", "items", ref("op"))),
			"sprites", obj("type", "object", "minProperties", json.Number("1"), "additionalProperties", ref("sprite")),
		),
		"definitions", obj("shape", shape, "color", color, "op", obj("oneOf", ops), "part", part, "sprite", spriteS),
	)
	return pxlib.ToJSON(root, "  ")
}

// gateSchema は docs/colorgate.schema.json の中身。
func gateSchema() string {
	allow := obj("type", "object", "additionalProperties", false, "required", list("keys", "why"), "properties", obj(
		"keys", obj("type", "string", "label", "色の名前（正規表現）", "description", "例 ^tile"),
		"why", obj("type", "string", "label", "理由", "description", "画風の文書にある例外と同じ物。理由の無い例外は足さない"),
	))
	file := obj("type", "object", "additionalProperties", false, "required", list("style"), "properties", obj(
		"style", obj("type", "string", "label", "画風", "description", "styles の名前か free（この決まりの外。理由を why に）"),
		"why", obj("type", "string", "label", "理由", "description", "free にした理由"),
		"allow", obj("type", "array", "label", "例外にする色の名前", "items", allow),
		"known", obj("type", "object", "label", "既存の違反", "additionalProperties", false,
			"description", "採用した絵で決まりを破っている色の名前を 1 つずつ列挙する（正規表現にしない）。門は通すが件数を毎回出す。直したら消す。新しい絵の色は足さない",
			"properties", obj("keys", obj("type", "array", "items", obj("type", "string")), "why", obj("type", "string"))),
	))
	style := obj("type", "object", "additionalProperties", false, "required", list("label"), "properties", obj(
		"label", obj("type", "string", "label", "外れた色の言い方", "description", "例 Pear36 の外"),
		"colors", obj("type", "object", "label", "色の列挙", "description", "色の名前 → #rrggbb", "additionalProperties", obj("type", "string", "pattern", "^#[0-9a-fA-F]{6}$")),
		"from", obj("type", "string", "label", "色を引く Doc", "description", "ゲームのルートからの相対（例 assets/x.theme.json）"),
		"path", obj("type", "string", "label", "Doc の中の場所", "description", "\".\" 区切り（例 night）。省くと一番外"),
		"keys", obj("type", "string", "label", "引く色の名前", "description", "正規表現（例 ^pear）。省くと全部"),
	))
	root := obj(
		"$schema", "http://json-schema.org/draft-07/schema#",
		"title", "ドット絵の色の門 (*.colorgate.json)",
		"description", "fge px check と fge px build が読む。sprite.json のファイル名ごとに画風と例外を書く。生成物（bin/fge px schema --write）。直すのは go/internal/px/docs.go",
		"type", "object",
		"additionalProperties", false,
		"required", list("version", "styles", "files"),
		"properties", obj(
			"version", obj("const", json.Number(fmt.Sprint(gateVersion))),
			"note", obj("type", "string", "label", "メモ", "description", "いじると何が変わるか"),
			"default", obj("type", "string", "label", "既定の画風", "description", "files に無い新しい sprite.json に当てる画風（styles の名前）。画風を決めるのは門だけ（pxsrc の style は機種の決まりの上乗せで、門の画風は外れない）。省くと files に無い物は止める"),
			"styles", obj("type", "object", "label", "画風ごとの色の集合", "description", "名前 → 使ってよい色の出どころ（colors の列挙か from の Doc）。free は書かずに使える", "additionalProperties", style),
			"deny", obj("type", "array", "label", "どの画風でも使わない色", "items", obj("type", "object", "additionalProperties", false, "required", list("color", "why"), "properties", obj(
				"color", obj("type", "string", "pattern", "^#[0-9a-fA-F]{6}$"),
				"why", obj("type", "string", "description", "代わりにどうするか")))),
			"files", obj("type", "object", "label", "sprite.json ごとの決まり", "description", "鍵は sprite.json のファイル名（assets/ と atelier/ の同じ名前に効く）。ここに無いファイルは default の画風で見る（default も無ければ止まる）", "additionalProperties", file),
		),
	)
	return pxlib.ToJSON(root, "  ")
}

func refsText(refs []checkRef, sep string) string {
	parts := make([]string, len(refs))
	for i, r := range refs {
		parts[i] = r.String()
	}
	return strings.Join(parts, sep)
}

// styleMarkdown は docs/px-ops.md の「機種（style）」の節。
func styleMarkdown() string {
	return "\n## 機種（style）\n\n" +
		"pxsrc の一番外に `\"style\": \"snes\"` と名前で書くと `bin/lint-rules/px.json` の styles から引き（`bin/fge px help` に一覧）、" +
		"`\"style\": \"md.pxstyle.json\"` と書くと自前の Doc を読む（台本からは台本のフォルダが起点）。どの鍵も 0 と省略は見ない。\n\n" +
		"| 鍵 | 何を縛るか |\n|---|---|\n" +
		"| `label`・`note` | 名前と説明（違反の文に出る） |\n" +
		"| `colors` | 使える色（色キー → `#rrggbb`。色票に足され、その色キーで描ける） |\n" +
		"| `channelLevels` | RGB の 1 チャンネルの段数（8 = 3 bit の MD・32 = 5 bit の SFC・16 = PC-98） |\n" +
		"| `maxColors` | 1 コマの色数（透明を除く） |\n" +
		"| `tile`・`maxTileColors` | 升目の大きさ [w, h] と升目ごとの色数 |\n" +
		"| `palettes` | `{\"count\": 4, \"size\": 15}`: 1 コマの色を count 本 × size 色に割り付けられるか（色の多い単位から順に入る本へ入れる。単位は `tile` [w, h] を書けば升目・無ければ部品）。入らないと言い切れる時は gate・貪欲法の取りこぼしかもしれない時は advice |\n" +
		"| `maxSize` | 絵の最大の大きさ [w, h]（1 枚の格子は 1024 まで） |\n" +
		"| `pixel` | 画素の横:縦（PC-88 の 200 ライン = `[1, 2]`）。縛りではなく `--png` の PNG・GIF をこの比で引き伸ばす（sprite.json は 1:1 のまま） |\n\n" +
		"色の名前 `ink`・`shade`・`mid`・`light` は部品のランプの 0・1・2・3 段（暗 → 明。5 段以上のランプでも light は 3 段目で、一番明るい段は `ramp[-1]`）。ランプの無い部品では同じ名前の色キー。\n"
}
