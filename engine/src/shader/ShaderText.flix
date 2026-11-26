// ShaderText — シェーダーの字を、字のまま見る小さな判定（GLSL と WGSL に共通の形だけ）。
// 3D の描き手の木（render_gl の ShaderAst）と、ブラウザ版で前もって作った字に材質の部品を入れる所（Render3d.ShaderLibrary）と、ShaderGen のテストが同じ 1 本を使う。
pub mod ShaderText {

    /// 字が括弧なしで演算子の子に置ける形か（名前・数・欄の読み・添字・呼び出しだけで、括弧の外に空白も演算子も無い）。
    pub def isAtomText(text: String): Bool =
        let step = (acc: (Int32, Bool), ch: Char) -> {
            let (depth, ok) = acc;
            if (not ok) acc
            else if (ch == '(' or ch == '[') (depth + 1, true)
            else if (ch == ')' or ch == ']') (depth - 1, true)
            else if (depth > 0) acc
            else (depth, Char.isLetter(ch) or Char.isDigit(ch) or ch == '_' or ch == '.')
        };
        not String.isEmpty(text) and snd(String.toList(text) |> List.foldLeft(step, (0, true)))
}
