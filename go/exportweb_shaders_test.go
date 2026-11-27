package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const scene3dEntry = `def main(): Unit \ IO = run Game.run() with WebLayer.withProject3d(".")`

func TestTwoDimensionalGameBakesNoShaders(t *testing.T) {
	plan, err := planShaderBake(t.TempDir(), `run Game.run() with WebLayer.withProject(".")`, false)
	if err != nil || plan.Bake {
		t.Fatalf("plan %+v err %v", plan, err)
	}
}

func TestSceneGameBakesFromTheRecord(t *testing.T) {
	game := t.TempDir()
	variants := filepath.Join(game, "web", "shader-variants.json")
	if err := os.MkdirAll(filepath.Dir(variants), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(variants, []byte(`{"version": 1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	plan, err := planShaderBake(game, scene3dEntry, false)
	if err != nil || !plan.Bake || plan.Missing || plan.Variants != variants {
		t.Fatalf("plan %+v err %v", plan, err)
	}
}

func TestSceneGameWithoutRecordStops(t *testing.T) {
	_, err := planShaderBake(t.TempDir(), scene3dEntry, false)
	if err == nil || !strings.Contains(err.Error(), "make run") {
		t.Fatalf("err %v", err)
	}
}

func TestDraftSceneGameWithoutRecordBakesTheDefaultSet(t *testing.T) {
	plan, err := planShaderBake(t.TempDir(), scene3dEntry, true)
	if err != nil || !plan.Bake || !plan.Missing {
		t.Fatalf("plan %+v err %v", plan, err)
	}
	if got := draftReasonsOf([]string{"赤"}, plan); len(got) != 2 || got[1] != shaderVariantsMissingReason {
		t.Fatalf("reasons %q", got)
	}
}
