package px

// op の登録から作る文書: 端末の早見表・docs/px-ops.md・docs/pxsrc.schema.json・docs/colorgate.schema.json。
// 手で書かない（ずれたら fge px ops --check・fge px schema --check で落ちる）。

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/ababup1192/flix_game_engine/go/internal/pxlib"
)

const generatedNote = "生成物（bin/fge px ops --md）。直すのは go/internal/px の Op の構造体。"

// OpsTable は端末向けの 1 op 1 行の表。
func OpsTable() string {
	var b strings.Builder
	for _, op := range Ops() {
		fmt.Fprintf(&b, "%-14s %s\n", op.Name, op.Summary)
	}
	b.WriteString("（引数は fge px help <op>・書式は docs/pxsrc.schema.json）\n")
	return b.String()
}

// OpHelp は op 1 つの説明。
func OpHelp(op *Op) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s — %s\n技法: %s\n仕上げ: %s\n", op.Name, op.Summary, op.Technique, op.Finish)
	if len(op.Checks) > 0 {
		fmt.Fprintf(&b, "検査（部品の範囲で自動）: %s\n", strings.Join(op.Checks, "・"))
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

func defaultText(p Param) string {
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

// OpsMarkdown は docs/px-ops.md の中身（技法 → op → 仕上げの早見表と、op ごとの引数）。
func OpsMarkdown() string {
	var b strings.Builder
	b.WriteString("# fge px の op（技法 → op → 仕上げ）\n\n")
	b.WriteString("<!-- " + generatedNote + " -->\n\n")
	b.WriteString("指定（`<名前>.pxsrc.json`）の部品の `ops` に、上から順に当てる。書式は `docs/pxsrc.schema.json`、1 つの説明は `bin/fge px help <op>`。\n\n")
	b.WriteString("| 技法 | op | 何をするか | 仕上げ・検査 |\n|---|---|---|---|\n")
	for _, op := range Ops() {
		fmt.Fprintf(&b, "| %s | `%s` | %s | %s |\n", mdCell(op.Technique), op.Name, mdCell(op.Summary), mdCell(op.Finish))
	}
	b.WriteString("\n## 引数\n")
	for _, op := range Ops() {
		fmt.Fprintf(&b, "\n### `%s`\n\n", op.Name)
		if op.Whole {
			b.WriteString("格子全体に描く（部品の `at`・`use` の `at` でずらせない）。\n\n")
		}
		if len(op.Checks) > 0 {
			fmt.Fprintf(&b, "部品を描き終えたら、その範囲で検査 %s を回す。\n\n", "`"+strings.Join(op.Checks, "`・`")+"`")
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
	b.WriteString("\n## 検査\n\n| 検査 | 重さ | 何を見るか |\n|---|---|---|\n")
	for _, c := range Checks() {
		fmt.Fprintf(&b, "| `%s` | %s | %s |\n", c.Name, c.Level, mdCell(c.Summary))
	}
	return b.String()
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

func jsonValue(v any) any {
	switch t := v.(type) {
	case float64:
		return json.Number(strings.TrimSuffix(strings.TrimRight(fmt.Sprintf("%f", t), "0"), "."))
	case []any:
		out := make([]any, len(t))
		for i, e := range t {
			out[i] = jsonValue(e)
		}
		return out
	}
	return v
}

func paramSchema(p Param) *pxlib.Obj {
	var s *pxlib.Obj
	switch p.Type {
	case TNumber:
		s = obj("type", "number")
	case TInt:
		s = obj("type", "integer")
	case TString:
		s = obj("type", "string")
	case TBool:
		s = obj("type", "boolean")
	case TColor:
		s = ref("color")
	case TPoint, TPair:
		s = numArray(2)
	case TPoints:
		s = obj("type", "array", "items", numArray(2))
	case TShape:
		s = ref("shape")
	case TRows:
		s = obj("type", "array", "items", obj("type", "string"))
	case TColorMap:
		s = obj("type", "object", "additionalProperties", ref("color"))
	case TAxis:
		s = obj("enum", list("x", "y"))
	}
	out := obj("description", p.Summary)
	keys, vals := s.Items()
	for i, k := range keys {
		out.Set(k, vals[i])
	}
	if !p.Required && p.Default != nil {
		out.Set("default", jsonValue(p.Default))
	}
	return out
}

func opSchema(op *Op) *pxlib.Obj {
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

// SpecSchema は docs/pxsrc.schema.json の中身。
func SpecSchema() string {
	var ops []any
	for _, op := range Ops() {
		ops = append(ops, opSchema(op))
	}
	shape := obj("type", "object", "description",
		"形（符号付き距離）。鍵 1 つ: disk [cx,cy,r]・ellipse [cx,cy,rx,ry]・rect [x,y,w,h]・rbox [cx,cy,hw,hh,r]・capsule [ax,ay,bx,by,r]・"+
			"taper [ax,ay,bx,by,r0,r1]・poly [[x,y],…]・path [[x,y],…]+width・star [cx,cy,rOut,rIn]+n・mask [rows]+at・"+
			"union [形…]・inter [形…]・smoothUnion [形,形]+k・rounded 数+of・rotate 周+about+of・ref \"名前\"",
		"minProperties", json.Number("1"))
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
		))
	spriteS := obj("type", "object", "additionalProperties", false, "required", list("size", "parts", "frames"),
		"properties", obj(
			"note", obj("type", "string"),
			"size", obj("description", "[w, h]", "type", "array", "items", obj("type", "integer", "minimum", json.Number("1"), "maximum", json.Number("512")), "minItems", json.Number("2"), "maxItems", json.Number("2")),
			"anchor", obj("description", "足元などの基準点 [x, y]（省くと base のまま）", "type", "array", "items", obj("type", "integer"), "minItems", json.Number("2"), "maxItems", json.Number("2")),
			"ramp", obj("type", "string", "description", "部品の既定のランプ（ramps の名前）"),
			"parts", obj("type", "array", "items", ref("part"), "minItems", json.Number("1"), "description", "部品の平らな列。列の順が重ねる順"),
			"post", obj("type", "array", "items", ref("op"), "description", "全部の部品を描いた後に格子全体へ当てる op"),
			"frames", obj("type", "object", "minProperties", json.Number("1"),
				"description", "コマ名 → 部品 id を鍵にした JSON Merge Patch（変えないコマは {}・null で部品を外す）",
				"additionalProperties", obj("type", "object", "additionalProperties", obj("type", list("object", "null")))),
		))
	root := obj(
		"$schema", "http://json-schema.org/draft-07/schema#",
		"title", "ドット絵の指定 (*.pxsrc.json)",
		"description", "fge px build が読む。"+generatedNote,
		"type", "object",
		"additionalProperties", false,
		"required", list("version", "target", "sprites"),
		"properties", obj(
			"version", obj("const", json.Number(fmt.Sprint(SpecVersion))),
			"title", obj("type", "string", "label", "名前"),
			"note", obj("type", "string", "label", "メモ", "description", "いじると何が変わるか"),
			"target", obj("type", "string", "description", "書き出す sprite.json（atelier/ の下。assets/ は不可）"),
			"base", obj("type", "string", "description", "差し替える元の sprite.json（省くと target）"),
			"palette", obj("type", "string", "description", "色票の Doc（base が無いときの paletteFile）"),
			"gate", obj("type", "string", "description", "色の門の Doc（*.colorgate.json）。外れたら書き出さない"),
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
	return pxlib.DumpPy(root, "  ")
}

// GateSchema は docs/colorgate.schema.json の中身。
func GateSchema() string {
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
		"description", "fge px check と fge px build が読む。sprite.json のファイル名ごとに画風と例外を書く。生成物（bin/fge px schema）。直すのは go/internal/px/docs.go",
		"type", "object",
		"additionalProperties", false,
		"required", list("version", "styles", "files"),
		"properties", obj(
			"version", obj("const", json.Number(fmt.Sprint(GateVersion))),
			"note", obj("type", "string", "label", "メモ", "description", "いじると何が変わるか"),
			"styles", obj("type", "object", "label", "画風ごとの色の集合", "description", "名前 → 使ってよい色の出どころ（colors の列挙か from の Doc）。free は書かずに使える", "additionalProperties", style),
			"deny", obj("type", "array", "label", "どの画風でも使わない色", "items", obj("type", "object", "additionalProperties", false, "required", list("color", "why"), "properties", obj(
				"color", obj("type", "string", "pattern", "^#[0-9a-fA-F]{6}$"),
				"why", obj("type", "string", "description", "代わりにどうするか")))),
			"files", obj("type", "object", "label", "sprite.json ごとの決まり", "description", "鍵は sprite.json のファイル名（assets/ と atelier/ の同じ名前に効く）。ここに無いファイルは門で止まる", "additionalProperties", file),
		),
	)
	return pxlib.DumpPy(root, "  ")
}
