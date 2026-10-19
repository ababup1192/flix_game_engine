// Flow.Record — 遊んだ記録を flow と同じ文法で書く（App.launch が DEBUG の起動で debug/flow-record/latest.flow へ）。
// 再生は普通の flow と同じ（make flow FLOW=debug/flow-record/latest.flow）。World は書き出さず、
// 「始まり + 読んだファイルの中身 + 全部のフレーム」から作り直す。
//
//   # recorded 2026-10-19T12:00:00Z（App の記録・起動から全部のフレーム）
//   ready off                                   記録の手は書いたフレームでそのまま押す
//   start title +assets/rules.json=b64:…        始まり（新しく作った World が読んだファイルの中身つき）
//   wait 37f ns=16612345,…                      同じ入力が続くフレームは 1 行（実際の経過はナノ秒で全部）
//   tap Z ns=… / hold Down ns=… / release Down ns=…
//   wait 1f keys=Left,Z new=Z ns=…              押している物の丸ごと・前のフレームとの差分から出ない押した瞬間だけ new=
//   expect fp=1a2b3c4d                          60 フレームごとの指紋（App.withFingerprint）
//   reload assets/rules.json +assets/rules.json=b64:…   保存で読み直した（F1 は reload key）
//   request /cheat q=b64:…                      onRequest のルートが World を変えた
//   close / rewind 30                           窓の閉じるボタン・F8 の巻き戻しから再開
//   # ext 1200                                  それでも説明の付かない外からの変化（指紋が前のフレームの後と違う）
// 読んだファイルの拾い方: Fs.FileRead の read・readLines を包む（readBytes は拾わない —— Doc は文字のファイル）。
pub mod Flow.Record {
    use GameEngine.Key

    import java.io.FileWriter
    import java.io.File
    import java.nio.file.Files
    import java.nio.file.StandardCopyOption
    import java.time.Instant
    import java.io.IOException

    /// 記録に足す物（リモートの入口が App へ返す）: 書く行そのものか、流したフレームとその後の指紋の元。
    pub enum Item {
        case Line(String)
        case Played(App.Frame, Option[String])
    }

    /// 書いている途中の記録。同じ入力が続くフレームは pending に貯めて 1 行にまとめる。
    pub type alias Recorder = { path = String, out = FileWriter, state = Ref[Writing, Static] }

    /// まとめている行（head = ns= の前まで・ns は新しい順・single = hold の 1 フレームだけか）と、
    /// 前に書いたフレームの手の様子（再生の Flow.play が差分から押した瞬間を出すのと同じ物）。
    type alias Writing = {
        pending = Option[{ head = String, wait = Bool, ns = List[Int64] }],
        down = Set[Key], button = Bool, cursor = Option[Vec2.Vec2], count = Int32, lastFp = String
    }

    def fresh(): Writing =
        { pending = None, down = Set.empty(), button = false, cursor = None, count = 0, lastFp = "" }

    /// 記録を開く。前の回の記録は previous.flow へ残す（既定の置き場の時だけ）。開けなければ None（遊ぶのは止めない）。
    pub def open(path: String): Option[Recorder] \ IO =
        try {
            let file = new File(path);
            let parent = file.getParentFile();
            if (Object.isNull(parent)) () else discard parent.mkdirs();
            if (file.exists() and String.endsWith(suffix = "latest.flow", path))
                discard Files.move(file.toPath(), new File(String.replace(src = "latest.flow", dst = "previous.flow", path)).toPath(),
                                   StandardCopyOption.REPLACE_EXISTING)
            else ();
            let out = new FileWriter(path);
            out.write("# recorded ${Instant.now().toString()}（App の記録・起動から全部のフレーム）\nready off\n");
            out.flush();
            Some({ path = path, out = out, state = Ref.fresh(Static, fresh()) })
        } catch {
            case _: IOException => None
        }

    /// 記録の置き場（環境変数 FLOW_RECORD: 無し = debug/flow-record/latest.flow・"0" = 書かない・それ以外 = そのパス）。
    pub def pathFromEnv(): Option[String] \ IO =
        let value = Flow.Cli.envOr("FLOW_RECORD", "");
        if (value == "0") None
        else if (value == "" or value == "1") Some("debug/flow-record/latest.flow")
        else Some(value)

    def write(rec: Recorder, text: String): Unit \ IO =
        try { rec#out.write(text + "\n") } catch { case _: IOException => () }

    /// まとめている行を書き出す。
    pub def flush(rec: Recorder): Unit \ IO =
        let st = Ref.get(rec#state);
        match st#pending {
            case None => ()
            case Some(p) =>
                let count = List.length(p#ns);
                let ns = p#ns |> List.reverse |> List.map(Int64.toString) |> String.intercalate(",");
                let head = if (p#wait) "wait ${Int32.toString(count)}f" + p#head else p#head;
                write(rec, "${head} ns=${ns}");
                Ref.put({ pending = None | st }, rec#state)
        };
        try { rec#out.flush() } catch { case _: IOException => () }

    /// そのまま 1 行を書く（start・reload・request・close・rewind・# ext）。前にまとめていた行を先に書き出す。
    pub def line(rec: Recorder, text: String): Unit \ IO =
        flush(rec);
        write(rec, text);
        try { rec#out.flush() } catch { case _: IOException => () }

    /// 外から World が変わった（記録の行で説明の付かない変化）か: 指紋の元が前のフレームの後と違えば # ext を書く。
    pub def noteEntering(rec: Recorder, fingerprint: Option[String]): Unit \ IO =
        let st = Ref.get(rec#state);
        match fingerprint {
            case Some(text) if st#count > 0 and text != st#lastFp => line(rec, "# ext ${Int32.toString(st#count)}（外から World が変わった）")
            case _ => ()
        }

    /// 記録の行で World を変えた（start・reload…）後の指紋の元を覚え直す（# ext を誤って書かない）。
    pub def settle(rec: Recorder, fingerprint: Option[String]): Unit \ IO =
        match fingerprint {
            case Some(text) => Ref.put({ lastFp = text | Ref.get(rec#state) }, rec#state)
            case None       => ()
        }

    /// 実機のフレーム 1 つ（App.traceFrame に渡した Frame そのもの）と、そのフレームの後の指紋の元。
    /// 60 フレームごとに expect fp= と、指紋の元の文字のコメントを書く。
    pub def frame(rec: Recorder, frame: App.Frame, fingerprint: Option[String]): Unit \ IO =
        let st = Ref.get(rec#state);
        let pressed = Set.difference(frame#down, st#down);
        let released = Set.difference(st#down, frame#down);
        let derivedNew = pressed;
        let derivedClick = frame#mouseDown and not st#button;
        let lastCursor = st#cursor |> Option.getWithDefault({ x = -100.0, y = -100.0 });
        let derivedMoved = st#cursor |> Option.exists(p -> p#x != frame#cursor#x or p#y != frame#cursor#y);
        let opts =
            (if (frame#cursor#x != lastCursor#x or frame#cursor#y != lastCursor#y)
                 " at=${Float64.toString(frame#cursor#x)},${Float64.toString(frame#cursor#y)}" else "") +
            (if (frame#mouseDown) " mouse" else "") +
            (if (frame#wheel != 0.0) " wheel=${Float64.toString(frame#wheel)}" else "") +
            (if (frame#padTouched) " pad" else "") +
            (if (frame#justPressed != derivedNew) " new=${keysText(frame#justPressed)}" else "") +
            (if (frame#mouseClicked != derivedClick) (if (frame#mouseClicked) " click" else " noclick") else "") +
            (if (frame#mouseMoved != derivedMoved) (if (frame#mouseMoved) " moved" else " still") else "");
        let (verb, isWait) =
            if (Set.isEmpty(pressed) and Set.isEmpty(released)) ("", true)
            else if (Set.isEmpty(released)) ("hold ${keysText(pressed)}", false)
            else if (Set.isEmpty(pressed)) ("release ${keysText(released)}", false)
            else (" keys=${keysText(frame#down)}", true);
        let head = if (isWait) verb + opts else verb + opts;
        let ns = Float64.tryToInt64(Float64.round(frame#dt * 1000000000.0)) |> Option.getWithDefault(0i64);
        push(rec, { head = head, wait = isWait, ns = ns :: Nil });
        let after = Ref.get(rec#state);
        let count = after#count + 1;
        Ref.put({ down = frame#down, button = frame#mouseDown, cursor = Some(frame#cursor), count = count,
                  lastFp = fingerprint |> Option.getWithDefault(after#lastFp) | after }, rec#state);
        match fingerprint {
            case Some(text) if Int32.modulo(count, 60) == 0 =>
                line(rec, "expect fp=${Flow.fingerprintOf(text)}");
                write(rec, "# fp ${text}")
            case _ => ()
        }

    /// 1 フレームの行を足す: 前と同じ形の wait は数を足し、1 フレームだけの hold の直後の同じキーの release は tap にまとめる。
    def push(rec: Recorder, next: { head = String, wait = Bool, ns = List[Int64] }): Unit \ IO =
        let st = Ref.get(rec#state);
        match st#pending {
            case Some(p) if p#wait and next#wait and p#head == next#head =>
                Ref.put({ pending = Some({ ns = List.append(next#ns, p#ns) | p }) | st }, rec#state)
            case Some(p) if not p#wait and List.length(p#ns) == 1 and String.startsWith(prefix = "hold ", p#head)
                            and String.startsWith(prefix = "release ", next#head)
                            and keyWord(p#head) == keyWord(next#head) and restOf(p#head) == restOf(next#head) =>
                // 押して次のフレームで離した = tap（離したフレームは何も触らないフレーム）。
                Ref.put({ pending = Some({ head = "tap " + String.dropLeft(5, p#head), wait = false, ns = p#ns }) | st }, rec#state);
                flush(rec);
                Ref.put({ pending = Some({ head = restOf(next#head), wait = true, ns = next#ns }) | Ref.get(rec#state) }, rec#state)
            case _ =>
                flush(rec);
                Ref.put({ pending = Some(next) | Ref.get(rec#state) }, rec#state)
        }

    /// "hold Z at=1,2" の 2 語目（キー）。
    def keyWord(head: String): String =
        String.words(head) |> List.drop(1) |> List.head |> Option.getWithDefault("")

    /// "hold Z at=1,2" の 3 語目から後ろ（先頭の空白つき）。
    def restOf(head: String): String =
        let rest = String.words(head) |> List.drop(2);
        if (List.isEmpty(rest)) "" else " " + String.intercalate(" ", rest)

    /// キーの名前の列（名前の順・空なら -）。
    def keysText(keys: Set[Key]): String =
        if (Set.isEmpty(keys)) "-"
        else keys |> Set.toList |> List.map(key -> "${key}") |> List.sort |> String.intercalate(",")

    /// 始まりの行（引数の値が空白や # を含むか b64: で始まるなら b64: にする）と、読んだファイル。
    pub def startLine(name: String, args: Map[String, String], files: Map[String, Flow.File]): String =
        "start ${name}" + argsText(args) + filesText(files)

    /// 保存・F1 で読み直した行（target = 監視のパスか key）。
    pub def reloadLine(target: String, files: Map[String, Flow.File]): String =
        "reload ${target}" + filesText(files)

    /// onRequest のルートが World を変えた行（クエリは b64 にまとめる）。
    pub def requestLine(path: String, params: Map[String, String], files: Map[String, Flow.File]): String =
        let joined = params |> Map.toList |> List.map(match (k, v) -> "${k}=${v}") |> String.intercalate("&");
        "request ${path}" + (if (joined == "") "" else " q=b64:${Flow.base64Encode(joined)}") + filesText(files)

    def argsText(args: Map[String, String]): String =
        args |> Map.toList |> List.map(match (k, v) -> {
            let plain = not String.exists(c -> Char.isWhitespace(c) or c == '#', v) and not String.startsWith(prefix = "b64:", v);
            if (plain) " ${k}=${v}" else " ${k}=b64:${Flow.base64Encode(v)}"
        }) |> String.intercalate("")

    def filesText(files: Map[String, Flow.File]): String =
        files |> Map.toList |> List.map(match (path, file) -> match file {
            case Flow.File.Text(text) => " +${path}=b64:${Flow.base64Encode(text)}"
            case Flow.File.Missing    => " +${path}=missing"
        }) |> String.intercalate("")

    /// f を流し、その間に Fs.FileRead で読んだファイルの中身（読めなかった物は Missing）を拾う。
    pub def reading(f: Unit -> a \ ef): (a, Map[String, Flow.File]) \ ef + Fs.FileRead =
        region rc {
            let seen: Ref[Map[String, Flow.File], rc] = Ref.fresh(rc, Map.empty());
            let note = (path, result) -> match result {
                case Ok(text) => Ref.put(Map.insert(path, Flow.File.Text(text), Ref.get(seen)), seen)
                case Err(_)   => Ref.put(Map.insert(path, Flow.File.Missing, Ref.get(seen)), seen)
            };
            let value = run { f() } with handler Fs.FileRead {
                def read(path, k) = {
                    let result = Fs.FileRead.read(path);
                    note(path, result);
                    k(result)
                }
                def readLines(path, k) = {
                    let result = Fs.FileRead.read(path);
                    note(path, result);
                    k(result |> Result.map(String.lines))
                }
                def readBytes(path, k) = k(Fs.FileRead.readBytes(path))
            };
            (value, Ref.get(seen))
        }

    /// F8 のチケットの写し: ここまでの記録に「表示中の瞬間まで戻る」（rewind back）と mark ticket を足して
    /// dir/record.flow に書き、チケットの README に再生の仕方を 1 行足す。
    pub def copyInto(rec: Recorder, dir: String, back: Int32): Bool \ IO =
        flush(rec);
        let dest = "${dir}/record.flow";
        try {
            discard Files.copy(new File(rec#path).toPath(), new File(dest).toPath(), StandardCopyOption.REPLACE_EXISTING);
            let out = new FileWriter(dest, true);
            out.write("# F8 のチケット: ここまで流すとチケットの瞬間に着く\n" +
                      (if (back > 0) "rewind ${Int32.toString(back)}\n" else "") + "mark ticket\n");
            out.close();
            let readme = new FileWriter("${dir}/README.md", true);
            readme.write("\n- 遊んだ記録: record.flow（`make flow FLOW=${dest}` で再生すると、この瞬間で止まる）\n");
            readme.close();
            true
        } catch {
            case _: IOException => false
        }

    /// 記録を閉じる（まとめている行を書き出す）。
    pub def close(rec: Recorder): Unit \ IO =
        flush(rec);
        try { rec#out.close() } catch { case _: IOException => () }
}
