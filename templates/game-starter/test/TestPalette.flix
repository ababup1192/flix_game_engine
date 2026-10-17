// Studio 用の色の写し（assets/__NAME__.palette.json）が古くないかを見張る 2 本。
// この写しは生成物で、Studio のドット絵エディタが「legend の名前 → 実色」を引くためだけにある。
// テーマの色やドット絵の legend を変えたのに作り直していないと、編集画面と実機で配色が
// 食い違う（しかも Studio は黙って仮色で描くので気付きにくい）。だからここで縛る。
mod TestPalette {

    use fge::PxSpriteDoc

    @Test
    def testPaletteMirrorIsFresh(): Unit \ {Assert, IO} =
        // 食い違ったら `make palette`（`make render-all` でも作り直される）。
        let (sprites, theme) = run {
            (PxSpriteDoc.load(World.spritePath()), ThemeDoc.load(ThemeDoc.path()))
        } with Fs.FileRead.runWithIO;
        let fresh = Palette.toJson(Palette.entriesOf(sprites, theme));
        let onDisk = run { Fs.ReadFile.read(Palette.path()) }
            with Fs.ReadFile.runWithFileRead with Fs.FileRead.runWithIO;
        Assert.assertEq(expected = fresh,
            onDisk |> Result.toOption |> Option.getWithDefault(""))

    @Test
    def testPaletteCoversEveryLegendName(): Unit \ {Assert, IO} =
        // legend に出てくる名前が全部そろっていること。抜けた名前は Studio が解けず、
        // その色だけ仮色で描かれる（＝ここが痩せると編集画面が嘘をつく）。
        let sprites = run { PxSpriteDoc.load(World.spritePath()) } with Fs.FileRead.runWithIO;
        let names = sprites#legend |> Map.valuesOf |> List.distinct;
        let covered = Palette.entriesOf(sprites, ThemeDoc.defaults()) |> List.map(fst);
        Assert.assertEq(expected = (List.length(names), true),
            (List.length(covered), names |> List.forAll(n -> List.memberOf(n, covered))))
}
