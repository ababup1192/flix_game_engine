// GLSL と WGSL で 2 本に書いた手書きの式（ノイズの関数・ぼかし・mip のレベルを選ぶ読み・割り算）の数のリテラルが、出てくる順に同じか。
// 片方だけ数を直したずれを、GPU を使わずに止める（式の値まで同じかは bench/gl_parity の wgsl-rows が GPU で見る）。
// WhyNot: mod TestWgslPairs にしない — 比べる関数は ShaderGen と ShaderGen.Wgsl の pub でない関数で、子のモジュールからしか呼べない。
mod ShaderGen.Wgsl.TestWgslPairs {

    /// 字 s の数のリテラル（名前の途中の数字 — sg_hash1・vec2・f32 — は数えない）を出てくる順に。符号は見ない。
    def numbersIn(s: String): List[String] =
        let chars = String.toList(s) |> List.toVector;
        let n = Vector.length(chars);
        let at = (i: Int32) -> if (i >= 0 and i < n) Vector.get(i, chars) else ' ';
        let isPart = (ch: Char) -> Char.isLetter(ch) or Char.isDigit(ch) or ch == '_' or ch == '.';
        def digitsEnd(i: Int32): Int32 = if (Char.isDigit(at(i))) digitsEnd(i + 1) else i;
        def numberEnd(i: Int32): Int32 = {
            let afterInt = digitsEnd(i);
            let afterFrac = if (at(afterInt) == '.') digitsEnd(afterInt + 1) else afterInt;
            let hasExp = (at(afterFrac) == 'e' or at(afterFrac) == 'E') and
                         (Char.isDigit(at(afterFrac + 1)) or ((at(afterFrac + 1) == '-' or at(afterFrac + 1) == '+') and Char.isDigit(at(afterFrac + 2))));
            if (hasExp) digitsEnd(afterFrac + (if (Char.isDigit(at(afterFrac + 1))) 1 else 2)) else afterFrac
        };
        def go(i: Int32, acc: List[String]): List[String] =
            if (i >= n) List.reverse(acc)
            else if (Char.isDigit(at(i)) and not isPart(at(i - 1))) {
                let end = numberEnd(i);
                go(end, String.slice({ start = i }, { end = end }, s) :: acc)
            }
            else go(i + 1, acc);
        go(0, Nil)

    @Test
    def testNoiseFunctionsHaveTheSameNumbers(): Unit \ Assert =
        Assert.assertEq(expected = numbersIn(ShaderGen.preludeSource()), numbersIn(ShaderGen.Wgsl.prelude()))

    @Test
    def testBlurHasTheSameNumbers(): Unit \ Assert =
        Assert.assertEq(expected = numbersIn(ShaderGen.blurSourceWith(_ -> "textureLod(tex, p, 0.0)")), numbersIn(ShaderGen.Wgsl.blurSource()))

    /// GLSL の読みの座標の上下を返す式（WGSL には無い）は外して比べる。
    @Test
    def testTexMipHasTheSameNumbers(): Unit \ Assert =
        let glsl = ShaderGen.texMipSource() |> String.replace(src = "vec2(c.x, mix(c.y, 1.0 - c.y, flip))", dst = "c");
        Assert.assertEq(expected = numbersIn(glsl), numbersIn(ShaderGen.Wgsl.texMipSource()))

    @Test
    def testDivHasTheSameNumbers(): Unit \ Assert =
        Assert.assertEq(expected = numbersIn(ShaderGen.divSource()), numbersIn(ShaderGen.Wgsl.divSource()))

    /// 数の抜き方: 名前の途中の数字を数えず、小数と指数をひとまとまりで読む。
    @Test
    def testNumbersSkipNamesAndReadExponents(): Unit \ Assert =
        Assert.assertEq(expected = "0.5" :: "1e-12" :: "2" :: "1.0E-4" :: Nil,
                        numbersIn("sg_hash1(vec2f(0.5), f32(x) < 1e-12) * 2 + uTex0 + 1.0E-4"))
}
