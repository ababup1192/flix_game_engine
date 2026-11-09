// RailDoc — novel.rail.json（縦の画面の操作の列 = 右端のアイコンの列と右上の …）の宣言ドキュメント層。
// 置き場所の決まり（どの順に積むか・どこから開くか）は Rail のコードが決め、ここは積み方の選びと大きさと長押しの秒だけ。
// 読み込む時に PortraitDoc の rail 欄へ組む（Controls.loadPortrait）。横の画面は読まない。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod RailDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// 列の積み方。Top(railGap) = 右上の … のすぐ下から下へ積む（… の押せる正方形の下端と列の上端の間が railGap）、
    /// Bottom(railBottom) = 画面の下から上へ積む（列の下端と画面の下の間が railBottom）。
    pub enum Anchor with Eq, ToString {
        case Top(Float64)
        case Bottom(Float64)
    }

    /// どれも design px（幅 540 の中の px）。anchor = 列の積み方、iconSize = 列の丸の直径、buttonHeight = 列の 1 段の押せる正方形の辺、
    /// railRight = 列と … の丸の右端と画面の右端の間、moreTop = … の押せる正方形の上端と画面の上の間、moreSize = … の丸の直径、
    /// moreHeight = … の押せる正方形の辺、longPressSeconds = 列のボタンを長押しと見る秒（名前のツールチップ・オートはスキップ）、
    /// tooltipTextSize = ツールチップの字、saveLoadItemWidth = しおりから開く [セーブ｜ロード] の 1 つの幅、menuWidth = … から開くメニューの幅。
    pub type alias Rec = {
        version = Int32,
        anchor = Anchor,
        iconSize = Float64,
        buttonHeight = Float64,
        railRight = Float64,
        moreTop = Float64,
        moreSize = Float64,
        moreHeight = Float64,
        longPressSeconds = Float64,
        tooltipTextSize = Float64,
        saveLoadItemWidth = Float64,
        menuWidth = Float64
    }

    /// 型検査が record を展開しないため、Res が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.rail.json"

    /// コード側の既定値（assets/novel.rail.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, anchor = Anchor.Top(defaultGap()), iconSize = 49.0, buttonHeight = 66.0, railRight = 14.0,
                  moreTop = 12.0, moreSize = 46.0, moreHeight = 66.0, longPressSeconds = 0.4, tooltipTextSize = 20.0,
                  saveLoadItemWidth = 120.0, menuWidth = 240.0 })

    /// 既定の列と … の間（anchor = top の時）と、列と画面の下の間（anchor = bottom の時）。
    def defaultGap(): Float64 = 4.0

    def defaultBottom(): Float64 = 36.0

    /// "top" / "bottom" と、その積み方だけが使う余白から積み方を作る。知らない字は top。
    def anchorOf(name: String, gap: Float64, bottom: Float64): Anchor = match name {
        case "bottom" => Anchor.Bottom(bottom)
        case _        => Anchor.Top(gap)
    }

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, root);
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  anchor = anchorOf(JsonCodec.stringOr("anchor", "top", root), num("railGap", defaultGap()), num("railBottom", defaultBottom())),
                  iconSize = num("iconSize", d#iconSize), buttonHeight = num("buttonHeight", d#buttonHeight),
                  railRight = num("railRight", d#railRight),
                  moreTop = num("moreTop", d#moreTop), moreSize = num("moreSize", d#moreSize), moreHeight = num("moreHeight", d#moreHeight),
                  longPressSeconds = num("longPressSeconds", d#longPressSeconds), tooltipTextSize = num("tooltipTextSize", d#tooltipTextSize),
                  saveLoadItemWidth = num("saveLoadItemWidth", d#saveLoadItemWidth), menuWidth = num("menuWidth", d#menuWidth) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
