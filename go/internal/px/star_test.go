package px

import (
	"math"
	"math/big"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// writeFiles は一時フォルダに files（相対パス → 中身）を書いて、そのフォルダを返す。
func writeFiles(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for p, body := range files {
		full := filepath.Join(dir, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func runScript(t *testing.T, files map[string]string, script string, opt starOptions) (*starResult, error) {
	t.Helper()
	return runStar(writeFiles(t, files), script, opt)
}

// ---------------------------------------------------------------- CPython と同じ答え（値は python3 で出した物）

func TestPyRandomMatchesCPython(t *testing.T) {
	r := newPyRandom(big.NewInt(0))
	for i, want := range []float64{0.8444218515250481, 0.7579544029403025, 0.420571580830845} {
		if got := r.random(); got != want {
			t.Errorf("Random(0) の %d 個目 = %v, want %v", i, got, want)
		}
	}
	big40 := new(big.Int).Add(new(big.Int).Lsh(big.NewInt(1), 40), big.NewInt(5))
	if got := newPyRandom(big40).random(); got != 0.5043802970418443 {
		t.Errorf("Random(2**40+5) = %v", got)
	}
	if got := newPyRandom(big.NewInt(-3)).random(); got != 0.23796462709189137 {
		t.Errorf("Random(-3) = %v", got)
	}
}

func TestStarRngMatchesCPython(t *testing.T) {
	res, err := runScript(t, map[string]string{"a.px.star": `
r = px.rng(7)
px.write_json("o.json", [[r.randint(9, 15) for _ in range(5)], [r.randint(-4, 4) for _ in range(3)], r.uniform(6, 14)], style = "python")
`}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(res.Files[0].Data), "[[11, 10, 12, 14, 9], [-3, 4, -3], 8.925511335300683]"; got != want {
		t.Errorf("got %s want %s", got, want)
	}
}

func TestHashAndNoiseMatchPxlib(t *testing.T) {
	res, err := runScript(t, map[string]string{"a.px.star": `
px.write_json("o.json", [px.hash01(3, 5), px.hash01(-7, 2, 9), px.hash01(100, -3, 2246822519),
    px.noise1(0.3, 2), px.noise1(-0.667, 8), px.noise1(70.5, 3)], style = "python")
`}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	want := "[0.765316243228809, 0.45355916685740444, 0.11534294651712826, 0.954261606365991, 0.2261487954465971, 0.5484115482122338]"
	if got := string(res.Files[0].Data); got != want {
		t.Errorf("got %s\nwant %s", got, want)
	}
}

func TestRoundMatchesPython(t *testing.T) {
	res, err := runScript(t, map[string]string{"a.px.star": `
px.write_json("o.json", [px.round(2.5), px.round(-0.5), px.round(2.675, 2), px.round(0.125, 2), px.round(172, 1), px.round(146.04999, 1)], style = "python")
`}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(res.Files[0].Data), "[2, 0, 2.67, 0.12, 172, 146.0]"; got != want {
		t.Errorf("got %s want %s", got, want)
	}
}

func TestFloatReprMatchesPython(t *testing.T) {
	for x, want := range map[float64]string{1.0: "1.0", 0.1: "0.1", 1e-05: "1e-05", 1e16: "1e+16", 1e15: "1000000000000000.0",
		123456789012345680.0: "1.2345678901234568e+17", 0.0001: "0.0001", 2.5e-05: "2.5e-05", 1.0 / 3: "0.3333333333333333"} {
		if got, _ := pyFloatRepr(x); got != want {
			t.Errorf("repr(%v) = %s, want %s", x, got, want)
		}
	}
	if got, _ := pyFloatRepr(math.Copysign(0, -1)); got != "-0.0" {
		t.Errorf("repr(-0.0) = %s", got)
	}
}

func TestPythonJSONLayout(t *testing.T) {
	src := `d = {"a": [1, 2.0, "x\né\"", None, True], "b": {}, "c": []}
px.write_json("c.json", d, style = "python")
px.write_json("i.json", d, style = "python", indent = 1)
`
	res, err := runScript(t, map[string]string{"a.px.star": src}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	compact := `{"a": [1, 2.0, "x\né\"", null, true], "b": {}, "c": []}`
	indented := "{\n \"a\": [\n  1,\n  2.0,\n  \"x\\né\\\"\",\n  null,\n  true\n ],\n \"b\": {},\n \"c\": []\n}"
	if got := string(res.Files[0].Data); got != compact {
		t.Errorf("1 行: got %s", got)
	}
	if got := string(res.Files[1].Data); got != indented {
		t.Errorf("indent=1: got %s", got)
	}
}

// ---------------------------------------------------------------- math は正しく丸めた値

// macOS の libm は 0.5 ulp を超えてずれる引数がある。正しく丸めた値（Python の decimal で 60 桁）を返す。
func TestMathIsCorrectlyRounded(t *testing.T) {
	for _, tc := range []struct {
		got, want float64
	}{
		{crCos(0.7404804896930609), 0.7381444851051177},
		{crCos(2.5307274153917776), -0.8191520442889916},
		{crSin(0.7404804896930608), 0.674642660309071},
		{crHypot(3, 4), 5},
	} {
		if tc.got != tc.want {
			t.Errorf("got %v want %v", tc.got, tc.want)
		}
	}
	if v, _ := crPow(2, 10); v != 1024 {
		t.Errorf("pow(2, 10) = %v", v)
	}
	if v, _ := crExp(0); v != 1 {
		t.Errorf("exp(0) = %v", v)
	}
}

// Go の math と 4 ulp 以内（式の取り違えを見る。Go の Pow や amd64 の Exp は 1 ulp を超えてずれる。答えそのものは golden で固める）。
func TestMathNearGoMath(t *testing.T) {
	rng := rand.New(rand.NewSource(3))
	var x, y float64
	near := func(name string, a, b float64) {
		if !withinULP(a, b, 4) {
			t.Fatalf("%s: %v と Go の %v が 1 ulp より離れている（%v, %v）", name, a, b, x, y)
		}
	}
	for i := 0; i < 3000; i++ {
		x, y = rng.Float64()*40-20, rng.Float64()*40-20
		near("sin", crSin(x), math.Sin(x))
		near("cos", crCos(x), math.Cos(x))
		e, _ := crExp(x)
		near("exp", e, math.Exp(x))
		l, _ := crLog(math.Abs(x))
		near("log", l, math.Log(math.Abs(x)))
		p, _ := crPow(math.Abs(x), y/10)
		near("pow", p, math.Pow(math.Abs(x), y/10))
		near("atan2", crAtan2(y, x), math.Atan2(y, x))
	}
}

func withinULP(a, b float64, n int) bool {
	for i := 0; i < n; i++ {
		a = math.Nextafter(a, b)
	}
	return a == b
}

// 関数の答えの表が golden.json とバイトで同じ（arm64 と amd64 で同じ結果になることを make go-test-amd64 で見る）。
func TestStarGoldenSameOnEveryArch(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("testdata", "star", "golden.px.star"))
	if err != nil {
		t.Fatal(err)
	}
	res, err := runScript(t, map[string]string{"golden.px.star": string(src)}, "golden.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	goldenPath := filepath.Join("testdata", "star", "golden.json")
	if os.Getenv("PX_STAR_UPDATE") == "1" {
		if err := os.WriteFile(goldenPath, res.Files[0].Data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(res.Files[0].Data) != string(want) {
		t.Errorf("台本の答えが golden.json と違う（CPU で答えが変わっている）")
	}
}

// ---------------------------------------------------------------- 囲い（サンドボックス）

func TestLoadOnlyFromScriptDirAndTools(t *testing.T) {
	files := map[string]string{
		"scenes/tools/lib.star":    "def f():\n    return 1\n",
		"scenes/a/lib2.star":       "def g():\n    return 2\n",
		"scenes/secret/x.star":     "def h():\n    return 3\n",
		"scenes/a/ok.px.star":      "load(\"../tools/lib.star\", \"f\")\nload(\"lib2.star\", \"g\")\npx.write_json(\"o.json\", [f(), g()])\n",
		"scenes/a/bad.px.star":     "load(\"../secret/x.star\", \"h\")\n",
		"scenes/a/notstar.px.star": "load(\"../tools/lib.py\", \"f\")\n",
	}
	dir := writeFiles(t, files)
	if _, err := runStar(dir, "scenes/a/ok.px.star", starOptions{}); err != nil {
		t.Errorf("同じフォルダと隣の tools/ は読める: %v", err)
	}
	for _, s := range []string{"scenes/a/bad.px.star", "scenes/a/notstar.px.star"} {
		if _, err := runStar(dir, s, starOptions{}); err == nil {
			t.Errorf("%s: 決めたフォルダの外の load が止まらない", s)
		}
	}
}

func TestMaxStepsStops(t *testing.T) {
	_, err := runScript(t, map[string]string{"a.px.star": "def spin():\n    x = 0\n    while True:\n        x += 1\n\nspin()\n"}, "a.px.star", starOptions{MaxSteps: 100000})
	if err == nil || !strings.Contains(err.Error(), "手数の上限") {
		t.Errorf("手数の上限で止まらない: %v", err)
	}
}

func TestNoFileTimeOrNet(t *testing.T) {
	for _, src := range []string{`open("x")`, `time.now()`, `http.get("x")`, `load("os", "x")`} {
		if _, err := runScript(t, map[string]string{"a.px.star": src + "\n"}, "a.px.star", starOptions{}); err == nil {
			t.Errorf("%s が通った", src)
		}
	}
}

func TestWritesStayInsideWorkRoot(t *testing.T) {
	for _, p := range []string{"../x.json", "/tmp/x.json", "assets/x.json", "a/assets/x.json", "x.txt"} {
		src := "px.write_json(\"" + p + "\", {})\n"
		if _, err := runScript(t, map[string]string{"a.px.star": src}, "a.px.star", starOptions{}); err == nil {
			t.Errorf("%s へ書けてしまう", p)
		}
	}
}

func TestWriteSpecChecksSpec(t *testing.T) {
	_, err := runScript(t, map[string]string{"a.px.star": `px.write_spec("t.pxsrc.json", {"version": 2})` + "\n"}, "a.px.star", starOptions{})
	if err == nil || !strings.Contains(err.Error(), "target") {
		t.Errorf("spec の書き損じで止まらない: %v", err)
	}
}

// ---------------------------------------------------------------- 決まり

func TestUnusedFunctionIsAdvice(t *testing.T) {
	res, err := runScript(t, map[string]string{"a.px.star": "def used():\n    return 1\n\ndef spare():\n    return 2\n\nused()\n"}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatalf("使われない関数で止まった（advice に下げる）: %v", err)
	}
	if !strings.Contains(strings.Join(res.Advice, "\n"), "spare") {
		t.Errorf("使われない関数が advice に無い: %v", res.Advice)
	}
}

func TestNoneArgIsOmitted(t *testing.T) {
	res, err := runScript(t, map[string]string{"a.px.star": "px.write_json(\"o.json\", [op.fill(shape = None, color = \"c0\")])\n"}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got := string(res.Files[0].Data); !strings.Contains(got, `"fill"`) || strings.Contains(got, "shape") {
		t.Errorf("None の引数が省かれていない: %s", got)
	}
	if _, err := parseOpCall(map[string]any{"fill": map[string]any{"shape": nil, "color": "c0"}}, "t", nil); err != nil {
		t.Errorf("pxsrc の null が省いたのと同じにならない: %v", err)
	}
}

func TestAdvice(t *testing.T) {
	cells := strings.Repeat("[0, 0], ", 201)
	src := "def once():\n    i = 0\n    while i < 1:\n        i += 1\n\nonce()\n" + strings.Repeat("\n", 600) +
		`px.write_spec("t.pxsrc.json", {"version": 2, "target": "atelier/t.sprite.json", "palette": "p.json", "ramps": {"r": ["c0"]},
  "sprites": {"s": {"size": [4, 4], "ramp": "r", "parts": [{"id": "dots", "ops": [{"put": {"cells": [` + cells + `], "color": "c0"}}]}], "frames": {"f0": {}}}}})
`
	res, err := runScript(t, map[string]string{"a.px.star": src}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	all := strings.Join(res.Advice, "\n")
	for _, want := range []string{"行（600 行まで）", "while が 1 か所", "s.dots の put が 201 画素"} {
		if !strings.Contains(all, want) {
			t.Errorf("advice に %q が無い:\n%s", want, all)
		}
	}
}

// ---------------------------------------------------------------- 口

func TestGenWritesAndBuildReadsFromMemory(t *testing.T) {
	dir := writeFiles(t, map[string]string{
		"assets/t.palette.json": `{"version": 1, "c0": "#202020", "c1": "#606060", "c2": "#a0a0a0", "c3": "#e0e0e0"}`,
		"art/t.px.star": `px.write_spec("t.pxsrc.json", {"version": 2, "target": "//atelier/t.sprite.json", "palette": "../assets/t.palette.json",
  "ramps": {"r": ["c0", "c1", "c2", "c3"]},
  "sprites": {"s": {"size": [4, 2], "ramp": "r", "parts": [{"id": "a", "shape": {"rect": [0, 0, %d, 1]}, "ops": [{"fill": {"color": "ink"}}]}],
  "frames": {"idle": {}}}}})
` + "\n",
	})
	// build: pxsrc は書かずに描く
	src, _ := os.ReadFile(filepath.Join(dir, "art", "t.px.star"))
	if err := os.WriteFile(filepath.Join(dir, "art", "t.px.star"), []byte(strings.Replace(string(src), "%d", "2", 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, engineRoot, dir, []string{"build", "art/t.px.star", "--no-check"}, false); code != 0 {
		t.Fatalf("build: %d\n%s%s", code, out.String(), errOut.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "art", "t.pxsrc.json")); err == nil {
		t.Errorf("build が pxsrc を書いた")
	}
	if _, err := os.Stat(filepath.Join(dir, "atelier", "t.sprite.json")); err != nil {
		t.Errorf("build が sprite.json を書いていない: %v", err)
	}
	// gen: pxsrc を書く。2 回目は同じ中身なので触らない
	for i, want := range []string{"変わった 1", "変わった 0"} {
		out.Reset()
		if code := Run(&out, &errOut, engineRoot, dir, []string{"gen", "art/t.px.star"}, false); code != 0 {
			t.Fatalf("gen %d: %s", i, errOut.String())
		}
		if !strings.Contains(out.String(), want) {
			t.Errorf("gen %d: %q が無い: %s", i, want, out.String())
		}
	}
}

// ---------------------------------------------------------------- 初めての担当の書きにくさ（0 周目）

// 台本の中のパスは台本のフォルダが起点・// は作業場の根から。pxsrc の target などは根からのパスに直して書く。
func TestPathsAreRelativeToScript(t *testing.T) {
	src := `ramps = px.palette("t.palette.json", {"r": ["#202020", "#606060"]})
px.write_spec("t.pxsrc.json", {"version": 2, "target": "//atelier/t.sprite.json", "palette": "t.palette.json", "style": "my.pxstyle.json",
  "ramps": ramps, "sprites": {"s": {"size": [2, 2], "ramp": "r", "parts": [{"id": "a", "ops": []}], "frames": {"f": {}}}}})
`
	res, err := runScript(t, map[string]string{"debug/scene/t.px.star": src}, "debug/scene/t.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, f := range res.Files {
		paths = append(paths, f.Path)
	}
	if strings.Join(paths, " ") != "debug/scene/t.palette.json debug/scene/t.pxsrc.json" {
		t.Errorf("書いた先: %v", paths)
	}
	spec := string(res.Files[1].Data)
	for _, want := range []string{`"target": "atelier/t.sprite.json"`, `"palette": "debug/scene/t.palette.json"`, `"style": "debug/scene/my.pxstyle.json"`} {
		if !strings.Contains(spec, want) {
			t.Errorf("pxsrc に %s が無い:\n%s", want, spec)
		}
	}
}

// px.palette は hex の列から色票を書き、ランプ（色キーの列）を返す。
func TestPaletteWritesHexAndReturnsRamps(t *testing.T) {
	src := `ramps = px.palette("p.palette.json", {"roof": ["#301018", "602028"], "ink": "#000000"})
px.write_json("r.json", ramps)
`
	res, err := runScript(t, map[string]string{"a.px.star": src}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got := string(res.Files[0].Data); got != "{\n \"version\": 1,\n \"roof0\": \"#301018\",\n \"roof1\": \"#602028\",\n \"ink\": \"#000000\"\n}\n" {
		t.Errorf("色票: %s", got)
	}
	if got := string(res.Files[1].Data); !strings.Contains(got, `"roof": [`) || strings.Contains(got, "ink") {
		t.Errorf("返り値はランプだけ: %s", got)
	}
	if _, err := runScript(t, map[string]string{"a.px.star": `px.palette("p.palette.json", {"x": "red"})` + "\n"}, "a.px.star", starOptions{}); err == nil {
		t.Errorf("#rrggbb でない色が通った")
	}
}

// op.<名前>(…) は {名前: {引数}} を作り、予約語の引数は末尾の _ を外す。型の誤りはその行で止まる。
func TestOpModuleBuildsDictAndAliasesReserved(t *testing.T) {
	res, err := runScript(t, map[string]string{"a.px.star": `px.write_json("o.json", [op.directional(from_ = 1, band = 0.25), op.sel_out()])` + "\n"}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if got := string(res.Files[0].Data); !strings.Contains(got, `"from": 1`) || !strings.Contains(got, `"sel_out": {}`) {
		t.Errorf("op の dict: %s", got)
	}
	for _, src := range []string{`op.directional(band = "x")`, `op.directional(nope = 1)`, `op.directional(1)`} {
		if _, err := runScript(t, map[string]string{"a.px.star": src + "\n"}, "a.px.star", starOptions{}); err == nil || !strings.Contains(err.Error(), "a.px.star:1") {
			t.Errorf("%s: 行番号つきで止まらない: %v", src, err)
		}
	}
}

// 一番外の名前の再代入（Starlark の決まり）には def の中に入れる案内を付ける。
func TestTopLevelReassignHint(t *testing.T) {
	_, err := runScript(t, map[string]string{"a.px.star": "for i in range(2):\n    pass\nfor i in range(3):\n    pass\n"}, "a.px.star", starOptions{})
	if err == nil || !strings.Contains(err.Error(), "def の中に入れて") {
		t.Errorf("案内が無い: %v", err)
	}
}

// docs/px-ops.md に載せた最小の台本は、そのまま gen と build を通る。
func TestStarExampleRuns(t *testing.T) {
	dir := writeFiles(t, map[string]string{"debug/px-scenes/lamp/lamp.px.star": starExample})
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, engineRoot, dir, []string{"build", "debug/px-scenes/lamp/lamp.px.star"}, false); code != 0 {
		t.Fatalf("build: %d\n%s%s", code, out.String(), errOut.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "atelier", "lamp.sprite.json")); err != nil {
		t.Errorf("target が atelier/ に書かれていない: %v", err)
	}
}

// snap は台本を受けて gen してから撮り、周に台本を積む。古い pxsrc を撮る時は警告する。
func TestSnapTakesScriptAndWarnsStalePxsrc(t *testing.T) {
	dir := writeFiles(t, map[string]string{"debug/px-scenes/lamp/lamp.px.star": starExample})
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, engineRoot, dir, []string{"snap", "debug/px-scenes/lamp/lamp.px.star"}, false); code != 0 {
		t.Fatalf("snap: %d\n%s%s", code, out.String(), errOut.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "debug", "history", "lamp", "r1.lamp.px.star")); err != nil {
		t.Errorf("周に台本が積まれていない: %v", err)
	}
	// 台本だけ直して pxsrc を撮ると、台本の変更が入っていないと言う
	star := filepath.Join(dir, "debug", "px-scenes", "lamp", "lamp.px.star")
	if err := os.WriteFile(star, []byte(strings.Replace(starExample, "[16, 24]", "[16, 26]", 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	future := time.Now().Add(time.Hour)
	if err := os.Chtimes(star, future, future); err != nil {
		t.Fatal(err)
	}
	if w := staleStar(dir, "debug/px-scenes/lamp/lamp.pxsrc.json"); !strings.Contains(w, "台本の変更が入っていない") {
		t.Errorf("古い pxsrc の警告が無い: %q", w)
	}
}

// schema は引数なしでは docs/ を書かない（--write で書く）。
func TestSchemaDefaultOnlyPrints(t *testing.T) {
	dir := t.TempDir()
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, dir, dir, []string{"schema"}, false); code != 0 || !strings.Contains(out.String(), "docs/pxsrc.schema.json") {
		t.Fatalf("schema: %d %s", code, errOut.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "docs")); err == nil {
		t.Errorf("引数なしの schema が docs/ を書いた")
	}
}

// help は引数なしでコマンドと style（色数の上限）、コマンドの名前でその使い方を出す。
func TestHelpListsCommandsAndStyles(t *testing.T) {
	var out, errOut strings.Builder
	if code := Run(&out, &errOut, engineRoot, t.TempDir(), []string{"help"}, false); code != 0 || !strings.Contains(out.String(), "snes") || !strings.Contains(out.String(), "15 色") {
		t.Errorf("help の一覧: %d %s%s", code, out.String(), errOut.String())
	}
	out.Reset()
	if code := Run(&out, &errOut, engineRoot, t.TempDir(), []string{"help", "snap"}, false); code != 0 || !strings.Contains(out.String(), "--max") {
		t.Errorf("help snap: %d %s", code, out.String())
	}
}

// build --png は実寸・4 倍・横並びを書き、同じ指定からは同じバイトになる。
func TestBuildPNGIsDeterministic(t *testing.T) {
	dir := writeFiles(t, map[string]string{"debug/px-scenes/lamp/lamp.px.star": starExample})
	var sums []string
	for i := 0; i < 2; i++ {
		var out, errOut strings.Builder
		if code := Run(&out, &errOut, engineRoot, dir, []string{"build", "debug/px-scenes/lamp/lamp.px.star", "--png", "--no-check"}, false); code != 0 {
			t.Fatalf("build: %s", errOut.String())
		}
		var all []byte
		for _, n := range []string{"lamp.png", "lamp@4x.png", "lamp.strip.png", "lamp.strip@4x.png"} {
			data, err := os.ReadFile(filepath.Join(dir, "debug", "px", "lamp", "png", n))
			if err != nil {
				t.Fatal(err)
			}
			all = append(all, data...)
		}
		sums = append(sums, string(all))
	}
	if sums[0] != sums[1] {
		t.Errorf("同じ指定から違う PNG")
	}
}

func TestReservedPaletteKeyAdvice(t *testing.T) {
	res, err := runScript(t, map[string]string{"a.px.star": `px.write_json("t.palette.json", {"version": 1, "ink": "#101010"})` + "\n"}, "a.px.star", starOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(res.Advice, "\n"), `色キー "ink"`) {
		t.Errorf("ink の色キーが advice に無い: %v", res.Advice)
	}
}
