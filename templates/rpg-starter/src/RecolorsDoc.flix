// RecolorsDoc — assets/rpg.recolors.json（色違いの catalog）の Doc 層。
// 1 行 = 色票の鍵を 4 組まで差し替える表（from → to）。どの敵がどの行を使うかは rpg.foes.json の recolor。
// 差し替えた絵のアトラスは Res が作る（Sheet.recolored）。
// fail-open — 読めない行は飛ばして 1 行言う（その色違いの敵は元の色で描かれる）。
mod RecolorsDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// recolors = 色違いの名前 → 色票の鍵の差し替え（from → to）、problems = 読む時に飛ばした行。
    pub type alias Rec = { version = Int32, recolors = Map[String, Map[String, String]], problems = List[String] }

    /// WhyNot: 外で組ませない — 既定へ落とした欄と知らせる行は fromJson と既定を通さないと揃わない。
    enum RecolorsDocOf(Rec)

    pub type alias Doc = RecolorsDocOf

    pub def rec(d: Doc): Rec = match d { case RecolorsDocOf.RecolorsDocOf(r) => r }

    pub def path(): String = "assets/rpg.recolors.json"

    def defaults(): Doc = RecolorsDocOf.RecolorsDocOf({ version = 1, recolors = Map.empty(), problems = Nil })

    /// 色違いの差し替え（無い名前は None）。
    pub def swapsOf(d: Doc, name: String): Option[Map[String, String]] = Map.get(name, rec(d)#recolors)

    def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let rows = Map.get("recolors", root) |> Option.flatMap(JsonCodec.decodeStringMap(JsonCodec.expectObject)) |> Option.getWithDefault(Map.empty());
        let decoded = rows |> Map.map(swapsRowOf);
        let problems = decoded |> Map.toList |> List.filterMap(match (key, row) ->
            if (Map.isEmpty(row)) Some("[recolors] '${key}' に差し替え（from1 と to1 …）が 1 組も無い") else None);
        RecolorsDocOf.RecolorsDocOf({ version = JsonCodec.intOr("version", rec(defaults())#version, root),
                  recolors = decoded |> Map.filter(row -> not Map.isEmpty(row)), problems = problems })

    /// from1..from4 → to1..to4（どちらかが空の組は飛ばす）。
    def swapsRowOf(obj: Map[String, Json]): Map[String, String] =
        List.range(1, 5) |> List.filterMap(i -> {
            let original = JsonCodec.stringOr("from${i}", "", obj);
            let swapped = JsonCodec.stringOr("to${i}", "", obj);
            if (String.isEmpty(original) or String.isEmpty(swapped)) None else Some((original, swapped))
        }) |> List.toMap

    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
