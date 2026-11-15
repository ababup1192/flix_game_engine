// Render3dGlsl と Render3dWgsl で 2 本に書いた手書きの式（影の PCF・法線マップの TBN・環境マップの読み）の数のリテラルが、出てくる順に同じか。
// 片方だけ数を直したずれを、GPU を使わずに止める。光の式の木から作る関数（toGlsl・toWgsl）は 1 つの木から出るので比べない。
// WhyNot: mod TestRender3dWgslPairs にしない — 比べる GLSL の関数は Render3dGlsl の pub でない関数で、子のモジュールからしか呼べない。
mod Render3dGlsl.TestRender3dWgslPairs {

    /// 字 s の数のリテラル（名前の途中の数字 — ivec2・vec2i・f32 — は数えない）を出てくる順に。符号は見ない。
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

    /// 宣言の行（uniform）を外した字（WGSL は宣言を Render3dWgsl.sceneDeclarations にまとめている）。
    def withoutUniforms(s: String): String =
        String.lines(s) |> List.filter(l -> not String.startsWith({ prefix = "uniform " }, l)) |> List.join("\n")

    /// s の marker から後ろ（無ければ空）。
    def startingAt(marker: String, s: String): String =
        match String.indexOf({ substr = marker }, s) {
            case Some(i) => String.slice({ start = i }, { end = String.length(s) }, s)
            case None    => ""
        }

    @Test
    def testShadowPcfHasTheSameNumbers(): Unit \ Assert =
        Assert.assertEq(expected = numbersIn(withoutUniforms(Render3dGlsl.shadowSource())), numbersIn(Render3dWgsl.shadowSource()))

    @Test
    def testNormalMapHasTheSameNumbers(): Unit \ Assert =
        Assert.assertEq(expected = numbersIn(Render3dGlsl.applyNormalMapSource()), numbersIn(Render3dWgsl.applyNormalMapSource()))

    /// 環境マップの読み（向き → 座標・mip のレベルを決めて読む所）。向きの式は木から作るので外す。
    @Test
    def testEnvironmentReadHasTheSameNumbers(): Unit \ Assert =
        let glsl = startingAt("vec2 environmentUv(", Render3dGlsl.environmentSource());
        let wgsl = startingAt("fn environmentUv(", Render3dWgsl.environmentSource());
        Assert.assertEq(expected = (false, numbersIn(glsl)), (String.isEmpty(wgsl), numbersIn(wgsl)))
}
