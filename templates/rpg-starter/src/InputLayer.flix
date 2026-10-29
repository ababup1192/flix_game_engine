// InputLayer — 入力を受ける一番手前の層を 1 か所で決める。キーの振り分け（Controls）はこの値を match するだけにする。
// 手前から: 終了の確認 → 暗転の途中・戦いの演出の途中（入力を捨てる）→ タイトル → フィールドに開いているウィンドウ（会話・メニュー・店・知らせ）→ 歩ける。
// 戦いは「演出（Busy）→ 伝言（BattleMessage）」を 1 手ずつ繰り返し、選ぶ番になったら BattleChoose。
// 開いているウィンドウは種類ごとの case（閉じている時の case は持たない。振り分けに死んだ枝を作らない）。
mod InputLayer {
    use World.{FieldWindow}

    pub enum Layer {
        case Asking(World.Ask)       // Esc の終了の確認（どの場面より手前）
        case Busy                    // 暗転の途中・トロッコで走っている（入力を捨てる）
        case Title(World.TitleItem)  // タイトルのメニュー
        case Talk(World.TalkState)   // 会話のウィンドウ
        case Menu(World.MenuPage)    // フィールドのメニュー
        case Shop(World.ShopPage)    // 道具屋
        case Notice                  // メニューの知らせ
        case Walking                 // ウィンドウが閉じていて歩ける
        case BattleChoose(Member.Member, World.CommandPage)  // 戦いのコマンドを選んでいる（誰の・どのページ）
        case BattleMessage           // 戦いの伝言を出している（決定で出し切る・次へ）
    }

    pub def layerOf(w: World.World): Layer = match (w#ask, w#scene) {
        case (Some(ask), _)                => Layer.Asking(ask)
        case (None, World.Scene.Title(it)) => Layer.Title(it)
        case (None, World.Scene.Field(_))  => World.fieldRecOf(w) |> Option.map(fieldLayerOf) |> Option.getWithDefault(Layer.Busy)
        case (None, World.Scene.Battle(_)) => battleLayerOf(w)
    }

    def battleLayerOf(w: World.World): Layer =
        if (WorldBattle.isBusy(w)) Layer.Busy
        else WorldBattle.choosingOf(w) |> Option.map(match (m, page) -> Layer.BattleChoose(m, page)) |> Option.getWithDefault(Layer.BattleMessage)

    def fieldLayerOf(r: World.FieldRec): Layer = match r#stride {
        case _ if Option.nonEmpty(r#transition) => Layer.Busy
        case _ if World.isRiding(r)             => Layer.Busy
        case _                                  => windowLayerOf(r#window)
    }

    def windowLayerOf(window: FieldWindow): Layer = match window {
        case FieldWindow.Closed        => Layer.Walking
        case FieldWindow.Talk(t)       => Layer.Talk(t)
        case FieldWindow.Menu(page)    => Layer.Menu(page)
        case FieldWindow.Shop(_, page, _) => Layer.Shop(page)
        case FieldWindow.Notice(_)     => Layer.Notice
    }

    /// 層の名前だけ（flow の問いと状態の 1 行）。
    pub def nameOf(layer: Layer): String = match layer {
        case Layer.Asking(_) => "Asking"
        case Layer.Busy      => "Busy"
        case Layer.Title(_)  => "Title"
        case Layer.Talk(_)   => "Talk"
        case Layer.Menu(_)   => "Menu"
        case Layer.Shop(_)   => "Shop"
        case Layer.Notice    => "Notice"
        case Layer.Walking   => "Walking"
        case Layer.BattleChoose(_, _) => "BattleChoose"
        case Layer.BattleMessage => "BattleMessage"
    }
}
