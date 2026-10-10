// AudioMixerDoc — mixer.json（音の通り道）の読み込み。読めない欄は既定へ倒す（fail-open）。
// 形（version 1）:
//
//     { "version": 1, "note": "...",
//       "defaultBus": "sfx",
//       "buses":  [ { "name": "music", "volume": 0.8, "lowpass": 1.0 }, ... ],
//       "routes": [ { "prefix": "bgm", "bus": "music" }, ... ],
//       "ducks":  [ { "bus": "music", "by": ["sfx"], "depth": 0.6,
//                     "attackSeconds": 0.04, "holdSeconds": 0.1, "releaseSeconds": 0.4 } ],
//       "limits": [ { "prefix": "cursor", "cooldownSeconds": 0.05 } ],
//       "snapshots": [ { "name": "talk", "buses": [ { "name": "music", "lowpass": 0.2 } ] } ] }
//
// どの欄も省略できる（省略した欄は AudioMixer.passthrough と同じ = 何もしない）。
// 数の欄の意味は AudioMixer の型の doc を見る。schema は docs/mixer.schema.json。
pub mod AudioMixerDoc {
    use Util.Json.Json

    /// テキストから Mixer へ（JSON でない・オブジェクトでなければ None）。
    pub def fromJson(text: String): Option[AudioMixer.Mixer] =
        DocJson.decodeObject(fromRoot, text)

    /// path の mixer.json を読む。読めない・壊れているときは fallback。
    pub def load(fallback: AudioMixer.Mixer, path: String): AudioMixer.Mixer \ Fs.FileRead =
        DocJson.loadOr(fromJson, fallback, path)

    def fromRoot(root: Map[String, Json]): AudioMixer.Mixer =
        let base = AudioMixer.passthrough();
        { buses      = rowsOf("buses", busOf, root),
          routes     = rowsOf("routes", routeOf, root),
          defaultBus = JsonCodec.stringOr("defaultBus", base#defaultBus, root),
          ducks      = rowsOf("ducks", duckOf, root),
          limits     = rowsOf("limits", limitOf, root),
          snapshots  = rowsOf("snapshots", snapshotOf, root) }

    /// 配列の欄を行ごとに読む（読めない行だけ落とす）。
    def rowsOf(key: String, row: Map[String, Json] -> Option[a], root: Map[String, Json]): List[a] =
        match Map.get(key, root) {
            case Some(Json.JArray(items)) =>
                Vector.toList(items) |> List.filterMap(item -> JsonCodec.expectObject(item) |> Option.flatMap(row))
            case _ => Nil
        }

    def busOf(o: Map[String, Json]): Option[AudioMixer.Bus] =
        Map.get("name", o) |> Option.flatMap(JsonCodec.expectString) |> Option.map(name ->
            { name = name,
              volume = JsonCodec.floatOr("volume", 1.0, o),
              lowpass = JsonCodec.floatOr("lowpass", 1.0, o) })

    def routeOf(o: Map[String, Json]): Option[AudioMixer.Route] =
        forM (
            prefix <- Map.get("prefix", o) |> Option.flatMap(JsonCodec.expectString);
            bus    <- Map.get("bus", o) |> Option.flatMap(JsonCodec.expectString)
        ) yield { prefix = prefix, bus = bus }

    def duckOf(o: Map[String, Json]): Option[AudioMixer.Duck] =
        Map.get("bus", o) |> Option.flatMap(JsonCodec.expectString) |> Option.map(bus ->
            { bus = bus,
              by = match Map.get("by", o) {
                  case Some(Json.JArray(items)) => List.filterMap(JsonCodec.expectString, Vector.toList(items))
                  case _                        => Nil
              },
              depth = JsonCodec.floatOr("depth", 1.0, o),
              attackSeconds = JsonCodec.floatOr("attackSeconds", 0.05, o),
              holdSeconds = JsonCodec.floatOr("holdSeconds", 0.0, o),
              releaseSeconds = JsonCodec.floatOr("releaseSeconds", 0.3, o) })

    def limitOf(o: Map[String, Json]): Option[AudioMixer.Limit] =
        Map.get("prefix", o) |> Option.flatMap(JsonCodec.expectString) |> Option.map(prefix ->
            { prefix = prefix, cooldownSeconds = JsonCodec.floatOr("cooldownSeconds", 0.0, o) })

    def snapshotOf(o: Map[String, Json]): Option[AudioMixer.Snapshot] =
        Map.get("name", o) |> Option.flatMap(JsonCodec.expectString) |> Option.map(name ->
            { name = name, buses = rowsOf("buses", overrideOf, o) })

    def overrideOf(o: Map[String, Json]): Option[AudioMixer.BusOverride] =
        Map.get("name", o) |> Option.flatMap(JsonCodec.expectString) |> Option.map(name ->
            { name = name,
              volume = Map.get("volume", o) |> Option.flatMap(JsonCodec.expectFloat),
              lowpass = Map.get("lowpass", o) |> Option.flatMap(JsonCodec.expectFloat) })
}
