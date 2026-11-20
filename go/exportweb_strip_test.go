package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestIsWebStripDefaultSchema(t *testing.T) {
	if !isWebStripDefault("assets/data/enemy.schema.json") {
		t.Error("サブフォルダの schema も外すはず")
	}
}

func TestIsWebStripDefaultSourceFileUpperCase(t *testing.T) {
	if !isWebStripDefault("assets/art/Hero.PSD") {
		t.Error("大文字の拡張子の元ファイルも外すはず")
	}
}

func TestIsWebStripDefaultKeepsDoc(t *testing.T) {
	if isWebStripDefault("assets/enemy.json") {
		t.Error("Doc は外さないはず")
	}
}

func stripFiles(t *testing.T, keepJSON string, embed webEmbedPlan, files ...string) (webStripPlan, error) {
	t.Helper()
	game := t.TempDir()
	for _, f := range files {
		writeTestFile(t, game, f, "12345")
	}
	keep, err := resolveWebKeep(json.RawMessage(keepJSON))
	if err != nil {
		t.Fatal(err)
	}
	return planWebStrip(game, append([]string{"project.json"}, files...), keep, embed)
}

func TestPlanWebStripDropsSchemaAndBlend(t *testing.T) {
	plan, _ := stripFiles(t, `{}`, webEmbedPlan{}, "assets/a.json", "assets/a.schema.json", "assets/m/x.blend")
	if !reflect.DeepEqual(plan.Stripped, []string{"assets/a.schema.json", "assets/m/x.blend"}) {
		t.Errorf("schema と元ファイルを外すはず: %v", plan.Stripped)
	}
}

func TestPlanWebStripCountsBytes(t *testing.T) {
	plan, _ := stripFiles(t, `{}`, webEmbedPlan{}, "assets/a.schema.json", "assets/b.schema.json")
	if plan.StrippedBytes != 10 {
		t.Errorf("外した量は元のファイルの和: %d", plan.StrippedBytes)
	}
}

func TestPlanWebStripKeepGlobRestores(t *testing.T) {
	plan, _ := stripFiles(t, `{"keep": ["assets/a.schema.json"]}`, webEmbedPlan{}, "assets/a.schema.json", "assets/b.schema.json")
	if !reflect.DeepEqual(plan.Stripped, []string{"assets/b.schema.json"}) {
		t.Errorf("web.keep に当たる物は残すはず: %v", plan.Stripped)
	}
}

func TestPlanWebStripKeepGlobWithoutHitIsError(t *testing.T) {
	if _, err := stripFiles(t, `{"keep": ["assets/nope.schema.json"]}`, webEmbedPlan{}, "assets/a.schema.json"); err == nil {
		t.Error("当たらない web.keep は誤りのはず")
	}
}

func TestPlanWebStripSkipsOmitted(t *testing.T) {
	plan, _ := stripFiles(t, `{}`, webEmbedPlan{Omitted: []string{"assets/a.schema.json"}}, "assets/a.schema.json")
	if len(plan.Stripped) != 0 {
		t.Errorf("web.omit が外す物は数えないはず: %v", plan.Stripped)
	}
}

func TestPlanWebStripNoticesText(t *testing.T) {
	plan, _ := stripFiles(t, `{}`, webEmbedPlan{}, "assets/credits.txt", "assets/notes.md")
	if !reflect.DeepEqual(plan.Noticed, []string{"assets/credits.txt", "assets/notes.md"}) {
		t.Errorf(".txt と .md は知らせるはず: %v", plan.Noticed)
	}
}

func TestPlanWebStripKeepsText(t *testing.T) {
	plan, _ := stripFiles(t, `{}`, webEmbedPlan{}, "assets/credits.txt")
	if len(plan.Stripped) != 0 {
		t.Errorf(".txt は外さないはず: %v", plan.Stripped)
	}
}

func TestPlanWebStripSkipsEmbedded(t *testing.T) {
	plan, _ := stripFiles(t, `{}`, webEmbedPlan{Embedded: []string{"assets/a.schema.json"}}, "assets/a.schema.json")
	if len(plan.Stripped) != 0 {
		t.Errorf("web.embed が扱う物は数えないはず: %v", plan.Stripped)
	}
}

func TestWebStripWithoutRemovesStripped(t *testing.T) {
	plan := webStripPlan{Stripped: []string{"assets/a.schema.json"}}
	got := plan.without([]string{"project.json", "assets/a.schema.json", "assets/a.json"})
	if !reflect.DeepEqual(got, []string{"project.json", "assets/a.json"}) {
		t.Errorf("外す物だけ抜くはず: %v", got)
	}
}
