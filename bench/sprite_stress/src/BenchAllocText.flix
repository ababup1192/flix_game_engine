// BenchAllocText — 文字（Item.Text）の item 構築 + draw の確保バイトを測る使い捨ての入口。
// 文字はグリフ 1 つごとに Drawable と中間リストを作るので、1 文字あたりのバイトで見る。
// 実行: ../../bin/flix run --entrypoint BenchAllocText.main
mod BenchAllocText {

    use flix_game_engine::{AllocMeter, FontAtlas, Render}

    pub def main(): Unit \ IO =
        let lines = 50;
        let content = "SCORE 12345 HI 99999 x3";
        let chars = String.length(content) * lines;
        let atlas = testAtlas();
        let bytes = AllocMeter.measureBytes(5, () -> Render.draw(testItems(lines, content, atlas)));
        println("lines=${lines} chars=${chars} 構築+draw1回=${bytes}B 文字1個=${bytes / Int32.toInt64(chars)}B")

    /// タイトル画面の HUD が通る形: 色つき・折り返し無しのラベルを縦に並べる。
    def testItems(lines: Int32, content: String, atlas: FontAtlas): List[Render.PlacedItem] =
        List.range(0, lines) |> List.map(i ->
            ({ at = { x = 8.0, y = 8.0 + Int32.toFloat64(i) * 12.0 },
               item = Render.textTinted(content, atlas, 8.0, { r = 0.9, g = 0.9, b = 0.8 }, 100 + i) }:
              Render.PlacedItem))

    /// ASCII 数字と大文字だけの最小アトラス（グリフ表は計測に十分な形だけ持つ）。
    def testAtlas(): FontAtlas =
        let gm = { xOff = 0.5, yOff = -6.0, glyphW = 6.0, glyphH = 7.0,
                   advance = 7.0, s0 = 0.0, t0 = 0.0, s1 = 0.1, t1 = 0.1 };
        let glyph = (cp: Int32) -> (cp, gm);
        let cps = List.range(32, 127);
        { textureName = "font_test",
          textureSize = 256.0,
          fontSize = 8.0,
          ascent = 7.0,
          descent = 2.0,
          lineGap = 1.0,
          glyphs = List.toMap(List.map(glyph, cps)) }
}
