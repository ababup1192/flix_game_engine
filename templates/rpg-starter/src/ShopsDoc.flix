// ShopsDoc — assets/rpg.shops.json（宿代と、道具屋の品）の Doc 層。
// 品の値段は rpg.items.json の price（同じ道具の値段を 2 か所に書かない）。ここは並べる品と宿代だけ。
// fail-open — 読めない・壊れているときは品の無い店と既定の宿代で続ける。品の行の道具が無い食い違いは Res.problemsOf が言う。
mod ShopsDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// innPrice = 宿の 1 泊の値段、goods = 店に並ぶ品（上から並べる順）、problems = 読めずに飛ばした行（Res.problemsOf が言う）。
    pub type alias Rec = { version = Int32, innPrice = Int32, goods = List[Goods], problems = List[String] }

    /// 品 1 行: shop = 並べる店の名前（会話の <<shop 名前>>。空は村の道具屋 <<shop>>）・item = rpg.items.json の鍵。
    pub type alias Goods = { shop = String, item = String }

    /// shop の店に並ぶ品の鍵（並べる順）。
    pub def goodsOf(shop: String, d: Doc): List[String] =
        rec(d)#goods |> List.filter(g -> g#shop == shop) |> List.map(g -> g#item)

    /// WhyNot: 外で組ませない — 既定へ落とした欄と知らせる行は fromJson と既定を通さないと揃わない。
    enum ShopsDocOf(Rec)

    /// 読んだ Doc（作るのは fromJson と既定だけ。中身は rec で読む）。
    pub type alias Doc = ShopsDocOf

    pub def rec(d: Doc): Rec = match d { case ShopsDocOf.ShopsDocOf(r) => r }

    pub def path(): String = "assets/rpg.shops.json"

    def defaults(): Doc = ShopsDocOf.ShopsDocOf({ version = 1, innPrice = 6, goods = Nil, problems = Nil })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let rows = Map.get("goods", root) |> Option.flatMap(JsonCodec.decodeList(json -> Some(json))) |> Option.getWithDefault(Nil);
        let decoded = rows |> List.map(row -> JsonCodec.expectObject(row) |> Option.flatMap(obj ->
            Map.get("item", obj) |> Option.flatMap(JsonCodec.expectString)
                |> Option.map(item -> { shop = JsonCodec.stringOr("shop", "", obj), item = item })));
        let problems = decoded |> List.zipWithIndex |> List.filterMap(match (i, item) ->
            if (Option.isEmpty(item)) Some("[shops] goods の ${i + 1} 行目に item が無いので飛ばす") else None);
        ShopsDocOf.ShopsDocOf({ version = JsonCodec.intOr("version", d#version, root),
                  innPrice = JsonCodec.intOr("innPrice", d#innPrice, root),
                  goods = decoded |> List.filterMap(x -> x), problems = problems })

    /// path の Doc を読む。読めない・壊れているときは品の無い店。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
