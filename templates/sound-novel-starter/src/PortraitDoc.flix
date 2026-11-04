// PortraitDoc — novel.portrait.json（縦の画面 = 縦に持ったスマホ・タブレットで縦の design で起動した時だけ使う字と押せる物の大きさ）の宣言ドキュメント層。
// 置き場所（どこに並べるか）は Layout のコードが決め、ここは大きさだけ。横の画面（PC・横持ち・デスクトップ版）は読まない。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod PortraitDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// どれも design px（幅 540 の中の px）。*TextSize = 字の大きさ、*Height = 押せる高さ。
    /// bodySize / rubySize / nameSize = 頁の本文・ルビ・台詞に添える名前の字、logTextSize = バックログの本文の字、
    /// iconSize = 頁の下の操作の丸いアイコンの直径、buttonHeight = その押せる高さ（幅も同じ）、
    /// menuItem* = 歯車から開くメニューの 1 項目、choice* = 選択肢、titleItem* = タイトル画面のメニューの 1 項目、
    /// back* = 画面の右上の「戻る」、tab* = セーブ・ロードのページのタブ、settingTextSize / settingRowHeight = 設定の行の字と高さ、
    /// askButton* = 確認のウィンドウのはい・いいえ。
    pub type alias Rec = {
        version = Int32,
        bodySize = Float64,
        rubySize = Float64,
        nameSize = Float64,
        logTextSize = Float64,
        iconSize = Float64,
        buttonHeight = Float64,
        menuItemTextSize = Float64,
        menuItemHeight = Float64,
        choiceTextSize = Float64,
        choiceHeight = Float64,
        titleItemTextSize = Float64,
        titleItemHeight = Float64,
        backTextSize = Float64,
        backHeight = Float64,
        tabTextSize = Float64,
        tabHeight = Float64,
        settingTextSize = Float64,
        settingRowHeight = Float64,
        askButtonTextSize = Float64,
        askButtonHeight = Float64
    }

    /// 型検査が record を展開しないため、Res が持つ Doc は 1 case の enum で包む。
    pub enum Doc(Rec)

    pub def rec(d: Doc): Rec = match d { case Doc.Doc(r) => r }

    pub def path(): String = "assets/novel.portrait.json"

    /// コード側の既定値（assets/novel.portrait.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, bodySize = 25.0, rubySize = 12.0, nameSize = 16.0, logTextSize = 21.0,
                  iconSize = 49.0, buttonHeight = 72.0, menuItemTextSize = 22.0, menuItemHeight = 66.0, choiceTextSize = 23.0, choiceHeight = 76.0,
                  titleItemTextSize = 28.0, titleItemHeight = 68.0, backTextSize = 20.0, backHeight = 66.0,
                  tabTextSize = 20.0, tabHeight = 66.0, settingTextSize = 20.0, settingRowHeight = 66.0,
                  askButtonTextSize = 22.0, askButtonHeight = 66.0 })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, root);
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  bodySize = num("bodySize", d#bodySize), rubySize = num("rubySize", d#rubySize),
                  nameSize = num("nameSize", d#nameSize), logTextSize = num("logTextSize", d#logTextSize),
                  iconSize = num("iconSize", d#iconSize), buttonHeight = num("buttonHeight", d#buttonHeight),
                  menuItemTextSize = num("menuItemTextSize", d#menuItemTextSize), menuItemHeight = num("menuItemHeight", d#menuItemHeight),
                  choiceTextSize = num("choiceTextSize", d#choiceTextSize), choiceHeight = num("choiceHeight", d#choiceHeight),
                  titleItemTextSize = num("titleItemTextSize", d#titleItemTextSize), titleItemHeight = num("titleItemHeight", d#titleItemHeight),
                  backTextSize = num("backTextSize", d#backTextSize), backHeight = num("backHeight", d#backHeight),
                  tabTextSize = num("tabTextSize", d#tabTextSize), tabHeight = num("tabHeight", d#tabHeight),
                  settingTextSize = num("settingTextSize", d#settingTextSize), settingRowHeight = num("settingRowHeight", d#settingRowHeight),
                  askButtonTextSize = num("askButtonTextSize", d#askButtonTextSize), askButtonHeight = num("askButtonHeight", d#askButtonHeight) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
