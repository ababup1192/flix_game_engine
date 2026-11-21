package main

import "testing"

func testWasmIndex() wasmModuleIndex {
	return wasmModuleIndex{
		engine: map[string]string{"App": "engine_world", "App.Internal.Halt": "engine_world", "RenderPaint": "render_gl", "ShaderGen": "engine"},
		game:   map[string]bool{"PuzzleView": true},
	}
}

func TestWasmClassifyEngineModuleByLongestDecl(t *testing.T) {
	c := testWasmIndex().classify("$pkg$github$ababup1192$flix_game_engine.App.Internal.Halt.Def$pausedStep$1234::staticApply")
	if c.Package != "engine_world" || c.Module != "App.Internal.Halt" || c.Def != "App.Internal.Halt.pausedStep" {
		t.Fatalf("got %+v", c)
	}
}

func TestWasmClassifyGameClosure(t *testing.T) {
	c := testWasmIndex().classify("PuzzleView.Clo$draw$99::applyFrame")
	if c.Package != "ゲーム" || c.Def != "PuzzleView.draw" {
		t.Fatalf("got %+v", c)
	}
}

func TestWasmClassifyBareUnknownIsStdlib(t *testing.T) {
	if c := testWasmIndex().classify("RedBlackTree.Def$rotateBlack$932401::staticApply"); c.Package != "Flix 標準" {
		t.Fatalf("got %+v", c)
	}
}

func TestWasmClassifyEngineWebJava(t *testing.T) {
	if c := testWasmIndex().classify("fge.web.Browser::now"); c.Package != "engine_web" {
		t.Fatalf("got %+v", c)
	}
}

func TestWasmClassifyJavaRuntime(t *testing.T) {
	if c := testWasmIndex().classify("java.util.regex.Pattern::compile"); c.Package != "Java/TeaVM" {
		t.Fatalf("got %+v", c)
	}
}

func TestWasmFuncNamesReadsSubsectionOne(t *testing.T) {
	// subsection 1・2 本: 3 → "a"、5 → "bc"
	payload := []byte{1, 8, 2, 3, 1, 'a', 5, 2, 'b', 'c'}
	got, err := wasmFuncNames(payload)
	if err != nil || got[3] != "a" || got[5] != "bc" {
		t.Fatalf("got %v, %v", got, err)
	}
}
