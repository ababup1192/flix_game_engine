// WebFs — ブラウザ版の Fs の handler。読むのは起動の前に取ってきた素材の表（fge.web.AssetTable）で、
// saves/ の下だけは localStorage（鍵の頭にゲームの id）を読み書きする。saves/ の外への書き込みは何もせず Ok を返す
// （配ったゲームが書くのはセーブだけ。ほかは開発の道具の物で、ブラウザでは行き先が無い）。
pub mod WebFs {
    import fge.web.AssetTable
    import fge.web.Browser
    import fge.web.LocalStorage
    import java.lang.System

    /// Fs.FileRead を素材の表と localStorage で受ける。
    pub def runFileRead(f: Unit -> a \ ef): a \ (ef - Fs.FileRead) + IO =
        run f() with handler Fs.FileRead {
            def read(path, k)      = k(readText(path))
            def readLines(path, k) = k(Result.map(String.lines, readText(path)))
            def readBytes(path, k) = k(readBytes(path))
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
            def copyWith(src, dst, _opts, k) = k(copySave(src#src, dst))
            def moveWith(src, dst, _opts, k) = k(Result.flatMap(_ -> deleteSave(src#src), copySave(src#src, dst)))
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

    def readText(path: String): Result[IoError, String] \ IO =
        let text = if (isSave(path)) LocalStorage.get(keyOf(path)) else AssetTable.text(normalize(path));
        if (Object.isNull(text)) Err(notFound(path)) else Ok(text)

    def readBytes(path: String): Result[IoError, Vector[Int8]] \ IO =
        let bytes = AssetTable.bytes(normalize(path));
        if (Object.isNull(bytes)) Err(notFound(path)) else Ok(Array.toVector(bytes))

    // WhyNot: saves/ の外への書き込みを黙って捨てない — 「書いたのに残らない」の元が追えない。
    /// saves/ の外への書き込みは何もせず Ok。道ごとに初回 1 回だけ言う。
    def skipped(warned: Ref[Set[String], Static], path: String): Result[IoError, Unit] \ IO =
        if (Set.memberOf(normalize(path), Ref.get(warned))) Ok(())
        else {
            Ref.put(Set.insert(normalize(path), Ref.get(warned)), warned);
            System.err.println("[WebFs] ${path} は saves/ の外なのでブラウザ版では書かない");
            Ok(())
        }

    def writeSave(path: String, text: String): Result[IoError, Unit] \ IO =
        if (LocalStorage.set(keyOf(path), text)) Ok(())
        else Err(IoError.IoError(IoError.ErrorKind.PermissionDenied, "localStorage に書けない（${path}）"))

    def appendSave(path: String, text: String): Result[IoError, Unit] \ IO =
        let before = LocalStorage.get(keyOf(path));
        writeSave(path, (if (Object.isNull(before)) "" else before) + text)

    def copySave(src: String, dst: String): Result[IoError, Unit] \ IO =
        if (not isSave(dst)) Ok(()) else Result.flatMap(text -> writeSave(dst, text), readText(src))

    def deleteSave(path: String): Result[IoError, Unit] \ IO =
        if (not isSave(path)) Ok(())
        else if (LocalStorage.remove(keyOf(path))) Ok(())
        else Err(IoError.IoError(IoError.ErrorKind.PermissionDenied, "localStorage から消せない（${path}）"))

    def unsupportedIn(path: String, op: String): Result[IoError, Unit] =
        if (isSave(path)) Err(IoError.IoError(IoError.ErrorKind.Unsupported, "ブラウザ版のセーブは字だけ（${op}・${path}）"))
        else Ok(())
}
