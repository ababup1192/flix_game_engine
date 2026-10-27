// Saves — 遊んだ人ごとに残す物（セーブデータ・既読の行・設定）と、その読み書き。
// 中身は 1 つの JSON（saves/novel.json）。読むのは起動の 1 回（Main）、書くのは App.addOutput が
// 「中身が変わった実機のフレームの後」でだけ（World の saveRev が鍵。テスト・flow・描き出しでは書かない）。
//
// セーブの枠は 5 つのページ（Tab）× 6 枠。オートとクイックは「新しい物を先頭に入れ、古い物を後ろへ押し出す」ページ、
// 1〜3 は人が枠を選んで書くページ。どの枠も中身は「戻れる所」Mark（YarnRunner のブックマークと、前のノードから
// 持ち越す舞台）と、ロード画面に出す物（場所・話し手・台詞・保存した日時・通し番号）。
// Mark はバックログの行と「戻る」も同じ物を持つ（セーブ・ロード・戻るが 1 つの戻し方 World.restore を通る）。
mod Saves {
    use fge::{DocJson, JsonCodec, Log, YarnRunner}
    use Util.Json.Json

    /// World が持つので包む（record のままだと World を取る全 def へ中身が展開される）。
    enum Saves(Rec)

    /// 未読の行もスキップするか。
    pub enum SkipScope with Eq, ToString {
        case ReadOnly
        case Everything
    }

    /// 選択肢を選んだ後もスキップを続けるか。
    pub enum AfterChoice with Eq, ToString {
        case StopSkip
        case KeepSkip
    }

    /// 窓の出し方。
    pub enum Display with Eq, ToString {
        case Window
        case Fullscreen
    }

    /// 設定の画面で変える値。cps = 1 秒の字数、autoWait = オートで読み終えてから送るまでの秒、
    /// masterVolume / ambienceVolume / seVolume = 全体・環境音・効果音の音量（0〜1）、windowAlpha = 文章の窓の濃さ（0〜1）。
    pub type alias Config = {
        cps = Float64,
        autoWait = Float64,
        masterVolume = Float64,
        ambienceVolume = Float64,
        seVolume = Float64,
        windowAlpha = Float64,
        skipScope = SkipScope,
        afterChoice = AfterChoice,
        display = Display
    }

    /// 戻れる所 1 つ。bookmark = シナリオの位置、shot / ambience / particles / mode = その時の背景・環境音・粒・文章の出し方
    /// （ブックマークが当て直すのは今のノードの頭からなので、前のノードで始まった物はここから戻す）。
    pub type alias Mark = {
        bookmark = YarnRunner.Bookmark,
        shot = Option[Stage.Shot],
        ambience = Option[String],
        particles = Option[String],
        mode = Stage.Mode
    }

    /// セーブデータ 1 つ。place = 場所の名前（背景の写真の label）、speaker / excerpt = その時の話し手と台詞、
    /// page = その時に画面に出ていた文（NVL は頁の行を上から、ADV は今の 1 行。サムネに小さく写す）、
    /// savedAt = 保存した日時（その土地の時刻の 1970-01-01 からの秒）、serial = 保存した順の通し番号（大きいほど新しい）。
    pub type alias Slot = { mark = Mark, place = String, speaker = String, excerpt = String, page = List[String], savedAt = Int64, serial = Int32 }

    /// セーブのページ。Auto = 場面が替わるたびに自動で残る、Quick = クイックセーブ、Numbered(n) = 1 から数えた n ページ目。
    pub enum Tab with Eq, ToString {
        case Auto
        case Quick
        case Numbered(Int32)
    }

    /// slots = 枠の鍵（keyOf）→ データ、seen = 読んだ行（.yarn の「ファイル:行」）、config = 設定、serial = 最後に使った通し番号。
    pub type alias Rec = { slots = Map[Int32, Slot], seen = Set[String], config = Config, serial = Int32 }

    pub def rec(saves: Saves): Rec = match saves { case Saves.Saves(r) => r }

    pub def configOf(saves: Saves): Config = rec(saves)#config

    pub def serialOf(saves: Saves): Int32 = rec(saves)#serial

    pub def slotsOf(saves: Saves): Map[Int32, Slot] = rec(saves)#slots

    pub def seenOf(saves: Saves): Set[String] = rec(saves)#seen

    pub def path(): String = "saves/novel.json"

    /// 1 ページの枠の数（2 列 × 3 行）。
    pub def perPage(): Int32 = 6

    /// ロード画面のページ（左から）。
    pub def tabs(): List[Tab] = Tab.Auto :: Tab.Quick :: Tab.Numbered(1) :: Tab.Numbered(2) :: Tab.Numbered(3) :: Nil

    /// セーブ画面のページ（オートとクイックは人が枠を選んで書かない）。
    pub def writableTabs(): List[Tab] = tabs() |> List.filter(isWritable)

    pub def isWritable(tab: Tab): Bool = match tab {
        case Tab.Numbered(_) => true
        case Tab.Auto        => false
        case Tab.Quick       => false
    }

    /// ページの並びの番号（0 から）。
    def tabIndex(tab: Tab): Int32 = match tab {
        case Tab.Auto        => 0
        case Tab.Quick       => 1
        case Tab.Numbered(n) => n + 1
    }

    /// ページ tab の i 枠目の鍵。
    pub def keyOf(tab: Tab, i: Int32): Int32 = tabIndex(tab) * perPage() + i

    /// 鍵からページと枠（JSON から読んだ鍵の検算・つづきからの行き先）。
    def placeOfKey(key: Int32): Option[(Tab, Int32)] =
        let page = key / perPage();
        let i = Int32.remainder(key, perPage());
        tabs() |> List.find(tab -> tabIndex(tab) == page) |> Option.map(tab -> (tab, i))

    pub def slotOf(tab: Tab, i: Int32, saves: Saves): Option[Slot] = Map.get(keyOf(tab, i), slotsOf(saves))

    /// 初めて遊ぶ時（設定は novel.kind.json の既定）。
    pub def fresh(kind: KindDoc.Doc): Saves =
        Saves.Saves({ slots = Map.empty(), seen = Set.empty(), config = defaultConfig(kind), serial = 0 })

    /// 設定の既定（設定の画面の「初期設定に戻す」もこれ）。
    pub def defaultConfig(kind: KindDoc.Doc): Config =
        let k = KindDoc.rec(kind);
        { cps = k#cps, autoWait = k#autoWait, masterVolume = k#masterVolume, ambienceVolume = k#ambienceVolume,
          seVolume = k#seVolume, windowAlpha = k#windowAlpha,
          skipScope = SkipScope.ReadOnly, afterChoice = AfterChoice.StopSkip, display = Display.Window }

    pub def isSeen(source: String, saves: Saves): Bool = Set.memberOf(source, seenOf(saves))

    pub def withSeen(source: String, saves: Saves): Saves = let r = rec(saves); Saves.Saves({ seen = Set.insert(source, r#seen) | r })

    pub def withConfig(config: Config, saves: Saves): Saves = Saves.Saves({ config = config | rec(saves) })

    /// 次に書くデータの通し番号。
    pub def nextSerial(saves: Saves): Int32 = serialOf(saves) + 1

    /// ページ tab の i 枠目に書く。
    pub def withSlot(tab: Tab, i: Int32, slot: Slot, saves: Saves): Saves =
        let r = rec(saves);
        Saves.Saves({ slots = Map.insert(keyOf(tab, i), slot, r#slots), serial = Int32.max(r#serial, slot#serial) | r })

    /// ページ tab の先頭に入れ、前からある物を 1 つずつ後ろへ押す（最後の枠からあふれた物は消える。オートとクイック）。
    pub def withPushed(tab: Tab, slot: Slot, saves: Saves): Saves =
        let shifted = List.range(0, perPage() - 1) |> List.reverse |> List.foldLeft((acc, i) ->
            match Map.get(keyOf(tab, i), acc) {
                case Some(s) => Map.insert(keyOf(tab, i + 1), s, acc)
                case None    => Map.remove(keyOf(tab, i + 1), acc)
            }, slotsOf(saves));
        let r = rec(saves);
        Saves.Saves({ slots = Map.insert(keyOf(tab, 0), slot, shifted), serial = Int32.max(r#serial, slot#serial) | r })

    pub def withoutSlot(tab: Tab, i: Int32, saves: Saves): Saves = let r = rec(saves); Saves.Saves({ slots = Map.remove(keyOf(tab, i), r#slots) | r })

    pub def hasAny(saves: Saves): Bool = not Map.isEmpty(slotsOf(saves))

    /// いちばん新しいデータのページと枠（「つづきから」の行き先・NEW の印）。
    pub def latest(saves: Saves): Option[(Tab, Int32)] =
        slotsOf(saves) |> Map.toList
            |> List.foldLeft((best, entry) -> {
                let (key, slot) = entry;
                match best {
                    case Some((_, top)) if top#serial >= slot#serial => best
                    case _ => Some((key, slot))
                }
            }, None)
            |> Option.flatMap(match (key, _) -> placeOfKey(key))

    // ── 日時の字（ロード画面）──

    /// 1970-01-01 00:00 からの秒を「2026/08/14 19:32」に（暦はグレゴリオ暦。秒はその土地の時刻のまま渡す）。
    pub def dateText(seconds: Int64): String =
        let s = Int64.max(0i64, seconds);
        let days = s / 86400i64;
        let minuteOfDay = Int64.remainder(s, 86400i64) / 60i64;
        let (y, m, d) = civilOf(days);
        "${y}/${pad2(m)}/${pad2(d)} ${pad2(minuteOfDay / 60i64)}:${pad2(Int64.remainder(minuteOfDay, 60i64))}"

    /// 1970-01-01 からの日数 → (年, 月, 日)（0 以上の日数だけを受ける）。
    def civilOf(days: Int64): (Int64, Int64, Int64) =
        let z = days + 719468i64;
        let era = z / 146097i64;
        let doe = z - era * 146097i64;
        let yoe = (doe - doe / 1460i64 + doe / 36524i64 - doe / 146096i64) / 365i64;
        let doy = doe - (365i64 * yoe + yoe / 4i64 - yoe / 100i64);
        let mp = (5i64 * doy + 2i64) / 153i64;
        let d = doy - (153i64 * mp + 2i64) / 5i64 + 1i64;
        let m = if (mp < 10i64) mp + 3i64 else mp - 9i64;
        let y = yoe + era * 400i64 + (if (m <= 2i64) 1i64 else 0i64);
        (y, m, d)

    def pad2(n: Int64): String = if (n < 10i64) "0${n}" else "${n}"

    // ── JSON ──

    pub def toJson(saves: Saves): Json =
        let num = x -> Json.JNumber(JsonCodec.floatToBd(x));
        let text = o -> o |> Option.map(Json.JString) |> Option.getWithDefault(Json.JNull);
        let slot = (s: Slot) -> Json.JObject(Map#{
            "bookmark" => YarnRunner.bookmarkToJson(s#mark#bookmark),
            "photo" => text(s#mark#shot |> Option.map(shot -> shot#photo)),
            "grade" => text(s#mark#shot |> Option.map(shot -> shot#grade)),
            "ambience" => text(s#mark#ambience), "particles" => text(s#mark#particles),
            "mode" => Json.JString("${s#mark#mode}"),
            "place" => Json.JString(s#place), "speaker" => Json.JString(s#speaker), "excerpt" => Json.JString(s#excerpt),
            "page" => Json.JArray(s#page |> List.map(Json.JString) |> List.toVector),
            "savedAt" => num(Int64.toFloat64(s#savedAt)), "serial" => num(Int32.toFloat64(s#serial)) });
        let r = rec(saves);
        let c = r#config;
        Json.JObject(Map#{
            "version" => num(2.0),
            "serial" => num(Int32.toFloat64(r#serial)),
            "slots" => Json.JObject(r#slots |> Map.toList |> List.map(match (i, s) -> (Int32.toString(i), slot(s))) |> List.toMap),
            "seen" => Json.JArray(r#seen |> Set.toList |> List.map(Json.JString) |> List.toVector),
            "config" => Json.JObject(Map#{ "cps" => num(c#cps), "autoWait" => num(c#autoWait),
                                           "masterVolume" => num(c#masterVolume),
                                           "ambienceVolume" => num(c#ambienceVolume), "seVolume" => num(c#seVolume),
                                           "windowAlpha" => num(c#windowAlpha),
                                           "skipScope" => Json.JString("${c#skipScope}"),
                                           "afterChoice" => Json.JString("${c#afterChoice}"),
                                           "display" => Json.JString("${c#display}") })
        })

    /// JSON から（壊れた枠・行はその分だけ捨て、設定の欠けた欄は fallback の値）。
    pub def fromJson(fallback: Saves, json: Json): Saves =
        let root = JsonCodec.expectObject(json) |> Option.getWithDefault(Map.empty());
        let slotOf = j -> JsonCodec.expectObject(j) |> Option.flatMap(obj -> forM (
                bookmark <- Map.get("bookmark", obj) |> Option.flatMap(YarnRunner.bookmarkFromJson)
            ) yield {
                let text = key -> Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString);
                let mode = if (text("mode") == Some("Adv")) Stage.Mode.Adv else Stage.Mode.Nvl;
                { mark = { bookmark = bookmark,
                           shot = forM (photo <- text("photo"); grade <- text("grade")) yield { photo = photo, grade = grade },
                           ambience = text("ambience"), particles = text("particles"), mode = mode },
                  place = JsonCodec.stringOr("place", "", obj), speaker = JsonCodec.stringOr("speaker", "", obj),
                  excerpt = JsonCodec.stringOr("excerpt", "", obj),
                  page = Map.get("page", obj) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString)) |> Option.getWithDefault(Nil),
                  savedAt = Float64.tryToInt64(JsonCodec.floatOr("savedAt", 0.0, obj)) |> Option.getWithDefault(0i64),
                  serial = JsonCodec.intOr("serial", 0, obj) }
            });
        let slots = Map.get("slots", root) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty())
            |> Map.toList
            |> List.filterMap(match (key, j) -> forM (i <- Int32.fromString(key); s <- slotOf(j)) yield (i, s))
            |> List.filter(match (i, _) -> Option.nonEmpty(placeOfKey(i)))
            |> List.toMap;
        let seen = Map.get("seen", root) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString))
            |> Option.getWithDefault(Nil) |> List.toSet;
        let c = configOf(fallback);
        let config = Map.get("config", root) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(obj -> {
            let word = (key, fallbackWord) -> JsonCodec.stringOr(key, fallbackWord, obj);
            { cps = JsonCodec.floatOr("cps", c#cps, obj), autoWait = JsonCodec.floatOr("autoWait", c#autoWait, obj),
              masterVolume = JsonCodec.floatOr("masterVolume", c#masterVolume, obj),
              ambienceVolume = JsonCodec.floatOr("ambienceVolume", c#ambienceVolume, obj),
              seVolume = JsonCodec.floatOr("seVolume", c#seVolume, obj),
              windowAlpha = JsonCodec.floatOr("windowAlpha", c#windowAlpha, obj),
              skipScope = if (word("skipScope", "${c#skipScope}") == "Everything") SkipScope.Everything else SkipScope.ReadOnly,
              afterChoice = if (word("afterChoice", "${c#afterChoice}") == "KeepSkip") AfterChoice.KeepSkip else AfterChoice.StopSkip,
              display = if (word("display", "${c#display}") == "Fullscreen") Display.Fullscreen else Display.Window }
        }) |> Option.getWithDefault(c);
        let topSerial = slots |> Map.valuesOf |> List.map(s -> s#serial) |> List.foldLeft(Int32.max, 0);
        Saves.Saves({ slots = slots, seen = seen, config = config, serial = Int32.max(topSerial, JsonCodec.intOr("serial", 0, root)) })

    /// 起動の 1 回: 無い・読めない時は fresh（初めて遊ぶ時と同じ）。
    pub def load(kind: KindDoc.Doc): Saves \ Fs.FileRead =
        let fallback = fresh(kind);
        match Fs.FileRead.read(path()) {
            case Ok(text) => DocJson.parse(text) |> Option.map(json -> fromJson(fallback, json)) |> Option.getWithDefault(fallback)
            case Err(_)   => fallback
        }

    /// 書く（App.addOutput の write）。書けない時は 1 行知らせて続ける（遊びは止めない）。
    pub def write(saves: Saves): Unit \ Fs.FileWrite =
        let done = forM (
            _ <- Fs.FileWrite.mkDirs("saves");
            _ <- Fs.FileWrite.write({ str = Util.Json.toPrettyString(2, toJson(saves)) }, path())
        ) yield ();
        match done {
            case Ok(_)  => ()
            case Err(e) => Log.warn("[saves] 書けない: ${path()} (${e})")
        }
}
