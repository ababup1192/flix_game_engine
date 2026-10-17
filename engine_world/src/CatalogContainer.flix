// CatalogContainer — 「1 ファイル = 1 種類の一覧」を表す汎用の入れ物。id から中身を引ける
// entries と、それ以外のトップレベル項目 meta に分けて持つ。
// どのゲームのデータ（武器・ユニット等）も同じ形で読み書きでき、id 参照と保存を共通化できる。
// 利用例: weapons.json を読む / id "sword" の武器を引く / players 一覧を meta から取る。
//
// 例: `weapons.json` は `{"weapons": {"sword": {...}, ...}}`
//       containerKey = "weapons", entries = {sword => ...}, meta = {}
//
// 例: `units.json` は `{"units": {...}, "players": [...], "enemies": [...]}`
//       containerKey = "units", entries = {knight => ...},
//       meta = {"players" => JArray(...), "enemies" => JArray(...)}
//
// 注意: `Saveable[CatalogContainer[t]]` の polymorphic instance は付けない。`fromJson` の型に
//   containerKey を値として渡せないため。代わりに `encode` / `decode` 関数 API を提供し、各 catalog は
//   wrap enum + 単相 Saveable instance を書く。
pub mod CatalogContainer {
    use Util.Json.Json
    use Util.Json.Json.{JObject}

    /// 1 container の中身。
    /// `containerKey` は JSON top でこの container を保持しているキー名 (例: "weapons")。
    /// `entries` は id → 値の Map。`meta` は containerKey 以外の top-level フィールド。
    pub enum CatalogContainer[t] {
        case CatalogContainer({
            containerKey = String,
            entries      = Map[String, t],
            meta         = Map[String, Json]
        })
    }

    /// entries だけを取り出すアクセサ。
    pub def entriesOf(catalog: CatalogContainer[t]): Map[String, t] =
        let CatalogContainer.CatalogContainer(payload) = catalog;
        payload#entries

    /// meta フィールド (containerKey 以外の top-level フィールド) を取り出す。
    pub def metaOf(catalog: CatalogContainer[t]): Map[String, Json] =
        let CatalogContainer.CatalogContainer(payload) = catalog;
        payload#meta

    /// 1 件を id で引く。境界: 未定義 id は None。
    pub def get(id: String, catalog: CatalogContainer[t]): Option[t] =
        Map.get(id, entriesOf(catalog))

    /// catalog を JSON object として encode する。
    /// 形式: `{containerKey: encodeStringMap(entries), ...meta}`
    /// entry encoder は pure として渡す (内部で `unsafe IO` を隠した形 = JsonCodec の慣例と整合)。
    pub def encode(encodeEntry: t -> Json, catalog: CatalogContainer[t]): Json =
        let CatalogContainer.CatalogContainer(payload) = catalog;
        let entriesJson = JsonCodec.encodeStringMap(encodeEntry, payload#entries);
        let base = Map.insert(payload#containerKey, entriesJson, payload#meta);
        JObject(base)

    /// JSON object から containerKey 配下を entries、残りを meta として decode する。
    /// 失敗ケース (None): containerKey が無い / object でない / 要素 decode 失敗のいずれか。
    pub def decode(containerKey: String,
                    decodeEntry: Json -> Option[t],
                    element: Json): Option[CatalogContainer[t]] =
        forM (
            top         <- JsonCodec.expectObject(element);
            entriesJson <- Map.get(containerKey, top);
            entries     <- JsonCodec.decodeStringMap(decodeEntry, entriesJson)
        ) yield {
            let meta = Map.remove(containerKey, top);
            CatalogContainer.CatalogContainer({
                containerKey = containerKey,
                entries      = entries,
                meta         = meta
            })
        }
}
