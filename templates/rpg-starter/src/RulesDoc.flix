// RulesDoc — assets/rpg.rules.json（歩く速さ・文字送り・暗転の長さ・始まりの場所とお金・依頼の手付け・宿の前・出会いの歩数）の Doc 層。
// 歩ける条件・出入口の決まりはコード（WorldField）。ここに if を書き始めたら Doc の境界を越えている。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod RulesDoc {
    use fge::{Dir4, DocJson, JsonCodec, Log}
    use Util.Json.Json

    /// 遊びの決まりの値。
    ///   secondsPerTile … 1 マス歩く秒。
    ///   cps            … 会話の文字送り（1 秒の字数）。
    ///   fadeSeconds    … 暗転の片道（覆う・晴らすのそれぞれ）の秒。
    ///   startMap / startX / startY / startFacing … 「はじめから」で立つマップとマスと向き。
    ///   startGold      … 「はじめから」の手持ちのお金。
    ///   advance        … 依頼を受けた時の手付け（<<quest accept>> が払う）。
    ///   homeMap / homeX / homeY … 宿の前（「つづきから」で立つマップとマス。下を向いて立つ）。
    ///   innSeconds     … 宿に泊まる時の暗転（覆う方）の秒。晴らす方は fadeSeconds。
    ///   minSteps / maxSteps … 次の戦いまでの歩数を引く範囲（両端を含む。出会いの組のあるマップだけ数える）。
    ///   flashSeconds   … 出会った時の点滅の秒（覆い切ったら戦いへ）。
    ///   messageWait    … 戦いの伝言を出し切ってから次へ送るまでの秒（決定で早送り）。
    ///   fxSeconds      … 戦いの演出（斬撃・当たり）の秒。その間は入力を捨て、伝言は 1 行目だけ出す。
    ///   spread         … ダメージのぶれの幅（0.125 なら 0.875〜1.125 倍）。
    ///   critRate       … 仲間の通常攻撃が会心になる率。
    ///   fleeBase / fleeSlope … にげる率 = fleeBase + (仲間の一番速い − 敵の一番速い) × fleeSlope（0.1..0.95 に収める）。
    ///   maxFoes        … 1 戦の敵の数の上限（描き場所が 3 つなので 3 より大きくしても 3）。
    ///   goldKeep       … 全滅した時に残るお金の割合（切り捨て）。
    ///   secondsPerRail … トロッコが 1 マス走る秒。
    ///   darkRadius / torchRadius … 暗いマップで見えるマスの数（先頭から）。たいまつを灯す前 / 灯した後（残りの歩数は items の lightSteps）。
    ///   sleepRate      … 敵の sleep が眠っていない仲間に効く率。
    ///   wakeRate       … 眠った人がその人の手番の頭で起きる率（眠った次の手番は必ず眠る）。
    ///   problems       … 読む時に既定へ落とした欄（load が 1 行ずつ言う）。
    pub type alias Rec = {
        version = Int32,
        secondsPerTile = Float64,
        cps = Float64,
        fadeSeconds = Float64,
        startMap = String,
        startX = Int32,
        startY = Int32,
        startFacing = Dir4.Dir4,
        startGold = Int32,
        advance = Int32,
        homeMap = String,
        homeX = Int32,
        homeY = Int32,
        innSeconds = Float64,
        minSteps = Int32,
        maxSteps = Int32,
        flashSeconds = Float64,
        messageWait = Float64,
        fxSeconds = Float64,
        spread = Float64,
        critRate = Float64,
        fleeBase = Float64,
        fleeSlope = Float64,
        maxFoes = Int32,
        goldKeep = Float64,
        secondsPerRail = Float64,
        darkRadius = Float64,
        torchRadius = Float64,
        sleepRate = Float64,
        wakeRate = Float64,
        problems = List[String]
    }

    /// WhyNot: 外で組ませない — 既定へ落とした欄と知らせる行は fromJson と既定を通さないと揃わない。
    enum RulesDocOf(Rec)

    /// 読んだ Doc（作るのは fromJson と既定だけ。中身は rec で読む）。
    pub type alias Doc = RulesDocOf

    pub def rec(d: Doc): Rec = match d { case RulesDocOf.RulesDocOf(r) => r }

    pub def path(): String = "assets/rpg.rules.json"

    /// コード側の既定（assets/rpg.rules.json と同じ値から出発する）。
    pub def defaults(): Doc =
        RulesDocOf.RulesDocOf({ version = 1, secondsPerTile = 0.22, cps = 30.0, fadeSeconds = 0.3,
                  startMap = "village", startX = 7, startY = 8, startFacing = Dir4.Dir4.Up,
                  startGold = 50, advance = 50, homeMap = "village", homeX = 3, homeY = 4, innSeconds = 1.2, problems = Nil, minSteps = 12, maxSteps = 20,
                  flashSeconds = 0.5, messageWait = 0.8, fxSeconds = 0.4, spread = 0.125, critRate = 0.03125, fleeBase = 0.5, fleeSlope = 0.03,
                  maxFoes = 3, goldKeep = 0.5, secondsPerRail = 0.08, darkRadius = 1.0, torchRadius = 3.0,
                  sleepRate = 0.6, wakeRate = 0.5 })

    /// テキストから Doc へ（fail-open）。JSON でない・形が違う欄は既定へ落とす。
    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let (startFacing, facingProblems) = facingOr(d#startFacing, root);
        RulesDocOf.RulesDocOf({ version = JsonCodec.intOr("version", d#version, root),
                  secondsPerTile = JsonCodec.floatOr("secondsPerTile", d#secondsPerTile, root),
                  cps = JsonCodec.floatOr("cps", d#cps, root),
                  fadeSeconds = JsonCodec.floatOr("fadeSeconds", d#fadeSeconds, root),
                  startMap = JsonCodec.stringOr("startMap", d#startMap, root),
                  startX = JsonCodec.intOr("startX", d#startX, root),
                  startY = JsonCodec.intOr("startY", d#startY, root),
                  startFacing = startFacing,
                  startGold = JsonCodec.intOr("startGold", d#startGold, root),
                  advance = JsonCodec.intOr("advance", d#advance, root),
                  homeMap = JsonCodec.stringOr("homeMap", d#homeMap, root),
                  homeX = JsonCodec.intOr("homeX", d#homeX, root),
                  homeY = JsonCodec.intOr("homeY", d#homeY, root),
                  innSeconds = JsonCodec.floatOr("innSeconds", d#innSeconds, root),
                  problems = facingProblems,
                  minSteps = JsonCodec.intOr("minSteps", d#minSteps, root),
                  maxSteps = JsonCodec.intOr("maxSteps", d#maxSteps, root),
                  flashSeconds = JsonCodec.floatOr("flashSeconds", d#flashSeconds, root),
                  messageWait = JsonCodec.floatOr("messageWait", d#messageWait, root),
                  fxSeconds = JsonCodec.floatOr("fxSeconds", d#fxSeconds, root),
                  spread = JsonCodec.floatOr("spread", d#spread, root),
                  critRate = JsonCodec.floatOr("critRate", d#critRate, root),
                  fleeBase = JsonCodec.floatOr("fleeBase", d#fleeBase, root),
                  fleeSlope = JsonCodec.floatOr("fleeSlope", d#fleeSlope, root),
                  maxFoes = JsonCodec.intOr("maxFoes", d#maxFoes, root),
                  goldKeep = JsonCodec.floatOr("goldKeep", d#goldKeep, root),
                  secondsPerRail = JsonCodec.floatOr("secondsPerRail", d#secondsPerRail, root),
                  darkRadius = JsonCodec.floatOr("darkRadius", d#darkRadius, root),
                  torchRadius = JsonCodec.floatOr("torchRadius", d#torchRadius, root),
                  sleepRate = JsonCodec.floatOr("sleepRate", d#sleepRate, root),
                  wakeRate = JsonCodec.floatOr("wakeRate", d#wakeRate, root) })

    /// startFacing の欄と、既定へ落とした時の知らせる行（無ければ黙って既定・知らない名前なら既定へ落として 1 行）。
    def facingOr(fallback: Dir4.Dir4, root: Map[String, Json]): (Dir4.Dir4, List[String]) =
        let name = JsonCodec.stringOr("startFacing", "", root);
        match DirName.dirOf(name) {
            case Some(dir)                    => (dir, Nil)
            case None if String.isEmpty(name) => (fallback, Nil)
            case None                         => (fallback, Log.fellBackLine("rules", "startFacing '${name}'", "${fallback}", "向きは ${DirName.names()}") :: Nil)
        }

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
