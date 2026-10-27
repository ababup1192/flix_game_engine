// Saves — 遊んだ人ごとに残す物（栞 = セーブの枠・既読の行・設定）と、その読み書き。
// 中身は 1 つの JSON（saves/novel.json）。読むのは起動の 1 回（Main）、書くのは App.addOutput が
// 「中身が変わった実機のフレームの後」でだけ（World の saveRev が鍵。テスト・flow・描き出しでは書かない）。
// 栞の中身は YarnRunner のブックマーク（ノード・変数・そこまでの送りと選択）と、舞台のうち前のノードから持ち越す物
// （背景・環境音・粒）。ロードはブックマークを当て直して今のノードのコマンドを畳み、持ち越す物は栞の値で上書きする
// （ブックマークが当て直すのは今のノードの頭からなので、前のノードで鳴らし始めた環境音はそれだけでは戻らない）。
mod Saves {
    use fge::{DocJson, JsonCodec, Log, YarnRunner}
    use Util.Json.Json

    /// 設定の画面で変える値。cps = 1 秒の字数、autoWait = オートで読み終えてから送るまでの秒、
    /// ambienceVolume / seVolume = 環境音・効果音の音量（0〜1）。
    pub type alias Config = { cps = Float64, autoWait = Float64, ambienceVolume = Float64, seVolume = Float64 }

    /// 栞 1 枚。place = 場所の名前（背景の写真の label）、excerpt = 挟んだ所の台詞の頭、
    /// shot / ambience / particles = 挟んだ時の背景・環境音・粒（Stage の同じ名前の欄）。
    pub type alias Slot = { bookmark = YarnRunner.Bookmark, place = String, excerpt = String,
                            shot = Option[Stage.Shot], ambience = Option[String], particles = Option[String] }

    /// slots = 枠の番号（0 から）→ 栞、seen = 読んだ行（.yarn の「ファイル:行」）、config = 設定。
    pub type alias Saves = { slots = Map[Int32, Slot], seen = Set[String], config = Config }

    pub def path(): String = "saves/novel.json"

    /// 栞の枠の数（セーブの窓の 2 列 × 3 行）。
    pub def slotCount(): Int32 = 6

    /// 初めて遊ぶ時（設定は novel.kind.json の既定）。
    pub def fresh(kind: KindDoc.Doc): Saves =
        let k = KindDoc.rec(kind);
        { slots = Map.empty(), seen = Set.empty(),
          config = { cps = k#cps, autoWait = k#autoWait, ambienceVolume = k#ambienceVolume, seVolume = k#seVolume } }

    pub def isSeen(source: String, saves: Saves): Bool = Set.memberOf(source, saves#seen)

    pub def withSeen(source: String, saves: Saves): Saves = { seen = Set.insert(source, saves#seen) | saves }

    pub def withSlot(i: Int32, slot: Slot, saves: Saves): Saves = { slots = Map.insert(i, slot, saves#slots) | saves }

    pub def withConfig(config: Config, saves: Saves): Saves = { config = config | saves }

    pub def hasAny(saves: Saves): Bool = not Map.isEmpty(saves#slots)

    // ── JSON ──

    pub def toJson(saves: Saves): Json =
        let num = x -> Json.JNumber(JsonCodec.floatToBd(x));
        let text = o -> o |> Option.map(Json.JString) |> Option.getWithDefault(Json.JNull);
        let slot = s -> Json.JObject(Map#{ "bookmark" => YarnRunner.bookmarkToJson(s#bookmark),
                                          "place" => Json.JString(s#place), "excerpt" => Json.JString(s#excerpt),
                                          "photo" => text(s#shot |> Option.map(shot -> shot#photo)),
                                          "grade" => text(s#shot |> Option.map(shot -> shot#grade)),
                                          "ambience" => text(s#ambience), "particles" => text(s#particles) });
        let c = saves#config;
        Json.JObject(Map#{
            "version" => num(1.0),
            "slots" => Json.JObject(saves#slots |> Map.toList |> List.map(match (i, s) -> (Int32.toString(i), slot(s))) |> List.toMap),
            "seen" => Json.JArray(saves#seen |> Set.toList |> List.map(Json.JString) |> List.toVector),
            "config" => Json.JObject(Map#{ "cps" => num(c#cps), "autoWait" => num(c#autoWait),
                                           "ambienceVolume" => num(c#ambienceVolume), "seVolume" => num(c#seVolume) })
        })

    /// JSON から（壊れた枠・行はその分だけ捨て、設定の欠けた欄は fallback の値）。
    pub def fromJson(fallback: Saves, json: Json): Saves =
        let root = JsonCodec.expectObject(json) |> Option.getWithDefault(Map.empty());
        let slotOf = j -> JsonCodec.expectObject(j) |> Option.flatMap(obj -> forM (
                bookmark <- Map.get("bookmark", obj) |> Option.flatMap(YarnRunner.bookmarkFromJson)
            ) yield {
                let text = key -> Map.get(key, obj) |> Option.flatMap(JsonCodec.expectString);
                { bookmark = bookmark, place = JsonCodec.stringOr("place", "", obj),
                  excerpt = JsonCodec.stringOr("excerpt", "", obj),
                  shot = forM (photo <- text("photo"); grade <- text("grade")) yield { photo = photo, grade = grade },
                  ambience = text("ambience"), particles = text("particles") }
            });
        let slots = Map.get("slots", root) |> Option.flatMap(JsonCodec.expectObject) |> Option.getWithDefault(Map.empty())
            |> Map.toList
            |> List.filterMap(match (key, j) -> forM (i <- Int32.fromString(key); s <- slotOf(j)) yield (i, s))
            |> List.toMap;
        let seen = Map.get("seen", root) |> Option.flatMap(JsonCodec.decodeList(JsonCodec.expectString))
            |> Option.getWithDefault(Nil) |> List.toSet;
        let c = fallback#config;
        let config = Map.get("config", root) |> Option.flatMap(JsonCodec.expectObject) |> Option.map(obj ->
            { cps = JsonCodec.floatOr("cps", c#cps, obj), autoWait = JsonCodec.floatOr("autoWait", c#autoWait, obj),
              ambienceVolume = JsonCodec.floatOr("ambienceVolume", c#ambienceVolume, obj),
              seVolume = JsonCodec.floatOr("seVolume", c#seVolume, obj) }) |> Option.getWithDefault(c);
        { slots = slots, seen = seen, config = config }

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
