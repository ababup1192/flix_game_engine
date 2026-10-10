// 色票 Doc の書き出し — Studio が読める外形（version / note / colors）で、
// 導いた色がそのまま 16 進で載ること。
mod TestPaletteExport {
    import java.io.File

    def tones(): Map[String, Color] =
        PaletteExport.fromKeys(key -> match key {
            case "leaf1" => Color.rgb8(31, 106, 51)
            case "leaf2" => Color.rgb8(47, 143, 69)
            case _       => Color.rgb8(0, 0, 0)
        }, "leaf1" :: "leaf2" :: Nil)

    @Test
    def testBuildPutsResolvedColorsUnderColors(): Unit \ Assert =
        // 読み戻して colors の中身が resolver の答えと一致する（Studio が引く道）。
        let back = PaletteExport.build({ note = "n", colors = tones() })
            |> DocJson.parse
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(m -> Map.get("colors", m))
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.map(m -> (Map.get("leaf1", m), Map.get("leaf2", m)));
        Assert.assertEq(
            expected = Some((Some(Util.Json.Json.JString("#1f6a33")),
                             Some(Util.Json.Json.JString("#2f8f45")))),
            back)

    @Test
    def testBuildCarriesVersionAndNote(): Unit \ Assert =
        // 外形 6 点（version と note）を落とすと Studio のフォームに出ない。
        let top = PaletteExport.build({ note = "手で編集しない", colors = tones() })
            |> DocJson.parse
            |> Option.flatMap(JsonCodec.expectObject);
        Assert.assertEq(
            expected = (Some(1), Some("手で編集しない")),
            (top |> Option.map(m -> JsonCodec.intOr("version", -1, m)),
             top |> Option.flatMap(m -> Map.get("note", m)) |> Option.flatMap(JsonCodec.expectString)))

    @Test
    def testWriteSkipsWhenContentIsSame(): Unit \ { Assert, IO } =
        // 同じ中身の 2 回目は書かない（更新時刻が進むと Studio が描き出しを起こし直す）。
        let file = File.createTempFile("palette", ".json");
        file.deleteOnExit();
        let path = file.getPath();
        let spec = { note = "n", colors = tones() };
        discard run { PaletteExport.write(path, spec) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO;
        discard file.setLastModified(1000i64);
        discard run { PaletteExport.write(path, spec) } with Fs.FileRead.runWithIO with Fs.FileWrite.runWithIO;
        Assert.assertEq(expected = 1000i64, file.lastModified())
}
