package docshape

import (
	"strings"
	"testing"

	"github.com/ababup1192/flix_game_engine/go/internal/lintconf"
)

func run(t *testing.T, root string, args ...string) (int, string) {
	t.Helper()
	t.Setenv("ENGINE", "") // 手元の ENGINE で engine の docs/ を拾わない
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, root, args)
	if err != nil {
		t.Fatal(err)
	}
	return code, out.String() + errOut.String()
}

const goodSchema = `{"version":1,"sections":{"speed":{"kind":"field","type":"float","label":"速さ"},
  "rows":{"kind":"list","label":"行","fields":{"name":{"type":"text","description":"名前"}}}}}`

// 外形の揃った Doc は通り、version・note の欠けをそれぞれ止める。
// Doc を渡しただけではスキーマの label は見ない (Doc の値 1 つでスキーマ全体をそろえさせない)。
func TestShapeFires(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"assets/hero.unit.json":   `{"version":1,"note":"速さを上げると走る","speed":1}`,
		"assets/unit.schema.json": goodSchema,
		"assets/bad.enemy.json":   `{"note":"  ","speed":1}`,
		"assets/enemy.schema.json": `{"version":1,"sections":{"speed":{"kind":"field","type":"float"},
		  "rows":{"kind":"list","label":"行","fields":{"hp":{"type":"int"}}}}}`,
	})
	if code, msg := run(t, root, "assets/hero.unit.json"); code != 0 {
		t.Fatalf("通るはず code=%d msg=%s", code, msg)
	}
	code, msg := run(t, root, "assets/bad.enemy.json")
	if code != 1 || strings.Count(msg, "!! ") != 2 || !strings.Contains(msg, "bad.enemy.json [version]") || !strings.Contains(msg, "bad.enemy.json [note]") {
		t.Fatalf("version と note の 2 件だけのはず code=%d msg=%s", code, msg)
	}
}

// スキーマの label はスキーマのファイル自体を渡したときだけ見る。
func TestLabelOnlyWhenSchemaGiven(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"assets/a.enemy.json": `{"version":1,"note":"敵"}`,
		"assets/enemy.schema.json": `{"version":1,"sections":{"speed":{"kind":"field","type":"float"},
		  "rows":{"kind":"list","label":"行","fields":{"hp":{"type":"int"}}}}}`,
	})
	if code, msg := run(t, root, "assets/a.enemy.json"); code != 0 {
		t.Fatalf("Doc だけなら通るはず code=%d msg=%s", code, msg)
	}
	code, msg := run(t, root, "assets/enemy.schema.json")
	if code != 1 || !strings.Contains(msg, "enemy.schema.json [label] rows.hp・speed") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// engine が持つ種類 (fx など) は engine の docs/<種類>.schema.json で足りる。
// engine の場所はゲームなら ENGINE → local.mk → Makefile の ENGINE、engine のリポ自身なら根。
func TestEngineDocsSchema(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"Makefile":                   "ENGINE ?= engine\ninclude $(ENGINE)/mk/game.mk\n",
		"engine/mk/game.mk":          "",
		"engine/docs/fx.schema.json": `{"type":"object"}`,
		"assets/town.fx.json":        `{"version":1,"note":"煙"}`,
		"assets/town.terrain.json":   `{"version":1,"note":"地形"}`,
	})
	code, msg := run(t, root, "assets/town.fx.json", "assets/town.terrain.json")
	if code != 1 || strings.Count(msg, "!! ") != 1 || !strings.Contains(msg, "town.terrain.json [schema]") {
		t.Fatalf("fx は engine の docs で通り terrain だけ止まるはず code=%d msg=%s", code, msg)
	}
	self := lintconf.TestRepo(t, Name, map[string]string{
		"mk/game.mk":                      "",
		"docs/fx.schema.json":             `{"type":"object"}`,
		"templates/s/assets/town.fx.json": `{"version":1,"note":"煙"}`,
	})
	if code, msg := run(t, self, "templates/s/assets/town.fx.json"); code != 0 {
		t.Fatalf("engine のリポ自身は根の docs を見るはず code=%d msg=%s", code, msg)
	}
}

// スキーマは project.json の editor.resources[] (テンプレートの穴 __W__ があっても読む) →
// 置き場から assets/ まで上った <種類>.schema.json の順で探し、無ければ止める。
// sprite・test の段・名前の段が 2 つの JSON は Doc として数えない。
func TestSchemaLookup(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"templates/s/project.json":              `{"w": __W__, "editor":{"resources":[{"pattern":"assets/sample.kind.json","schema":"assets/sample.schema.json"}]}}`,
		"templates/s/assets/sample.kind.json":   `{"version":1,"//":"見本"}`,
		"templates/s/assets/sample.schema.json": goodSchema,
		"assets/music/a.chip.json":              `{"version":1,"note":"曲"}`,
		"assets/chip.schema.json":               goodSchema,
		"assets/town.map.json":                  `{"version":1,"note":"町"}`,
		"assets/hero.sprite.json":               `{}`,
		"assets/card/layout.json":               `{}`,
		"test/assets/x.ui.json":                 `{}`,
	})
	code, msg := run(t, root, "templates/s/assets/sample.kind.json", "assets/music/a.chip.json", "assets/town.map.json",
		"assets/hero.sprite.json", "assets/card/layout.json", "test/assets/x.ui.json")
	if code != 1 || strings.Count(msg, "!! ") != 1 || !strings.Contains(msg, "assets/town.map.json [schema] スキーマ map.schema.json") {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}

// ゲームの除外で黙る (鍵は "パス::規則")。
func TestLocalExempt(t *testing.T) {
	root := lintconf.TestRepo(t, Name, map[string]string{
		"assets/gen.table.json":               `{"version":1,"note":"生成物"}`,
		"bin/lint-rules/doc-shape.local.json": `{"exempt":{"assets/gen.table.json::schema":"生成物で Studio に出さない"}}`,
	})
	if code, msg := run(t, root, "assets/gen.table.json"); code != 0 {
		t.Fatalf("code=%d msg=%s", code, msg)
	}
}
