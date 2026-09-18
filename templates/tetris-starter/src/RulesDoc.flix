// RulesDoc — tetris.rules.json（手触りと収支の数値）の宣言ドキュメント層。
// Doc は「調整したい数値の初期値の宣言」まで。落ちる・ねばる・消えるの規則そのものは
// コード（World）側にある。ここに if 文を書き始めたら Doc の境界を越えている合図。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod RulesDoc {
    use Util.Json.Json

    /// 手触りと収支の数値。いじると何が変わるかは各フィールドのコメントのとおり。
    ///   gravityInterval … 1 行落ちるまでの秒。小さいほど速い。
    ///   softDropFactor  … 下キーを押している間の落下倍率（大きいほど速く落ちる）。
    ///   lockDelay       … 接地してから固定されるまでの猶予秒。移動/回転で 0 に戻る（設置面ねばり）。
    ///   maxLockResets   … その猶予リセットの上限回数。無限に延命できないための天井。
    ///   clearDuration   … ライン消し演出の長さ（秒）。この間だけ閃光が出る。
    ///   scores          … 同時に消した行数 → もらえる点（index = 行数。0..4）。
    pub type alias Rec = {
        version = Int32,
        gravityInterval = Float64,
        softDropFactor = Float64,
        lockDelay = Float64,
        maxLockResets = Int32,
        clearDuration = Float64,
        scores = List[Int32]
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/tetris.rules.json"

    /// コード側の既定値（assets/tetris.rules.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          gravityInterval = 0.8,
          softDropFactor = 8.0,
          lockDelay = 0.5,
          maxLockResets = 15,
          clearDuration = 0.35,
          scores = 0 :: 100 :: 300 :: 500 :: 800 :: Nil })

    /// n 行同時消しの得点。表の範囲外（想定外の行数）は 0 点にする（fail-open）。
    /// リテラルを配らず必ず Doc の scores を引く — 得点調整が JSON だけで完結する。
    pub def scoreFor(n: Int32, doc: Doc): Int32 =
        List.drop(n, rec(doc)#scores) |> List.head |> Option.getWithDefault(0)

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          gravityInterval = JsonCodec.floatOr("gravityInterval", d#gravityInterval, root),
          softDropFactor = JsonCodec.floatOr("softDropFactor", d#softDropFactor, root),
          lockDelay = JsonCodec.floatOr("lockDelay", d#lockDelay, root),
          maxLockResets = JsonCodec.intOr("maxLockResets", d#maxLockResets, root),
          clearDuration = JsonCodec.floatOr("clearDuration", d#clearDuration, root),
          scores = intListOr(d#scores, "scores", root) })

    /// 整数の配列を読む。配列でない・要素に数でないものが混じるときは既定へ落とす。
    def intListOr(fallback: List[Int32], key: String, obj: Map[String, Json]): List[Int32] =
        Map.get(key, obj)
            |> Option.flatMap(json -> JsonCodec.decodeList(JsonCodec.expectInt, json))
            |> Option.getWithDefault(fallback)

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
