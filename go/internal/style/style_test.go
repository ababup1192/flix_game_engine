package style

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 何を見るか: 画風の軸の判定・出す字面・終了コード。

func run(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	var out, errOut strings.Builder
	code, err := Run(&out, &errOut, repoRoot(), args)
	if err != nil {
		t.Fatalf("検査が動かなかった: %v", err)
	}
	return out.String(), errOut.String(), code
}

// writePNG は左半分と右半分を塗り分けた絵を書き出す。
func writePNG(t *testing.T, name string, w, h int, left, right color.RGBA) string {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			c := left
			if x >= w/2 {
				c = right
			}
			img.Set(x, y, c)
		}
	}
	path := filepath.Join(t.TempDir(), name)
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestNoArgsShowsUsage(t *testing.T) {
	out, errOut, code := run(t)
	if code != 1 {
		t.Errorf("終了コードが %d (期待 1)", code)
	}
	if !strings.HasPrefix(out, docHead) {
		t.Errorf("使い方の 1 行目が出ていない: %q", out)
	}
	if errOut != "" {
		t.Errorf("stderr に出ている: %q", errOut)
	}
}

func TestUnknownOption(t *testing.T) {
	out, _, code := run(t, "--nope")
	if code != 1 || out != "知らないオプション: --nope\n" {
		t.Errorf("出力が %q / 終了コード %d", out, code)
	}
}

func TestHandValueAtTailIsUnknownOption(t *testing.T) {
	// 値の無い --hand は「知らないオプション」に落ちる。
	out, _, code := run(t, "--hand")
	if code != 1 || out != "知らないオプション: --hand\n" {
		t.Errorf("出力が %q / 終了コード %d", out, code)
	}
}

func TestBadHand(t *testing.T) {
	out, _, code := run(t, "--hand", "pixel", "a.png")
	if code != 1 || out != "--hand は coarse / fine / smooth のどれか: pixel\n" {
		t.Errorf("出力が %q / 終了コード %d", out, code)
	}
}

func TestBadUnit(t *testing.T) {
	out, _, code := run(t, "--unit", "two", "a.png")
	if code != 1 || out != "--unit には数を渡してください: two\n" {
		t.Errorf("出力が %q / 終了コード %d", out, code)
	}
}

func TestCompareNeedsTwoFiles(t *testing.T) {
	out, _, code := run(t, "--compare", "a.png")
	if code != 1 || out != "--compare は PNG を 2 枚だけ渡してください\n" {
		t.Errorf("出力が %q / 終了コード %d", out, code)
	}
}

func TestMissingFile(t *testing.T) {
	out, _, code := run(t, "debug/no-such.png")
	if code != 1 || out != "見つからない: debug/no-such.png\n" {
		t.Errorf("出力が %q / 終了コード %d", out, code)
	}
}

func TestNotAPNG(t *testing.T) {
	path := filepath.Join(t.TempDir(), "note.txt")
	if err := os.WriteFile(path, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, _, code := run(t, path)
	if code != 1 || !strings.Contains(out, "測れない: "+path+" (PNG ではない)") {
		t.Errorf("出力が %q / 終了コード %d", out, code)
	}
}

func TestDescribeFlatImage(t *testing.T) {
	// 32x32 を左右 2 色で塗ると、中間色 0%・色数 2 になる。
	path := writePNG(t, "coarse-flat.png", 32, 32,
		color.RGBA{0, 0, 0, 255}, color.RGBA{255, 255, 255, 255})
	out, _, code := run(t, "--hand", "coarse", path)
	want := "coarse-flat.png  32x32  unit=2(自動)\n" +
		"  中間色 0.0%   格子適合 100%   楕円で説明できる面 0.0%\n" +
		"  色数 2 (画面の 90% を覆う色 2)   平均輝度 128\n" +
		"  隣の色の段: 1-4:0%  5-12:0%  13-32:0%  33+:100%\n" +
		"  明度 3 段: 暗 50% / 中 0% / 明 50%\n" +
		"OK: 画風の軸ズレはありません（注意 0 件）\n"
	if out != want {
		t.Errorf("出力が\n%s\n期待\n%s", out, want)
	}
	if code != 0 {
		t.Errorf("終了コードが %d (期待 0)", code)
	}
}

func TestStrictTurnsWarningIntoFailure(t *testing.T) {
	// 16x16 を左右で割ると面が楕円そのものと判定され、注意が 1 件出る。
	path := writePNG(t, "coarse-half.png", 16, 16,
		color.RGBA{0, 0, 0, 255}, color.RGBA{255, 255, 255, 255})
	out, _, code := run(t, "--hand", "coarse", path)
	if code != 0 || !strings.Contains(out, "注意: coarse-half.png: 画面の 100.0% が楕円そのものの面") {
		t.Fatalf("注意が 1 件出ていない: %q / 終了コード %d", out, code)
	}
	if _, _, code := run(t, "--strict", "--hand", "coarse", path); code != 1 {
		t.Errorf("--strict の終了コードが %d (期待 1)", code)
	}
}

func TestUnknownHandWarns(t *testing.T) {
	path := writePNG(t, "title.png", 16, 16,
		color.RGBA{0, 0, 0, 255}, color.RGBA{255, 255, 255, 255})
	out, _, code := run(t, path)
	if code != 0 || !strings.Contains(out, "注意: title.png: 描き手が分かりません — --hand を渡すと判定します\n") {
		t.Errorf("出力が %q / 終了コード %d", out, code)
	}
}

func TestSmoothWarnsOnFlatImage(t *testing.T) {
	path := writePNG(t, "smooth-flat.png", 16, 16,
		color.RGBA{0, 0, 0, 255}, color.RGBA{255, 255, 255, 255})
	out, errOut, code := run(t, path)
	if code != 0 {
		t.Errorf("終了コードが %d (期待 0・smooth は NG を出さない)", code)
	}
	if errOut != "" {
		t.Errorf("stderr に出ている: %q", errOut)
	}
	for _, want := range []string{
		"注意: smooth-flat.png: 中間色が 0.0% しかない",
		"注意: smooth-flat.png: 色数 2 と少なすぎ",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("%q が出ていない: %s", want, out)
		}
	}
}

func TestBadGoesToStderrWithHint(t *testing.T) {
	// 色数の多い絵を coarse と言うと NG。NG は stderr へ出て手つきの在り処が付く。
	dir := t.TempDir()
	img := image.NewNRGBA(image.Rect(0, 0, 64, 64))
	for y := 0; y < 64; y++ {
		for x := 0; x < 64; x++ {
			img.Set(x, y, color.RGBA{uint8(x * 4), uint8(y * 4), uint8((x + y) * 2), 255})
		}
	}
	path := filepath.Join(dir, "coarse-grad.png")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := png.Encode(f, img); err != nil {
		t.Fatal(err)
	}
	f.Close()

	out, errOut, code := run(t, path)
	if code != 1 {
		t.Errorf("終了コードが %d (期待 1)", code)
	}
	if strings.Contains(out, "NG:") {
		t.Errorf("NG が stdout に出ている: %s", out)
	}
	if !strings.HasPrefix(errOut, "\nNG: ") {
		t.Errorf("stderr が空行 + NG で始まっていない: %q", errOut)
	}
	if !strings.Contains(errOut, "手つきの在り処: .claude/skills/pixel-art（お題の種類の表）・色の予算とタイルは retro-pixel") {
		t.Errorf("手つきの在り処が出ていない: %s", errOut)
	}
}

func TestCompareSaysNoDifference(t *testing.T) {
	a := writePNG(t, "fine-flat.png", 32, 32,
		color.RGBA{0, 0, 0, 255}, color.RGBA{255, 255, 255, 255})
	b := writePNG(t, "smooth-flat.png", 32, 32,
		color.RGBA{0, 0, 0, 255}, color.RGBA{255, 255, 255, 255})
	out, errOut, code := run(t, "--compare", a, b)
	if code != 1 {
		t.Errorf("終了コードが %d (期待 1)", code)
	}
	if !strings.Contains(out, "fine-flat.png <-> smooth-flat.png の差\n") {
		t.Errorf("差の見出しが出ていない: %s", out)
	}
	if !strings.Contains(errOut, "NG: fine と smooth の差がほぼありません (中間色の差 +0.0 ポイント・色数 1.00 倍)") {
		t.Errorf("差が無い旨の NG が出ていない: %s", errOut)
	}
}

func TestGuessHand(t *testing.T) {
	rules, err := LoadRules(repoRoot())
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"debug/style/FAMICOM-a.png": "coarse",
		"sfc-b.png":                 "fine",
		"a/b/nopixel.png":           "smooth",
		"title.png":                 "",
		// 前から順に見るので coarse が先に当たる。
		"coarse-smooth.png": "coarse",
	}
	for path, want := range cases {
		if got := rules.guessHand(path); got != want {
			t.Errorf("%s の描き手が %q (期待 %q)", path, got, want)
		}
	}
}

func TestPyInt(t *testing.T) {
	ok := map[string]int{"2": 2, " 3 ": 3, "+4": 4, "-1": -1, "1_0": 10, "0": 0}
	for s, want := range ok {
		got, valid := pyInt(s)
		if !valid || got != want {
			t.Errorf("pyInt(%q) = %d, %v (期待 %d)", s, got, valid, want)
		}
	}
	for _, s := range []string{"", "two", "1.5", "_1", "1_", "1__2", "0x2", "+"} {
		if got, valid := pyInt(s); valid {
			t.Errorf("pyInt(%q) が %d を返した (期待 受け取らない)", s, got)
		}
	}
}

func TestBaseName(t *testing.T) {
	cases := map[string]string{
		"a/b/c.png": "c.png",
		"c.png":     "c.png",
		"a/b/":      "",
	}
	for path, want := range cases {
		if got := baseName(path); got != want {
			t.Errorf("baseName(%q) = %q (期待 %q)", path, got, want)
		}
	}
}
