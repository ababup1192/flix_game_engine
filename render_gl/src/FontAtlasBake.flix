// FontAtlasBake — 窓も GL も無しに、project.json のフォントをデスクトップの起動時と同じ距離場のアトラスに生成し、
// RenderFontCache.encode の形のファイルへ書き出す。stb の無い機種（ブラウザ）へ同梱するための入口。
//
// 生成するのはデスクトップと同じ RenderFont.bakeFontCpu・書くのは同じ RenderFontCache.encode なので、
// 同じフォントと同じ字の集合なら、デスクトップがキャッシュするファイルとバイトまで同じになる。
pub mod FontAtlasBake {
    import java.io.File
    import java.lang.System
    import java.lang.Exception
    import java.nio.file.Files

    /// 書き出した 1 本のフォント。
    pub type alias Written = { name = String, path = String, side = Int32, glyphCount = Int32 }

    /// どの字を生成するか。
    pub enum Glyphs {
        /// フォントが持つ BMP の字を全部。
        case All,
        /// デスクトップの `glyphs: used` と同じ集め方（RenderFont.loadUsedGlyphs）。
        case DesktopUsed,
        /// 渡した字だけ（フォントが持たない字は落ちる。落ちた字を見つけるのは呼び手の仕事）。
        case Only(Set[Int32])
    }

    /// project.json の fonts を全部生成し、`<outDir>/<fonts[].name>.fontatlas` へ書く。並びは project.json の順。
    /// project.json が読めない時と、書けない時だけ Err。
    pub def bakeProject(rootDir: String, glyphs: Glyphs, outDir: String): Result[String, List[Written]] \ IO =
        let loaded = run { ProjectLoader.loadProject(rootDir) } with Fs.FileRead.runWithIO;
        match loaded {
            case Err(e) => Err(e)
            case Ok(loadedProject) =>
                let wanted = wantedOf(rootDir, glyphs);
                discard new File(outDir).mkdirs();
                try {
                    Ok(List.map(entry -> bakeEntryOrBug(entry, wanted, outDir), loadedProject#config#fontManifest))
                } catch {
                    case e: Exception => Err("${outDir} へ書けない: ${e.getMessage()}")
                }
        }

    /// RenderFont.bakeFontCpu に渡す形（None はフォントの字を全部）。
    def wantedOf(rootDir: String, glyphs: Glyphs): Option[Set[Int32]] \ IO = match glyphs {
        case Glyphs.All         => None
        case Glyphs.DesktopUsed => RenderFont.loadUsedGlyphs(rootDir)
        case Glyphs.Only(cps)   => Some(cps)
    }

    /// 1 本を生成して書く。返す前にファイルの中身を読み戻して、decode が通ることまで確かめる。
    def bakeEntryOrBug(entry: RenderAsset.FontEntry, wanted: Option[Set[Int32]], outDir: String): Written \ IO =
        let fontBytes = Files.readAllBytes(new File(entry#path).toPath());
        let baked = RenderFont.bakeFontCpu(entry, fontBytes, wanted, (_, _) -> checked_ecast(()));
        let bytes = RenderFontCache.encode(baked);
        let path = "${outDir}/${entry#name}.fontatlas";
        RenderFontCache.writeFile(path, bytes);
        if (Option.isEmpty(RenderFontCache.decode(Files.readAllBytes(new File(path).toPath()), "font_${entry#name}")))
            bug!("${path}: 書いたアトラスを decode が読めない — encode と decode の形がずれている")
        else
            { name = entry#name, path = path, side = baked#side, glyphCount = Map.size(baked#atlas#glyphs) }

    /// 字の集合のファイル（UTF-8 の字を並べただけ・改行も字として読まない）を読む。
    pub def readCharset(path: String): Set[Int32] \ IO =
        let text = Files.readString(new File(path).toPath());
        let cps: Array[Int32, Static] = text.codePoints().toArray();
        Array.foldLeft((acc, cp) -> if (cp < 0x20) acc else Set.insert(cp, acc), Set.empty(), cps)

    /// コマンドの入口: `<ゲームの根> <--all | --used | 字の集合のファイル> <出力のフォルダ>`。
    /// 1 本ごとに `fontatlas<TAB>名前<TAB>パス<TAB>辺<TAB>字の数` を標準出力へ 1 行出す。
    /// 失敗は終わりの番号 1・呼び方の誤りは 2。
    pub def main(): Unit \ IO =
        let args = run { Sys.Env.getArgs() } with Sys.Env.runWithIO;
        match args {
            case root :: mode :: outDir :: Nil =>
                let glyphs = match mode {
                    case "--all"  => Glyphs.All
                    case "--used" => Glyphs.DesktopUsed
                    case file     => Glyphs.Only(readCharset(file))
                };
                match bakeProject(root, glyphs, outDir) {
                    case Ok(written) =>
                        List.forEach(w -> println("fontatlas\t${w#name}\t${w#path}\t${w#side}\t${w#glyphCount}"), written)
                    case Err(e) =>
                        println("font-bake: ${e}");
                        System.exit(1)
                }
            case _ =>
                println("使い方: <ゲームの根> <--all | --used | 字の集合のファイル> <出力のフォルダ>");
                System.exit(2)
        }
}
