// AudioMixerDoc — mixer.json（音の通り道）の読み込み。読めない欄・行は既定へ倒す（fail-open）。
// 形（version 1。schema は docs/mixer.schema.json）:
//
//     { "version": 1, "note": "...",
//       "defaultBus": "sfx",
//       "transitionSeconds": 0.3,
//       "buses":     [ { "name": "music", "volume": 0.8, "lowpassGainHF": 1.0 }, ... ],
//       "routes":    [ { "bus": "music", "prefixes": ["bgm", "ambience"] }, ... ],
//       "ducks":     [ { "bus": "music", "by": ["sfx"], "depth": 0.6,
//                        "attackSeconds": 0.04, "holdSeconds": 0.1, "releaseSeconds": 0.4 } ],
//       "cooldowns": [ { "prefix": "cursor", "seconds": 0.05 } ],
//       "snapshots": [ { "name": "talk", "buses": [ { "name": "music", "lowpassGainHF": 0.2 } ] } ] }
//
// どの欄も省略できる（省略した欄は AudioMixer.defaults と同じ = 何もしない）。
// 数の欄の意味は AudioMixer の型の doc を見る。
pub mod AudioMixerDoc {
    use Util.Json.Json

    /// テキストから Mixer へ（JSON でない・オブジェクトでなければ None）。
    pub def fromJson(text: String): Option[AudioMixer.Mixer] =
        DocJson.decodeObject(fromRoot, text)

    /// path の mixer.json を読む。読めない・壊れているときは fallback（ふつうは AudioMixer.defaults()）。
    pub def load(fallback: AudioMixer.Mixer, path: String): AudioMixer.Mixer \ Fs.FileRead =
        DocJson.loadOr(fromJson, fallback, path)

    def fromRoot(root: Map[String, Json]): AudioMixer.Mixer =
        let base = AudioMixer.defaults();
        { buses             = rowsOf("buses", busOf, root),
          routes            = rowsOf("routes", routeOf, root),
          defaultBus        = JsonCodec.stringOr("defaultBus", base#defaultBus, root),
          ducks             = rowsOf("ducks", duckOf, root),
          cooldowns         = rowsOf("cooldowns", cooldownOf, root),
          snapshots         = rowsOf("snapshots", snapshotOf, root),
          transitionSeconds = JsonCodec.floatOr("transitionSeconds", base#transitionSeconds, root) }

    /// 配列の欄を行ごとに読む（読めない行だけ落とす）。
    def rowsOf(key: String, row: Map[String, Json] -> Option[a], root: Map[String, Json]): List[a] =
        match Map.get(key, root) {
            case Some(Json.JArray(items)) =>
                Vector.toList(items) |> List.filterMap(item -> JsonCodec.expectObject(item) |> Option.flatMap(row))
            case _ => Nil
        }

    def stringsOf(key: String, o: Map[String, Json]): List[String] =
        match Map.get(key, o) {
            case Some(Json.JArray(items)) => List.filterMap(JsonCodec.expectString, Vector.toList(items))
            case _                        => Nil
        }

    def nameOf(key: String, o: Map[String, Json]): Option[String] =
        Map.get(key, o) |> Option.flatMap(JsonCodec.expectString)

    def busOf(o: Map[String, Json]): Option[AudioMixer.Bus] =
        nameOf("name", o) |> Option.map(name ->
            { name = name,
              volume = JsonCodec.floatOr("volume", 1.0, o),
              lowpassGainHF = JsonCodec.floatOr("lowpassGainHF", 1.0, o) })

    def routeOf(o: Map[String, Json]): Option[AudioMixer.Route] =
        nameOf("bus", o) |> Option.map(bus -> { bus = bus, prefixes = stringsOf("prefixes", o) })

    def duckOf(o: Map[String, Json]): Option[AudioMixer.Duck] =
        nameOf("bus", o) |> Option.map(bus ->
            { bus = bus,
              by = stringsOf("by", o),
              depth = JsonCodec.floatOr("depth", 1.0, o),
              attackSeconds = JsonCodec.floatOr("attackSeconds", 0.05, o),
              holdSeconds = JsonCodec.floatOr("holdSeconds", 0.0, o),
              releaseSeconds = JsonCodec.floatOr("releaseSeconds", 0.3, o) })

    def cooldownOf(o: Map[String, Json]): Option[AudioMixer.Cooldown] =
        nameOf("prefix", o) |> Option.map(prefix ->
            { prefix = prefix, seconds = JsonCodec.floatOr("seconds", 0.0, o) })

    def snapshotOf(o: Map[String, Json]): Option[AudioMixer.Snapshot] =
        nameOf("name", o) |> Option.map(name -> { name = name, buses = rowsOf("buses", overrideOf, o) })

    def overrideOf(o: Map[String, Json]): Option[AudioMixer.BusOverride] =
        nameOf("name", o) |> Option.map(name ->
            { name = name,
              volume = Map.get("volume", o) |> Option.flatMap(JsonCodec.expectFloat),
              lowpassGainHF = Map.get("lowpassGainHF", o) |> Option.flatMap(JsonCodec.expectFloat) })
}
