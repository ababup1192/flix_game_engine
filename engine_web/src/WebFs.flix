// WebFs — ブラウザ版の Fs の handler。読むのは書き出しの時に wasm へ埋め込んだ素材（fge.web.EmbeddedData・project.json の web.embed）と、
// 起動の前に取ってきた素材の表（fge.web.AssetTable）で、
// saves/ の下だけは localStorage（鍵の頭にゲームの id）を読み書きする。saves/ の外への書き込みは何もせず Ok を返す
// （配ったゲームが書くのはセーブだけ。ほかは開発の道具の物で、ブラウザでは行き先が無い）。
pub mod WebFs {
    import fge.web.AssetTable
    import fge.web.Browser
    import fge.web.EmbeddedCodec
    import fge.web.EmbeddedData
    import fge.web.LocalStorage
    import java.lang.{String => JString}

    /// 埋め込んだ素材 1 本が EmbeddedData.table の何番目（start）から何本の切れ端か（index は鍵の列を分ける番号）。
    type alias EmbeddedSpan = { start = Int32, count = Int32, index = Int32 }

    /// 埋め込んだ素材の位置と、戻した物の写し（初めて読んだ時に戻す）。
    type alias Embedded = { spans = Map[String, EmbeddedSpan], decoded = Ref[Map[String, Array[Int8, Static]], Static] }

    /// Fs.FileRead を埋め込んだ素材・素材の表・localStorage で受ける。
    pub def runFileRead(f: Unit -> a \ ef): a \ (ef - Fs.FileRead) + IO =
        let embedded = { spans = embeddedSpans(), decoded = Ref.fresh(Static, Map.empty()) };
        run f() with handler Fs.FileRead {
            def read(path, k)      = k(readText(embedded, path))
            def readLines(path, k) = k(Result.map(String.lines, readText(embedded, path)))
            def readBytes(path, k) = k(readBytes(embedded, path))
        }

    /// Fs.FileWrite を受ける。saves/ の下は localStorage へ書き、ほかは何もせず Ok。
    pub def runFileWrite(f: Unit -> a \ ef): a \ (ef - Fs.FileWrite) + IO =
        let warned: Ref[Set[String], Static] = Ref.fresh(Static, Set.empty());
        let writeText = (path, text) -> if (isSave(path)) writeSave(path, text) else skipped(warned, path);
        let appendText = (path, text) -> if (isSave(path)) appendSave(path, text) else skipped(warned, path);
        run f() with handler Fs.FileWrite {
            def write(data, path, k)       = k(writeText(path, data#str))
            def writeLines(data, path, k)  = k(writeText(path, String.intercalate("\n", data#lines) + "\n"))
            def writeBytes(_data, path, k) = k(unsupportedIn(path, "writeBytes"))
            def append(data, path, k)      = k(appendText(path, data#str))
            def appendLines(data, path, k) = k(appendText(path, String.intercalate("\n", data#lines) + "\n"))
            def appendBytes(_data, path, k) = k(unsupportedIn(path, "appendBytes"))
            def truncate(path, k)          = k(writeText(path, ""))
            def copyWith(src, dst, _opts, k) = k(if (isSave(dst)) copySave(src#src, dst) else skipped(warned, dst))
            def moveWith(src, dst, _opts, k) = k(moveSave(src#src, dst))
            def delete(path, k)            = k(deleteSave(path))
            def mkDir(_dir, k)             = k(Ok(()))
            def mkDirs(_dir, k)            = k(Ok(()))
            def mkTempDir(prefix, k)       = k(Err(IoError.IoError(IoError.ErrorKind.Unsupported, "ブラウザ版は一時のフォルダを作れない（${prefix}）")))
        }

    /// 道の頭の "./" を外し、区切りを / にそろえる。
    def normalize(path: String): String =
        let slashed = String.replace({src = "\\"}, {dst = "/"}, path);
        if (String.startsWith({prefix = "./"}, slashed)) normalize(String.drop(2, slashed)) else slashed

    /// セーブの道か（saves/ の下）。
    def isSave(path: String): Bool = String.startsWith({prefix = "saves/"}, normalize(path))

    /// localStorage の鍵（ゲームの id / 道）。同じ origin に並ぶ別のゲームとぶつからないよう頭に id を付ける。
    def keyOf(path: String): String \ IO = "${Browser.gameId()}/${normalize(path)}"

    def notFound(path: String): IoError = IoError.IoError(IoError.ErrorKind.NotFound, path)

    def readText(embedded: Embedded, path: String): Result[IoError, String] \ IO =
        if (isEmbedded(embedded, path)) Result.map(bytes -> unsafe IO { new JString(bytes, "UTF-8") }, embeddedBytes(embedded, path))
        else readStoredText(path)

    def readStoredText(path: String): Result[IoError, String] \ IO =
        let text = if (isSave(path)) LocalStorage.get(keyOf(path)) else AssetTable.text(normalize(path));
        if (Object.isNull(text)) Err(notFound(path)) else Ok(text)

    def readBytes(embedded: Embedded, path: String): Result[IoError, Vector[Int8]] \ IO =
        if (isEmbedded(embedded, path)) Result.map(Array.toVector, embeddedBytes(embedded, path))
        else {
            let bytes = AssetTable.bytes(normalize(path));
            if (Object.isNull(bytes)) Err(notFound(path)) else Ok(Array.toVector(bytes))
        }

    /// EmbeddedData.table（[道, 切れ端の数, 切れ端…] の繰り返し）から道ごとの位置を引く。
    def embeddedSpans(): Map[String, EmbeddedSpan] \ IO =
        let table = EmbeddedData.table();
        let n = Array.length(table);
        def go(i, index, acc) =
            if (i + 1 >= n) acc
            else {
                let count = Int32.fromString(Array.get(i + 1, table)) |> Option.getWithDefault(0);
                go(i + 2 + count, index + 1, Map.insert(Array.get(i, table), { start = i + 2, count = count, index = index }, acc))
            };
        go(0, 0, Map.empty())

    def isEmbedded(embedded: Embedded, path: String): Bool = Map.memberOf(normalize(path), embedded#spans)

    // WhyNot: 戻せない時に素材の表へ落ちて探さない — 埋め込んだ物は表に無く、「無い」と言うと壊れた符号が隠れる。
    def embeddedBytes(embedded: Embedded, path: String): Result[IoError, Array[Int8, Static]] \ IO =
        let key = normalize(path);
        match Map.get(key, Ref.get(embedded#decoded)) {
            case Some(bytes) => Ok(bytes)
            case None => match Map.get(key, embedded#spans) {
                case None => Err(notFound(path))
                case Some(span) =>
                    let bytes = EmbeddedCodec.decode(EmbeddedData.table(), span#start, span#count, EmbeddedData.seed(), span#index);
                    if (Object.isNull(bytes)) Err(IoError.IoError(IoError.ErrorKind.InvalidData, "wasm に埋め込んだ ${path} を戻せない（書き出し直す）"))
                    else {
                        Ref.put(Map.insert(key, bytes, Ref.get(embedded#decoded)), embedded#decoded);
                        Ok(bytes)
                    }
            }
        }

    // WhyNot: saves/ の外への書き込みを何も知らせずに捨てない — 「書いたのに残らない」の元が追えない。
    /// saves/ の外への書き込みは何もせず Ok。道ごとに初回 1 回だけ言う。
    def skipped(warned: Ref[Set[String], Static], path: String): Result[IoError, Unit] \ IO =
        if (Set.memberOf(normalize(path), Ref.get(warned))) Ok(())
        else {
            Ref.put(Set.insert(normalize(path), Ref.get(warned)), warned);
            Log.fellBackThen("WebFs", path, "書かない", "saves/ の外はブラウザ版に行き先が無い", Ok(()))
        }

    def writeSave(path: String, text: String): Result[IoError, Unit] \ IO =
        if (LocalStorage.set(keyOf(path), text)) Ok(())
        else Err(IoError.IoError(IoError.ErrorKind.PermissionDenied, "localStorage に書けない（${path}）"))

    def appendSave(path: String, text: String): Result[IoError, Unit] \ IO =
        let before = LocalStorage.get(keyOf(path));
        writeSave(path, (if (Object.isNull(before)) "" else before) + text)

    def copySave(src: String, dst: String): Result[IoError, Unit] \ IO =
        Result.flatMap(text -> writeSave(dst, text), readStoredText(src))

    // WhyNot: saves/ の外へ移す時に元を消さない — 行き先へは書けないので、セーブが消えるだけになる。
    def moveSave(src: String, dst: String): Result[IoError, Unit] \ IO =
        if (not isSave(dst)) Err(IoError.IoError(IoError.ErrorKind.Unsupported, "ブラウザ版は saves/ の外へ移せない（${src} → ${dst}）"))
        else Result.flatMap(_ -> deleteSave(src), copySave(src, dst))

    def deleteSave(path: String): Result[IoError, Unit] \ IO =
        if (not isSave(path)) Ok(())
        else if (LocalStorage.remove(keyOf(path))) Ok(())
        else Err(IoError.IoError(IoError.ErrorKind.PermissionDenied, "localStorage から消せない（${path}）"))

    def unsupportedIn(path: String, op: String): Result[IoError, Unit] =
        if (isSave(path)) Err(IoError.IoError(IoError.ErrorKind.Unsupported, "ブラウザ版のセーブは字だけ（${op}・${path}）"))
        else Ok(())
}
