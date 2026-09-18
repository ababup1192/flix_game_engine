// EnemyDoc — enemies.enemy.json(敵 3 種のテンポ数値)の宣言ドキュメント層。
// 種類そのものは増えない(歩く・飛ぶ・撃つで固定)— 増減するのはステージ側の配置。
// fail-open — 読めない・壊れているときは defaults() へ落とす。
mod EnemyDoc {
    use Util.Json.Json

    pub type alias Rec = {
        version = Int32,
        walkSpeed = Float64,   // 歩く敵の速さ px/s
        flyAmpTiles = Float64, // 飛ぶ敵の上下の振れ幅(タイル数)
        flyPeriod = Float64,   // 飛ぶ敵の 1 往復の秒
        shotSpeed = Float64,   // 弾の速さ px/s
        shotRangeTiles = Float64, // 撃つ敵が主役に気づく横距離(タイル数)
        shotCooldown = Float64 // 発射の間隔秒
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/enemies.enemy.json"

    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          walkSpeed = 34.0, flyAmpTiles = 2.2, flyPeriod = 2.6,
          shotSpeed = 130.0, shotRangeTiles = 12.0, shotCooldown = 2.2 })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version        = JsonCodec.intOr("version", d#version, root),
          walkSpeed      = JsonCodec.floatOr("walkSpeed", d#walkSpeed, root),
          flyAmpTiles    = JsonCodec.floatOr("flyAmpTiles", d#flyAmpTiles, root),
          flyPeriod      = JsonCodec.floatOr("flyPeriod", d#flyPeriod, root),
          shotSpeed      = JsonCodec.floatOr("shotSpeed", d#shotSpeed, root),
          shotRangeTiles = JsonCodec.floatOr("shotRangeTiles", d#shotRangeTiles, root),
          shotCooldown   = JsonCodec.floatOr("shotCooldown", d#shotCooldown, root) })

    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
