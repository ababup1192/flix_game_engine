// BattleDoc — rpg.battle.json（戦いの数値と文言）の宣言ドキュメント層。
// Doc は「初期値の宣言」まで: 誰が先に殴るか・逃げられるか・勝ち負けの規則はコード（World）側。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod BattleDoc {
    use Util.Json.Json

    /// 戦いの数値と文言。
    ///   encounterSteps … 何歩ごとに魔物が出るか（0 以下にすると出なくなる）。
    ///   heroMaxHp / heroAttack … 主人公の体力と一撃の重さ。
    ///   foeName / foeMaxHp / foeAttack … 魔物の名前・体力・一撃の重さ。
    ///   foeAppears / heroWins / heroLoses / heroFlees … 場面ごとの 1 行。
    ///   damageSuffix … 「◯◯ に 3 の」の後ろに付ける言葉（数の入る文はコードが組む）。
    pub type alias Rec = {
        version = Int32,
        encounterSteps = Int32,
        heroMaxHp = Int32,
        heroAttack = Int32,
        foeName = String,
        foeMaxHp = Int32,
        foeAttack = Int32,
        foeAppears = String,
        heroWins = String,
        heroLoses = String,
        heroFlees = String,
        damageSuffix = String
    }

    /// 型検査が record を展開しないため、World が持つ形は名前付きの enum にする。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/rpg.battle.json"

    /// コード側の既定値（assets/rpg.battle.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1,
          encounterSteps = 14,
          heroMaxHp = 20, heroAttack = 4,
          foeName = "やまびこ", foeMaxHp = 12, foeAttack = 3,
          foeAppears = "が あらわれた！",
          heroWins = "しずかに なった。",
          heroLoses = "め の まえが まっくらに なった…",
          heroFlees = "そっと ひきかえした。",
          damageSuffix = "の ダメージ！" })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違うフィールドは既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
          encounterSteps = JsonCodec.intOr("encounterSteps", d#encounterSteps, root),
          heroMaxHp = JsonCodec.intOr("heroMaxHp", d#heroMaxHp, root),
          heroAttack = JsonCodec.intOr("heroAttack", d#heroAttack, root),
          foeName = JsonCodec.stringOr("foeName", d#foeName, root),
          foeMaxHp = JsonCodec.intOr("foeMaxHp", d#foeMaxHp, root),
          foeAttack = JsonCodec.intOr("foeAttack", d#foeAttack, root),
          foeAppears = JsonCodec.stringOr("foeAppears", d#foeAppears, root),
          heroWins = JsonCodec.stringOr("heroWins", d#heroWins, root),
          heroLoses = JsonCodec.stringOr("heroLoses", d#heroLoses, root),
          heroFlees = JsonCodec.stringOr("heroFlees", d#heroFlees, root),
          damageSuffix = JsonCodec.stringOr("damageSuffix", d#damageSuffix, root) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
