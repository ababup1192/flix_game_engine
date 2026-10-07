// UiBinding — UI の各テキスト欄に付けた「差し込み名」を、実行時の値に置き換えて流し込む。
// どの欄に何を出すかは ui.json 側に書いておけるので、コード側は「名前→表示文字列」の対応だけ渡せばよい。
// 利用例: HP の数字を毎フレーム反映する / 所持金やスコアを表示に反映する / 選択中の項目名を出す。
// 注意: 値が見つからない（None）名前は、その欄の今の文字をそのまま残す。すべて純粋な変換。

pub mod UiBinding {

    /// bindings store を走査し、resolve が Some を返した entity の text を差し替える。
    /// resolve が None の key、text コンポーネントを持たない entity は据え置く。
    pub def apply(resolve: String -> Option[String], ui: UiStore.UiWorld): UiStore.UiWorld =
        ui#bindings |> Map.foldLeftWithKey((acc, id, key) ->
            match resolve(key) {
                case None       => acc
                case Some(text) => setTextById(id, text, acc)
            }, ui)

    /// entity id の text コンポーネント文字列を差し替える。text を持たなければ no-op。
    /// bindings は entity id をキーに持つため、名前パス経由でなく id で直接引く。
    def setTextById(id: EntityId, text: String, ui: UiStore.UiWorld): UiStore.UiWorld =
        match Map.get(id, ui#texts) {
            case None       => ui
            case Some(comp) => {texts = Map.insert(id, {text = text | comp}, ui#texts) | ui}
        }
}
