// Palette — Studio のドット絵エディタに「意味色キー → 実色」を教えるための写し。
// ゲームはこの写しを読まない（実色を決める権威は ThemeDoc.resolver ただ 1 つ）。
//
// なぜ要るか: Studio が見られるのは *.sprite.json の legend に書いた名前と
// *.theme.json にトップレベルで宣言してある色だけで、コードの中の導出
// （つやは基準色を明るく、影は暗く…）は知りようがない。名前が解けないと Studio は
// 並び順から作った仮色で塗るので、編集画面と実機で配色が食い違う。
// だから導出の結果をここへ書き出して読ませる。
//
// 生成物なので手で直さない（`make palette`。`make render-all` の前に走る）。
// テーマの色を変えたら作り直す — 忘れても TestPalette が食い違いを見つける。
mod Palette {

    use flix_game_engine::{Color, PxSpriteDoc, RenderUtil}

    pub def path(): String = "assets/rpg.palette.json"

    /// sprite Doc の legend に出てくる意味色キーを、テーマの実色へ解いた表（純粋）。
    /// 名前の重複は 1 つにまとめ、並びは名前順（書き出しが毎回同じになる）。
    pub def entriesOf(sprites: PxSpriteDoc.Doc, theme: ThemeDoc.Doc): List[(String, Color)] =
        entriesOfAll(sprites :: Nil, theme)

    /// 複数の sprite Doc の legend をまとめて 1 つの表にする。写しは 1 枚
    /// （assets/rpg.palette.json）だけ — Doc ごとに分けると paletteFile の指し先が
    /// 増えてどれが正か迷うため。
    pub def entriesOfAll(sprites: List[PxSpriteDoc.Doc], theme: ThemeDoc.Doc): List[(String, Color)] =
        sprites
            |> List.flatMap(doc -> doc#legend |> Map.valuesOf)
            |> List.distinct
            |> List.sort
            |> List.map(key -> (key, ThemeDoc.resolver(theme, key)))

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
            + "  \"//\": \"生成物（make palette）。Studio のドット絵エディタに意味色キーの実色を"
            + "教えるための写し。色を変えるのは rpg.theme.json 側。\",\n"
            + body + "\n}\n"

    /// Studio と実機の GL に渡るのは Float32 の値なので、その桁で書く。
    def channel(v: Float64): String =
        Float32.toString(RenderUtil.f32(v))

    /// 写しを書き出す。読むのは Studio だけなので、走らせるのは開発の手元だけでよい。
    pub def write(): Unit \ IO =
        let (rpg, town, theme) = run {
            (World.loadCharSprites(),
             World.loadTownSprites(),
             ThemeDoc.load(ThemeDoc.path()))
        } with Fs.FileRead.runWithIO;
        let text = toJson(entriesOfAll(rpg :: town :: Nil, theme));
        run {
            discard Fs.WriteFile.write({ str = text }, path())
        } with Fs.WriteFile.runWithFileWrite with Fs.FileWrite.runWithIO;
        println("wrote ${path()}")
}
