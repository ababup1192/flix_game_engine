// RenderFontCache — 焼き上がったフォントアトラスをディスクに取っておき、次の起動で読むだけにする。
//
// 日本語フォントは 1 本で数千字あり、全部を距離場にするのに十数秒かかる。焼き上がりは
// 同じ TTF・同じ大きさ・同じ作り方なら毎回まったく同じなので、1 度作ったら取っておけばよい。
//
// **読めないときは黙って作り直す。** 取っておいた物が壊れていても・古くても・書き込めなくても、
// 起動が止まることは無い（遅くなるだけ）。
mod RenderFontCache {
    import java.io.File
    import java.io.FileInputStream
    import java.io.FileOutputStream
    import java.io.ByteArrayOutputStream
    import java.io.ByteArrayInputStream
    import java.io.DataOutputStream
    import java.io.DataInputStream
    import java.lang.System
    import java.lang.Exception
    import java.nio.ByteBuffer
    import java.nio.ByteOrder
    import java.nio.file.Files
    import java.security.MessageDigest
    import java.util.zip.CRC32

    /// ファイルの目印。形を変えたらここも変える（前の形のファイルは読まずに捨てる）。
    def magic(): Int64 = 0x46474546_4F4E5402i64

    /// 1 字ぶんの記録の長さ: 文字番号(4) + 数値 9 個(8×9)。
    def glyphBytes(): Int32 = 76

    /// 取っておく場所。FLIX_GE_CACHE_DIR があればそこ、無ければ ~/.cache/flix_game_engine/font。
    /// 配布した .app の中はプロジェクト配下が書けないことがあるのでホーム側に置く。
    /// 同じ TTF を使う別のゲームどうしで使い回せるのも利点。
    /// テストは環境変数を後から差し替えられないので、システムプロパティ側の指定も見る。
    pub def dir(): String \ IO =
        let prop = System.getProperty("flix.ge.cacheDir");
        let custom = System.getenv("FLIX_GE_CACHE_DIR");
        if (not Object.isNull(prop)) prop
        else if (not Object.isNull(custom)) custom
        else "${System.getProperty("user.home")}/.cache/flix_game_engine/font"

    /// FLIX_GE_NO_FONT_CACHE=1 で取っておくのをやめる（作り直しを確かめたいとき）。
    pub def enabled(): Bool \ IO =
        let value = System.getenv("FLIX_GE_NO_FONT_CACHE");
        Object.isNull(value) or value == "0"

    /// 起動時のフォントの読み方。生成した .fontatlas（loadBaked）が使えればそれを読み、使えなければ
    /// project.json の `glyphs` の選び方で loadOrBake する。GL と WebGPU の起動はどちらもこれを通る。
    /// 出しうる字の走査（glyphs: used）は、生成した物を使えないフォントが出た時に 1 回だけ流す。
    pub def startupLoader(rootDir: String, glyphs: String): (RenderAsset.FontEntry, (Int32, Int32) -> Unit \ IO) -> RenderFont.BakedFont \ IO \ IO =
        let mode = RenderFont.glyphModeOf(glyphs);
        let wantedRef: Ref[Option[Option[Set[Int32]]], Static] = Ref.fresh(Static, None);
        let wanted = () -> match Ref.get(wantedRef) {
            case Some(w) => w
            case None =>
                let w = RenderFont.startupGlyphs(rootDir, mode);
                Option.forEach(cps -> println("[RenderFont] このゲームが出しうる字: ${Set.size(cps)} 字"), w);
                Ref.put(Some(w), wantedRef);
                w
        };
        (entry, onGlyph) -> {
            let fontBytes = readAllBytes(entry#path);
            match bakedForStartup(rootDir, mode, entry, fontBytes) {
                case Some(baked) => baked
                case None        => loadOrBake(entry, fontBytes, wanted(), onGlyph)
            }
        }

    /// 生成した物を起動に使えるなら Some。使わない選び方（glyphs: all・FLIX_GE_BAKED_FONT=0）と、無い時は黙って None。
    /// 有るのに使えない時は 1 行言って None。
    def bakedForStartup(rootDir: String, mode: RenderFont.GlyphMode, entry: RenderAsset.FontEntry,
                        fontBytes: Array[Int8, Static]): Option[RenderFont.BakedFont] \ IO =
        let skip = match mode {
            case RenderFont.GlyphMode.All => true
            case _                        =>
                let value = System.getenv("FLIX_GE_BAKED_FONT");
                not Object.isNull(value) and value == "0"
        };
        if (skip) None
        else loadBaked(rootDir, entry, fontBytes) |> Option.flatMap(reportBaked(entry))

    def reportBaked(entry: RenderAsset.FontEntry, loaded: Result[String, RenderFont.BakedFont]): Option[RenderFont.BakedFont] \ IO =
        match loaded {
            case Ok(baked) =>
                println("[RenderFont] '${entry#name}': 生成した .fontatlas を読みました"
                    + "（${Map.size(baked#atlas#glyphs)} 字・${baked#side}x${baked#side}）");
                Some(baked)
            case Err(reason) =>
                warnBakedUnusable(entry, reason);
                None
        }

    def warnBakedUnusable(entry: RenderAsset.FontEntry, reason: String): Unit \ IO =
        checked_ecast(Log.fellBack("font", "'${entry#name}' の生成した .fontatlas", "起動時の生成（project.json の glyphs）", reason))

    /// 生成した .fontatlas を置く所。開発中は build/font-atlas（bin/fge font-bake の出力）、配った物は font-atlas（fge dist が詰める）。
    def bakedDirs(rootDir: String): List[String] =
        "${rootDir}/build/font-atlas" :: "${rootDir}/font-atlas" :: Nil

    /// 生成した .fontatlas の 1 本。無ければ None（正常）。有れば、使える形（字を足せる辺へ移した物）か使えない理由。
    /// 使えるのは、隣の .key が今の bakedKeyOf と同じで・decode が通り・生成のサイズ（bakeSize）を縮めていない時。
    // WhyNot: 字の集合が古いかは見ない — 生成した後に足した字は実行中に足される（遅いのはその字だけ）。
    pub def loadBaked(rootDir: String, entry: RenderAsset.FontEntry,
                      fontBytes: Array[Int8, Static]): Option[Result[String, RenderFont.BakedFont]] \ IO =
        bakedDirs(rootDir)
            |> List.map(dir -> "${dir}/${entry#name}.fontatlas")
            |> List.find(path -> new File(path).isFile())
            |> Option.map(path -> readBaked(path, entry, fontBytes))

    def readBaked(path: String, entry: RenderAsset.FontEntry, fontBytes: Array[Int8, Static]): Result[String, RenderFont.BakedFont] \ IO =
        try {
            let keyFile = new File("${path}.key");
            if (not keyFile.isFile())
                Err("${path}.key が無い（.key を書かない古い engine の font-bake で生成した物）")
            else if (String.trim(Files.readString(keyFile.toPath())) != bakedKeyOf(fontBytes, entry#fontSize))
                Err("フォント・fontSize・engine の作り方のどれかが生成した時と違う（make font-bake で作り直す）")
            else
                decode(readAllBytes(path), "font_${entry#name}")
                    |> Option.toOk("${path} が読めない（壊れている）")
                    |> Result.flatMap(growableOf(entry))
        } catch {
            case e: Exception => Err("${path} が読めない: ${e.getMessage()}")
        }

    def growableOf(entry: RenderAsset.FontEntry, baked: RenderFont.BakedFont): Result[String, RenderFont.BakedFont] \ IO =
        if (baked#atlas#fontSize < entry#fontSize)
            Err("bakeSize を ${baked#atlas#fontSize} に縮めて生成した物（字を全部生成した時など）")
        else
            RenderFont.growableCopy(baked)
                |> Option.toOk("字が多く（${baked#side}x${baked#side}）、実行中に字を足す空きが取れない")

    /// 生成した .fontatlas の隣に置く .key の中身: フォントの中身・用意する大きさ・作り方の版。
    /// font-bake が書き、起動時に同じ関数で作った値と比べる（書く物と読む物がずれない）。
    pub def bakedKeyOf(fontBytes: Array[Int8, Static], fontSize: Float64): String \ IO =
        "${fontHash(fontBytes)}_${sanitize(Float64.toString(fontSize))}_${RenderFont.bakeVersion()}"

    /// 取ってあれば読み、無ければ生成して取っておく。fontBytes は entry#path の中身。
    pub def loadOrBake(entry: RenderAsset.FontEntry, fontBytes: Array[Int8, Static], wanted: Option[Set[Int32]],
                       onGlyph: (Int32, Int32) -> Unit \ IO): RenderFont.BakedFont \ IO =
        // 用意する字も鍵に混ぜる。混ぜないと、文言を足したのに前に生成した物を読んでしまい、
        // 足したはずの字が出ないまま気付けない。
        let key = keyOf(fontBytes, entry#fontSize, wanted);
        let useCache = enabled();
        match (if (useCache) load(key, entry) else None) {
            case Some(baked) =>
                println("[RenderFont] '${entry#name}': 焼き上がりを取ってあったので読み込みました"
                    + "（${baked#side}x${baked#side}）");
                baked
            case None =>
                let baked = RenderFont.bakeFontCpu(entry, fontBytes, wanted, onGlyph);
                if (useCache) store(key, baked) else ();
                baked
        }

    /// TTF の中身・用意する大きさ・作り方のバージョンから決まる見分けの印。ファイルの置き場所は含めない —
    /// 同じ字形なら、どこに置いてあっても同じ物を使い回せる。
    /// 中身から作るので、起動のたびに TTF を読み直して数え直す手間はかかる（10MB 級で数十 ms）。
    pub def keyOf(fontBytes: Array[Int8, Static], fontSize: Float64,
                  wanted: Option[Set[Int32]]): String \ IO =
        let marks = match wanted {
            case None      => "all"
            case Some(cps) => "${Set.size(cps)}x${Set.foldLeft((acc, cp) -> acc + cp, 0, cps)}"
        };
        "${fontHash(fontBytes)}_${sanitize(Float64.toString(fontSize))}${sanitize(marks)}_${RenderFont.bakeVersion()}"

    /// 字形そのものを表す 16 桁。区切りに使う "_" を含まない形にしてある —
    /// 含むと、同じフォントの古い大きさを片付ける prefix 照合が他のフォントまで巻き込む。
    def fontHash(fontBytes: Array[Int8, Static]): String \ IO =
        let digest = MessageDigest.getInstance("SHA-256");
        let hash = digest.digest(fontBytes);
        List.range(0, 8) |> List.foldLeft((acc, i) -> {
            let b = Int32.bitwiseAnd(Int8.toInt32(Array.get(i, hash)), 255);
            "${acc}${hexDigit(b / 16)}${hexDigit(Int32.remainder(b, 16))}"
        }, "")

    def hexDigit(v: Int32): String =
        String.slice({ start = v }, { end = v + 1 }, "0123456789abcdef")

    def sanitize(s: String): String =
        s |> String.map(c -> if (Char.isLetter(c) or Char.isDigit(c)) c else 'x')

    /// 読めたら Some。無い・壊れている・食い違うときは None（そのまま作り直せばよい）。
    pub def load(key: String, entry: RenderAsset.FontEntry): Option[RenderFont.BakedFont] \ IO =
        try {
            let path = pathOf(key);
            if (not new File(path).exists()) None
            else decode(readAllBytes(path), "font_${entry#name}")
        } catch {
            case _: Exception => None
        }

    /// アトラスのファイルの中身（store が書く形）を読む。壊れている・版が違う・検算が合わないときは None。
    /// ファイルを開かないので、ファイルの無い機種（アセットバンドルの byte 列）からも同じ物で読める。
    /// pixels は GC に任せる直接バッファ（起動の間ずっと持つ）。
    pub def decode(bytes: Array[Int8, Static], textureName: String): Option[RenderFont.BakedFont] \ IO =
        let input = ByteBuffer.wrap(bytes);
        if (Array.length(bytes) < headerSize() or input.getLong() != magic() or input.getInt() != RenderFont.bakeVersion()) None
        else {
            let side = input.getInt();
            let fontSize = input.getDouble();
            let ascent = input.getDouble();
            let descent = input.getDouble();
            let lineGap = input.getDouble();
            let glyphCount = input.getInt();
            // 壊れたファイルの出鱈目な数でいきなり大きな置き場を取らないよう、ありえる範囲かどうかを先に見る。
            let tableBytes = glyphCount * glyphBytes();
            let pixelBytes = side * side;
            if (side <= 0 or side > 8192 or glyphCount < 0 or glyphCount > 200000
                or Array.length(bytes) != headerSize() + tableBytes + pixelBytes + 16) None
            else {
                let table: Array[Int8, Static] = Array.empty(Static, tableBytes);
                discard input.get(table);
                let pixelStart = headerSize() + tableBytes;
                let pixels = ByteBuffer.allocateDirect(pixelBytes).order(ByteOrder.nativeOrder());
                discard pixels.put(bytes, pixelStart, pixelBytes);
                discard pixels.position(0);
                discard input.position(pixelStart + pixelBytes);
                let storedTable = input.getLong();
                let storedPixels = input.getLong();
                let crc = new CRC32();
                crc.update(bytes, pixelStart, pixelBytes);
                // 字の表の検算も見るのが肝。ここが壊れた物を通すと、絵は出るのに
                // 字の置き場所だけがずれる — 2 回目の起動でだけ字が乱れる形になり、一番気付きにくい。
                if (checksumOf(table) != storedTable or crc.getValue() != storedPixels) None
                else Some({
                    atlas = { textureName = textureName,
                              fontSize = fontSize,
                              textureSize = Int32.toFloat64(side),
                              ascent = ascent, descent = descent, lineGap = lineGap,
                              glyphs = decodeGlyphs(table, glyphCount) },
                    side = side, pixels = pixels })
            }
        }

    /// 頭の決まった大きさ（magic・版・side・fontSize・ascent・descent・lineGap・字の数）。
    def headerSize(): Int32 = 8 + 4 + 4 + 8 * 4 + 4

    /// 焼き上がりを取っておく。書けなくても黙って諦める（次の起動が遅いだけ）。
    /// 途中まで書いたファイルが残らないよう、別名で書いてから置き換える。
    pub def store(key: String, baked: RenderFont.BakedFont): Unit \ IO =
        try {
            discard new File(dir()).mkdirs();
            let tmp = "${pathOf(key)}.${System.nanoTime()}.tmp";
            writeFile(tmp, encode(baked));
            // 書き終えてから名前を付け替える。途中まで書いたファイルを誰かが読むことが無い。
            let target = new File(pathOf(key));
            let tmpFile = new File(tmp);
            if (not tmpFile.renameTo(target)) {
                discard target.delete();
                discard tmpFile.renameTo(target)
            } else ();
            dropStaleSiblings(key, "${key}.fontatlas")
        } catch {
            case _: Exception => ()
        }

    /// 生成したアトラスをファイルの中身（decode と対の形）にする: 頭・字の表・画素・字の表の検算・画素の検算。
    /// キャッシュのファイルも書き出しに同梱するファイルもこれ 1 つで作る（書き方が 2 つあると、ずれた片方だけ読めなくなる）。
    pub def encode(baked: RenderFont.BakedFont): Array[Int8, Static] \ IO =
        let head = headerBytes(baked);
        let table = glyphTableBytes(baked);
        let pixelBytes = baked#side * baked#side;
        let pixels: Array[Int8, Static] = Array.empty(Static, pixelBytes);
        discard baked#pixels.position(0);
        discard baked#pixels.get(pixels);
        discard baked#pixels.position(0);
        let crc = new CRC32();
        crc.update(pixels);
        let bos = new ByteArrayOutputStream(Array.length(head) + Array.length(table) + pixelBytes + 16);
        let out = new DataOutputStream(bos);
        out.write(head);
        out.write(table);
        out.write(pixels);
        out.writeLong(checksumOf(table));
        out.writeLong(crc.getValue());
        out.flush();
        bos.toByteArray()

    /// 中身を path へそのまま書く。書けなければ例外のまま返す（諦め方は呼び手が決める）。
    pub def writeFile(path: String, bytes: Array[Int8, Static]): Unit \ IO =
        let fos = new FileOutputStream(path);
        fos.write(bytes);
        fos.close()

    // ── 内部 ──────────────────────────────────────────────────

    def pathOf(key: String): String \ IO = "${dir()}/${key}.fontatlas"

    def readAllBytes(path: String): Array[Int8, Static] \ IO =
        let fis = new FileInputStream(path);
        let bytes = fis.readAllBytes();
        fis.close();
        bytes

    def headerBytes(baked: RenderFont.BakedFont): Array[Int8, Static] \ IO =
        let bos = new ByteArrayOutputStream();
        let out = new DataOutputStream(bos);
        out.writeLong(magic());
        out.writeInt(RenderFont.bakeVersion());
        out.writeInt(baked#side);
        out.writeDouble(baked#atlas#fontSize);
        out.writeDouble(baked#atlas#ascent);
        out.writeDouble(baked#atlas#descent);
        out.writeDouble(baked#atlas#lineGap);
        out.writeInt(Map.size(baked#atlas#glyphs));
        out.flush();
        bos.toByteArray()

    def glyphTableBytes(baked: RenderFont.BakedFont): Array[Int8, Static] \ IO =
        let bos = new ByteArrayOutputStream();
        let out = new DataOutputStream(bos);
        Map.forEach((cp, gm) -> {
            out.writeInt(cp);
            out.writeDouble(gm#xOff); out.writeDouble(gm#yOff);
            out.writeDouble(gm#glyphW); out.writeDouble(gm#glyphH);
            out.writeDouble(gm#advance);
            out.writeDouble(gm#s0); out.writeDouble(gm#t0);
            out.writeDouble(gm#s1); out.writeDouble(gm#t1)
        }, baked#atlas#glyphs);
        out.flush();
        bos.toByteArray()

    def checksumOf(bytes: Array[Int8, Static]): Int64 \ IO =
        let crc = new CRC32();
        crc.update(bytes);
        crc.getValue()

    /// 同じフォントの、前の大きさ・前の作り方でできたファイルを片付ける。
    /// アトラス 1 枚は最大 64MB あり、project.json の大きさをいじるたびに積み上がると
    /// すぐ数百 MB になる。今しがた置いた物だけを残す。
    def dropStaleSiblings(key: String, keep: String): Unit \ IO =
        try {
            let prefix = String.takeWhile(c -> c != '_', key);
            if (String.isEmpty(prefix)) () else
            let files = new File(dir()).listFiles();
            if (Object.isNull(files)) ()
            else
                Array.forEach(f -> {
                    let name = f.getName();
                    if (String.startsWith({ prefix = "${prefix}_" }, name)
                            and String.endsWith({ suffix = ".fontatlas" }, name)
                            and name != keep)
                        discard f.delete()
                    else ()
                }, files)
        } catch {
            case _: Exception => ()
        }

    def decodeGlyphs(table: Array[Int8, Static], count: Int32): Map[Int32, TextLayout.GlyphMetrics] \ IO =
        let inp = new DataInputStream(new ByteArrayInputStream(table));
        // 読み出しは書いた順に 1 つずつ受け取る。レコードの中に並べて書くと、
        // どの欄から評価されるかが決まっていないぶん、順番が入れ替わりうる。
        List.range(0, count) |> List.foldLeft((acc, _i) -> {
            let cp = inp.readInt();
            let xOff = inp.readDouble();
            let yOff = inp.readDouble();
            let glyphW = inp.readDouble();
            let glyphH = inp.readDouble();
            let advance = inp.readDouble();
            let s0 = inp.readDouble();
            let t0 = inp.readDouble();
            let s1 = inp.readDouble();
            let t1 = inp.readDouble();
            let gm: TextLayout.GlyphMetrics = {
                xOff = xOff, yOff = yOff, glyphW = glyphW, glyphH = glyphH,
                advance = advance, s0 = s0, t0 = t0, s1 = s1, t1 = t1
            };
            Map.insert(cp, gm, acc)
        }, Map.empty())
}
