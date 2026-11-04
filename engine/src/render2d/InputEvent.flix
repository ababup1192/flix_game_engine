/// InputEvent — 現在フレームで押されているキー・マウスボタンをまとめて取得する。
/// 毎フレーム全キーを走査してセットで返すので、押下エッジは呼び側が前フレームと差分して取る。
/// 利用例: フレーム開始時に押下キー集合を取り、前フレームとの差分で決定/移動を判定する。

pub mod InputEvent {

    /// 現在押されているキーのセットを取得する（GameEngine.allKeys() を全て走査）
    pub def currentKeys(): Set[GameEngine.Key] \ Platform.Input =
        List.foldLeft((acc, key) ->
            if (Platform.Input.isKeyPressed(key)) Set.insert(key, acc)
            else acc,
            Set.empty(),
            GameEngine.allKeys())
}
