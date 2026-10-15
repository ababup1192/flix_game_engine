// AtomicFile — ファイルを「書き終えてから置き換える」書き出し。
//
// 同じディレクトリの一時ファイルへ全部書いてから、rename で目的のパスへ入れ替える。読む側には
// 「前の中身」か「新しい中身」のどちらかしか見えず、書きかけのファイルは残らない。
// 走行中のゲームの裏で描き出していて途中でウィンドウを閉じた・make と同時に書いた、のような
// 途中で止まる書き出し（PNG・WAV）に使う。
pub mod AtomicFile {
    import java.io.File

    /// `path` へ書く。`fill` は渡された一時ファイルへ中身を全部書く関数。
    /// 書き終えたら一時ファイルを `path` へ rename する（親ディレクトリは無ければ作る）。
    /// 書く前に、同じ名前の前の一時ファイル（途中で止まった書き出しの残り）を消す。
    // WhyNot: Files.move(ATOMIC_MOVE) を使わない — 可変長引数（CopyOption...）を Flix から
    // 渡すのに配列と region が要る割に、同じディレクトリ内の rename は POSIX でもともと原子的で、
    // File.renameTo がそれを呼ぶ。一時ファイルを同じディレクトリに置くのはこのため
    // （別のファイルシステムをまたぐと rename はコピーになり、原子性が失われる）。
    // WhyNot: fill の例外を受けない — 受けて bug! に包むと元の例外の種類とスタックが消える。
    // そのとき残る一時ファイルは、同じパスへ次に書くときに消える。
    pub def write(path: String, fill: File -> Unit \ IO): Unit \ IO =
        let target = new File(path);
        let parent = target.getAbsoluteFile().getParentFile();
        if (not Object.isNull(parent)) discard parent.mkdirs() else ();
        let prefix = ".${target.getName()}.";
        deleteLeftovers(parent, prefix);
        let temp = File.createTempFile(prefix, ".tmp", parent);
        fill(temp);
        if (temp.renameTo(target)) ()
        else {
            // macOS / Linux の rename は置き換えるが、置き換えない実装（Windows）だけ先に消す。
            discard target.delete();
            if (temp.renameTo(target)) ()
            else {
                discard temp.delete();
                Log.warn("AtomicFile: ${path} を置き換えられませんでした（前の中身のまま）")
            }
        }

    /// dir の中の「prefix で始まり .tmp で終わる」ファイルを消す（前の書き出しが途中で止まった残り）。
    def deleteLeftovers(dir: File, prefix: String): Unit \ IO =
        let names = dir.list();
        if (Object.isNull(names)) ()
        else Array.forEach(name ->
            if (String.startsWith(prefix = prefix, name) and String.endsWith(suffix = ".tmp", name))
                discard (new File(dir, name)).delete()
            else (), names)
}
