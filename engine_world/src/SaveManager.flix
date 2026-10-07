// SaveManager — セーブデータをスロット番号でファイルに保存・読み出しする薄い層。
// `saves/slot{N}.json` というパス規約を固定するだけなので、番号を渡すだけでセーブ枠を扱える。
// 利用例: スロット 1 にセーブする / スロット 3 を読み込む。
// 注意: 別のパス規約が要るなら `Persistence` を直接呼ぶ。親ディレクトリ `saves/` の作成は
//   呼び出し側の責任（`Fs.WriteFile` は親ディレクトリを自動作成しない）。
pub mod SaveManager {

    /// `saves/slot{N}.json` のパス。
    pub def slotPath(slot: Int32): String = "saves/slot${slot}.json"

    /// スロット `slot` に `data` を書き出す。失敗時は `Err(message)`。
    pub def write(slot: Int32, data: a): Result[String, Unit] \ Fs.FileWrite with Saveable[a] =
        Persistence.save(slotPath(slot), data)

    /// スロット `slot` から読み出す。ファイル不在・パース失敗・形式不一致は `None`。
    pub def read(slot: Int32): Option[a] \ Fs.FileRead with Saveable[a] =
        Persistence.load(slotPath(slot))
}
