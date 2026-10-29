// Member — 仲間の顔ぶれ（固定の 3 人のうち、いま居る人）と、Doc・会話・マップで仲間を指す名前。
// 顔ぶれは物語に結び付くのでコードの enum に置く。仲間ごとの数は Doc（assets/rpg.party.json）、
// 加わった順と今の HP などは Party。Doc（PartyDoc・ItemsDoc）と Party の両方がこれを使う。
pub mod Member {

    /// 仲間。Doc の鍵・会話のコマンド（<<join mina>>）・マップの人の id は idOf の名前。
    pub enum Member with Eq, Order, ToString {
        case Luka
        case Mina
        case Toto
    }

    /// 全員（Doc の鍵を引く順）。
    pub def all(): List[Member] = Member.Luka :: Member.Mina :: Member.Toto :: Nil

    pub def idOf(m: Member): String = match m {
        case Member.Luka => "luka"
        case Member.Mina => "mina"
        case Member.Toto => "toto"
    }

    /// 全員の名前（Doc の鍵・マップの gate に書ける名前）。
    pub def ids(): List[String] = all() |> List.map(idOf)

    /// 名前 → 仲間（知らない名前は None）。
    pub def memberOf(name: String): Option[Member] = all() |> List.find(m -> idOf(m) == name)
}
