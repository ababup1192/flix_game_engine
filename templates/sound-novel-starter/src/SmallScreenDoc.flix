// SmallScreenDoc — novel.small.json（小さい画面 = スマホの時だけ使う字と押せる物の大きさ）の宣言ドキュメント層。
// 置き場所（どこに並べるか）は Layout のコードが決め、ここは大きさだけ。PC・タブレット・デスクトップ版は読まない。
// fail-open — 読めない・壊れているときは defaults() へ落とし、ゲームは必ず起動する。
mod SmallScreenDoc {
    use fge::{DocJson, JsonCodec}
    use Util.Json.Json

    /// どれも design px。*TextSize = 字の大きさ、*Height = 押せる高さ。
    /// titleItem* = タイトル画面のメニューの 1 項目、button* = 読む間の下の帯のボタン、choice* = 選択肢、
    /// advBodySize / advRubySize / advNameSize = ADV の本文・ルビ・名前の字、advPanelHeight = ADV のウィンドウの高さ、
    /// back* = 画面の右上の「戻る」、tab* = セーブ・ロードのページのタブ、settingTextSize / settingRowHeight = 設定の行の字と高さ、
    /// askButton* = 確認のウィンドウのはい・いいえ。
    pub type alias Rec = {
        version = Int32,
        titleItemTextSize = Float64,
        titleItemHeight = Float64,
        buttonTextSize = Float64,
        buttonHeight = Float64,
        choiceTextSize = Float64,
        choiceHeight = Float64,
        advBodySize = Float64,
        advRubySize = Float64,
        advNameSize = Float64,
        advPanelHeight = Float64,
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

    pub def path(): String = "assets/novel.small.json"

    /// コード側の既定値（assets/novel.small.json と同じ値から出発する）。
    pub def defaults(): Doc =
        Doc.Doc({ version = 1, titleItemTextSize = 28.0, titleItemHeight = 58.0, buttonTextSize = 18.0, buttonHeight = 58.0,
                  choiceTextSize = 26.0, choiceHeight = 60.0,
                  advBodySize = 26.0, advRubySize = 13.0, advNameSize = 24.0, advPanelHeight = 196.0,
                  backTextSize = 20.0, backHeight = 58.0, tabTextSize = 20.0, tabHeight = 58.0,
                  settingTextSize = 18.0, settingRowHeight = 58.0, askButtonTextSize = 22.0, askButtonHeight = 58.0 })

    pub def fromJson(text: String): Option[Doc] =
        DocJson.decodeObject(fromRoot, text)

    def fromRoot(root: Map[String, Json]): Doc =
        let d = rec(defaults());
        let num = (key, fallback) -> JsonCodec.floatOr(key, fallback, root);
        Doc.Doc({ version = JsonCodec.intOr("version", d#version, root),
                  titleItemTextSize = num("titleItemTextSize", d#titleItemTextSize), titleItemHeight = num("titleItemHeight", d#titleItemHeight),
                  buttonTextSize = num("buttonTextSize", d#buttonTextSize), buttonHeight = num("buttonHeight", d#buttonHeight),
                  choiceTextSize = num("choiceTextSize", d#choiceTextSize), choiceHeight = num("choiceHeight", d#choiceHeight),
                  advBodySize = num("advBodySize", d#advBodySize), advRubySize = num("advRubySize", d#advRubySize),
                  advNameSize = num("advNameSize", d#advNameSize), advPanelHeight = num("advPanelHeight", d#advPanelHeight),
                  backTextSize = num("backTextSize", d#backTextSize), backHeight = num("backHeight", d#backHeight),
                  tabTextSize = num("tabTextSize", d#tabTextSize), tabHeight = num("tabHeight", d#tabHeight),
                  settingTextSize = num("settingTextSize", d#settingTextSize), settingRowHeight = num("settingRowHeight", d#settingRowHeight),
                  askButtonTextSize = num("askButtonTextSize", d#askButtonTextSize), askButtonHeight = num("askButtonHeight", d#askButtonHeight) })

    /// path の Doc を読む。読めない・壊れているときは defaults（fail-open）。
    pub def load(p: String): Doc \ Fs.FileRead =
        DocJson.loadOr(fromJson, defaults(), p)
}
