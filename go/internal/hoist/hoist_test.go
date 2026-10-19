package hoist

// 何を守るか: 0.50 で踏んだ形（関数を返す def・shadeAll / forEachWithIndex のラムダが使う
// 呼び出しの結果や record の欄の let）を拾うこと。onceOutsideLoop を通した物・効果のある let・
// 軽い呼び出しだけの let・ラムダの中の let は鳴らさないこと。除外と古い除外の扱い。

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testRules() *Rules {
	return &Rules{
		ScopeSuffixes: []string{".flix"},
		FnReturnScope: []string{"engine/"},
		LoopCalls:     []string{"shadeAll", "Array.forEachWithIndex"},
		Once:          "onceOutsideLoop",
		NotMoved:      map[string]bool{"Int32.max": true},
		Effectful:     map[string]bool{"Array.toVector": true},
		Exempt:        map[string]string{},
	}
}

func found(path, src string) string {
	var out []string
	for _, h := range Scan(path, src, testRules()) {
		out = append(out, h.Kind+":"+h.Def+":"+h.Name)
	}
	return strings.Join(out, " ")
}

func TestFunctionReturningDefFires(t *testing.T) {
	src := "    pub def compileSpec(spec: Spec): (Vec2, Float64) -> Color =\n" +
		"        let f = build(spec);\n        (uv, t) -> f(uv, t)\n"
	if got := found("engine/src/A.flix", src); got != "fn-return:compileSpec:" {
		t.Fatalf("got %q", got)
	}
}

func TestFunctionReturningDefOutsideScopeIsQuiet(t *testing.T) {
	src := "    pub def f(x: Int32): Int32 -> Int32 =\n        y -> x + y\n"
	if got := found("game/src/A.flix", src); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestEffectOperationWithoutBodyIsQuiet(t *testing.T) {
	src := "eff Shader {\n    def build(spec: Spec): Unit\n}\n\npub mod X {\n    def g(): Int32 = 1\n}\n"
	if got := found("engine/src/A.flix", src); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestLoopLetFires(t *testing.T) {
	for _, tc := range []struct{ src, want string }{
		// 0.50 の drawSurface の形: 組み立てた関数をラムダに名前を付けて shadeAll へ
		{"    def drawSurface(s: SurfaceCmd): Unit =\n" +
			"        let eval = ShaderEval.compileSpec(s#spec);\n" +
			"        let pixelOf = i -> eval(i);\n" +
			"        shadeAll(n, pixelOf)\n", "loop-let:drawSurface:eval"},
		// record の欄を読んだ let をラムダに直に書く
		{"    def drawGrad(p: Poly): Unit =\n" +
			"        let blend = p#blend;\n" +
			"        Array.forEachWithIndex((i, dst) -> put(blendPixel(blend, dst), i), buf)\n", "loop-let:drawGrad:blend"},
		// タプルで分解した名前も見る
		{"    def f(s: S): Unit =\n" +
			"        let (ox, oy) = (s#x, s#y);\n" +
			"        shadeAll(n, i -> ox + Int32.toFloat64(i))\n", "loop-let:f:ox"},
	} {
		if got := found("engine_tools/src/A.flix", tc.src); got != tc.want {
			t.Fatalf("%q: got %q want %q", tc.src, got, tc.want)
		}
	}
}

func TestSafeLetsAreQuiet(t *testing.T) {
	for _, src := range []string{
		// onceOutsideLoop を通した
		"    def f(s: S): Unit = region rc {\n        let compiled = onceOutsideLoop(rc, compile(s#spec));\n" +
			"        shadeAll(n, i -> eval(compiled, i))\n    }\n",
		// 効果のある呼び出し（純粋な let ではない）
		"    def f(): Unit =\n        let dst = Array.toVector(buf);\n        shadeAll(n, i -> Vector.get(i, dst))\n",
		// 軽い呼び出しだけ
		"    def f(): Unit =\n        let x0 = Int32.max(0, rx);\n        shadeAll(n, i -> i + x0)\n",
		// ラムダの中の let
		"    def f(): Unit =\n        shadeAll(n, i -> { let px = Int32.remainder(i, w); px })\n",
		// 欄の名前がたまたま同じ (#blend) は使ったことにしない
		"    def f(p: P): Unit =\n        let blend = make(p);\n        shadeAll(n, i -> q#blend)\n",
		// ループに渡さないラムダ
		"    def f(p: P): Unit =\n        let t = make(p);\n        List.map(x -> x + t, xs)\n",
	} {
		if got := found("engine_tools/src/A.flix", src); got != "" {
			t.Fatalf("%q: got %q", src, got)
		}
	}
}

func writeRepo(t *testing.T, rules, src string) string {
	t.Helper()
	root := t.TempDir()
	for path, body := range map[string]string{
		RulesPath:                 rules,
		"engine_tools/src/A.flix": src,
	} {
		full := filepath.Join(root, path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

const rulesJSON = `{"scopeSuffixes":[".flix"],"skipPrefixes":[],"skipDirNames":["lib"],"fnReturnScope":["engine_tools/"],
"loopCalls":["shadeAll"],"once":"onceOutsideLoop","notMoved":{},"effectful":{},"exempt":%s}`

func TestExemptSilencesAndStaleExemptStops(t *testing.T) {
	src := "    def f(p: P): Unit =\n        let t = make(p);\n        shadeAll(n, i -> t)\n"
	root := writeRepo(t, strings.Replace(rulesJSON, "%s", `{"engine_tools/src/A.flix::f::t":"試しの除外"}`, 1), src)
	var out, errOut strings.Builder
	if code, err := Run(&out, &errOut, root, []string{"--all"}); err != nil || code != 0 {
		t.Fatalf("除外したのに code=%d err=%v %s", code, err, errOut.String())
	}
	root = writeRepo(t, strings.Replace(rulesJSON, "%s", `{"engine_tools/src/A.flix::g::t":"もう無い所"}`, 1), src)
	out.Reset()
	errOut.Reset()
	if code, _ := Run(&out, &errOut, root, []string{"--all"}); code != 1 || !strings.Contains(errOut.String(), "古い除外") {
		t.Fatalf("古い除外と鳴る所の両方で止まるはず: code=%d %s", code, errOut.String())
	}
}

func TestWarnDoesNotStop(t *testing.T) {
	src := "    def f(p: P): Unit =\n        let t = make(p);\n        shadeAll(n, i -> t)\n"
	root := writeRepo(t, strings.Replace(rulesJSON, "%s", `{}`, 1), src)
	var out, errOut strings.Builder
	if code, _ := Run(&out, &errOut, root, []string{"--all", "--warn"}); code != 0 {
		t.Fatalf("--warn は止めないはず: code=%d", code)
	}
	if !strings.Contains(errOut.String(), "let t") {
		t.Fatalf("鳴る所は出すはず: %s", errOut.String())
	}
}
