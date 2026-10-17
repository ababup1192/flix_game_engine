// Palette — Studio のドット絵エディタに「意味色キー → 実色」を教えるための写し。
// ゲームはこの写しを読まない(実色を決める権威は Theme.resolve ただ 1 つ)。
//
// なぜ要るか: Studio が legend の名前を実色に解ける道は「theme.json のトップレベルの名前 /
// sprite Doc の palette / paletteFile が指す色票」の 3 つだけ。このゲームの色は
// src/Theme.flix の defaults() がコード側に持ち、platformer.theme.json は上書き分しか
// 書かない(しかも colors の下に入れ子)ので、どの道でも解けない。解けない名前は
// Studio が並び順から作った仮色で塗るので、編集画面と実機で配色が食い違う
// (しかも見ただけでは気付けない)。だから解決の結果をここへ書き出して読ませる。
//
// 生成物なので手で直さない(`make palette`)。テーマの色や legend を変えたら作り直す。
mod Palette {

    use fge::{Color, PxSpriteDoc, RenderUtil}

    pub def path(): String = "assets/px.palette.json"

    /// sprite Doc の legend に出てくる意味色キーを、テーマの実色へ解いた表(純粋)。
    /// 名前の重複は 1 つにまとめ、並びは名前順(書き出しが毎回同じになる)。
    pub def entriesOf(sprites: PxSpriteDoc.Doc, theme: Theme.Doc): List[(String, Color)] =
        sprites#legend
            |> Map.valuesOf
            |> List.distinct
            |> List.sort
            |> List.map(key -> (key, Theme.resolve(theme, key)))

    /// 表を JSON のテキストへ。色は {"rgb":[…]} で書く — Studio の色解決が受け付ける形の中で、
    /// #rrggbb のように 256 段へ丸めないので実機の値とそのまま一致する。
    pub def toJson(entries: List[(String, Color)]): String =
        let body = entries
            |> List.map(entry -> {
                let (key, color) = entry;
                "  \"${key}\": { \"rgb\": [${channel(color#r)}, ${channel(color#g)}, ${channel(color#b)}] }"
            })
            |> List.join(",\n");
        "{\n  \"version\": 1,\n"
            + "  \"//\": \"生成物(make palette)。Studio のドット絵エディタに legend の意味色キーの"
            + "実色を教えるための写し。色を変えるのは platformer.theme.json / src/Theme.flix 側。\",\n"
            + body + "\n}\n"

    /// Studio と実機の GL に渡るのは Float32 の値なので、その桁で書く。
    def channel(v: Float64): String =
        Float32.toString(RenderUtil.f32(v))

    /// 写しを書き出す。読むのは Studio だけなので、走らせるのは開発の手元だけでよい。
    pub def write(): Unit \ IO =
        let (sprites, theme) = run {
            (PxSpriteDoc.load(World.spritePath()), Theme.load(Theme.path()))
        } with Fs.FileRead.runWithIO;
        let text = toJson(entriesOf(sprites, theme));
        run {
            discard Fs.WriteFile.write({ str = text }, path())
        } with Fs.WriteFile.runWithFileWrite with Fs.FileWrite.runWithIO;
        println("wrote ${path()}")
}
