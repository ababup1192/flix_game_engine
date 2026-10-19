// App.GameRegistry — DEBUG で起動したゲームの命令口の書き置き（~/.flix_ge_studio/games.json）。
//
// Studio が起こしたゲームは Studio が DEBUG_HTTP_PORT を渡して書き置く。make debug や VS Code から起こした
// ゲームは、命令口が空いたポートを自分で取って（DEBUG_HTTP_PORT が無い時）、同じ書き置きに自分を書く。
// 書き置きはこの 1 本だけ（Studio の「この行へ飛ばす」と bin/fge talk goto が同じ所を読む）。
//
//   { "games": [ { "dir": "<ゲームの根の実パス>", "pid": "<pid>", "port": "<ポート>" }, … ] }
//
// 値はどれも文字列（Studio の Game.entryJson と同じ形）。同じ dir の古い記録は上書きし、閉じる時に自分の行を消す。
// 書けなくてもゲームは止めない（書き置きは保険）。
pub mod App.GameRegistry {
    use Util.Json.Json
    use Util.Json.Json.{JObject, JArray, JString}

    import java.lang.System
    import java.lang.ProcessHandle
    import java.lang.Throwable
    import java.io.{File => JFile}
    import java.io.FileOutputStream
    import java.nio.file.Files
    import java.lang.{String => JavaString}
    import java.lang.Runtime
    import java.lang.Thread
    import java.util.concurrent.Callable
    import java.util.concurrent.FutureTask

    /// 書き置き 1 行。
    pub type alias Entry = { dir = String, pid = String, port = String }

    // ── 純粋なルール ──

    /// 書き置きの中身から行を読む（読めない行は捨てる・読めない中身は空）。
    pub def entriesOf(text: String): List[Entry] =
        DocJson.parse(text)
            |> Option.flatMap(JsonCodec.expectObject)
            |> Option.flatMap(Map.get("games"))
            |> Option.flatMap(JsonCodec.decodeList(json -> JsonCodec.expectObject(json) |> Option.map(obj ->
                { dir = JsonCodec.stringOr("dir", "", obj), pid = JsonCodec.stringOr("pid", "", obj),
                  port = JsonCodec.stringOr("port", "", obj) })))
            |> Option.map(List.filter(entry -> entry#dir != ""))
            |> Option.getWithDefault(Nil)

    /// entry を足す（同じ dir の古い行は外す）。
    pub def withEntry(entry: Entry, entries: List[Entry]): List[Entry] =
        List.append(entries |> List.filter(other -> other#dir != entry#dir), entry :: Nil)

    /// dir の行のうち pid が自分の物だけを外す（後から同じ dir で起こしたゲームの行は残す）。
    pub def withoutEntry(dir: String, pid: String, entries: List[Entry]): List[Entry] =
        entries |> List.filter(other -> not (other#dir == dir and other#pid == pid))

    /// 書き置きの中身。
    pub def textOf(entries: List[Entry]): String =
        let rows = entries |> List.map(entry -> JObject(Map#{
            "dir" => JString(entry#dir), "pid" => JString(entry#pid), "port" => JString(entry#port) }));
        Util.Json.toPrettyString(2, JObject(Map#{ "games" => JArray(List.toVector(rows)) })) + "\n"

    // ── 読み書き ──

    /// 書き置きの置き場。
    pub def path(): String \ IO =
        "${System.getProperty("user.home")}${JFile.separator}.flix_ge_studio${JFile.separator}games.json"

    /// 今いる所（ゲームの根）の実パス。
    pub def gameDir(): String \ IO =
        try { new JFile(".").getCanonicalPath() } catch { case _: Throwable => new JFile(".").getAbsolutePath() }

    pub def pidText(): String \ IO = "${ProcessHandle.current().pid()}"

    /// このゲームを port で書き置く。窓を閉じずに終わらせられた時（SIGTERM・make を止めた）も消えるよう、
    /// JVM の終わりにも消す（ループの後の unregister と 2 回消しても困らない）。
    // WhyNot: Runnable を匿名クラスで書かない — 手続き名の run が Flix の予約語。FutureTask は Callable から
    // Runnable を作る（RemoteDebug の描き出しのスレッドと同じ回り道）。
    pub def register(port: Int32): Unit \ IO =
        let entry = { dir = gameDir(), pid = pidText(), port = "${port}" };
        rewrite(entries -> withEntry(entry, entries));
        let hook = new FutureTask(new Callable[String] {
            def call(_this: Callable[String]): String \ IO = { unregister(); "" }
        });
        Runtime.getRuntime().addShutdownHook(new Thread(hook))

    /// このゲームの行を消す（閉じる時）。
    pub def unregister(): Unit \ IO =
        let dir = gameDir();
        let pid = pidText();
        rewrite(entries -> withoutEntry(dir, pid, entries))

    /// 読んで f を掛けて書き直す。隣に書いてから差し替える（書いている途中で落ちても壊れた JSON を残さない）。
    def rewrite(f: List[Entry] -> List[Entry]): Unit \ IO =
        try {
            let file = new JFile(path());
            discard file.getParentFile().mkdirs();
            let before = if (file.isFile()) new JavaString(Files.readAllBytes(file.toPath()), "UTF-8") else "";
            let temp = new JFile(path() + ".${pidText()}.tmp");
            let out = new FileOutputStream(temp);
            out.write(textOf(f(entriesOf(before))).getBytes("UTF-8"));
            out.close();
            // POSIX の rename は上書きで 1 回に差し替わる（Windows は上書きできないので先に消す）。
            if (not temp.renameTo(file)) { discard file.delete(); discard temp.renameTo(file) } else ()
        } catch {
            case e: Throwable => Log.warn("[remote-debug] 書き置き ${path()} を書けません — ${e.toString()}")
        }
}
