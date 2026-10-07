// Replay — 入力の列（Cue = 1つの入力を n フレーム保持）を順番に tick へ流し込み、
// ゲームプレイをプログラムから再現する。同じ入力列と同じフレーム時間なら結果は毎回
// 同じになるので、「この手順で遊ぶとこうなる」を機械が保証できる。
// 利用例: 面クリアの手順をテストとして固定する / プレイをそのまま GIF にする /
// 不具合の再現手順をデータで渡す。

pub mod Replay {

    /// Trace の一拍: この input を frames フレームのあいだ保持する。入力型 i は多相
    /// ゆえ、方向キーの record でも真偽フラグでも任意の入力型に成立する。
    pub type alias Cue[i] = { input = i, frames = Int32 }

    /// Trace を最後まで駆動し、終端の World を返す。各 Cue について tick を frames 回、
    /// 同じ input と dt で適用する。（run は Flix の予約語ゆえ、駆動関数は play と呼ぶ。）
    pub def play(tick: (i, Float64, w) -> w, dt: Float64, cues: List[Cue[i]], initial: w): w =
        List.foldLeft((w, cue) -> playCue(tick, dt, cue#frames, cue#input, w), initial, cues)

    def playCue(tick: (i, Float64, w) -> w, dt: Float64, n: Int32, input: i, w: w): w =
        if (n <= 0) w
        else playCue(tick, dt, n - 1, input, tick(input, dt, w))

    /// Trace の各フレームを順に並べた列 — GIF・解析・スクラブの原反。initial 自身は
    /// 含まず、tick を 1 回適用するごとの World を最古から順に積む。
    pub def timeline(tick: (i, Float64, w) -> w, dt: Float64, cues: List[Cue[i]], initial: w): List[w] =
        let (_, rev) = List.foldLeft((acc, cue) -> {
            let (w, filmed) = acc;
            cueFrames(tick, dt, cue#frames, cue#input, w, filmed)
        }, (initial, Nil), cues);
        List.reverse(rev)

    def cueFrames(tick: (i, Float64, w) -> w, dt: Float64, n: Int32, input: i, w: w,
                  filmed: List[w]): (w, List[w]) =
        if (n <= 0) (w, filmed)
        else {
            let w1 = tick(input, dt, w);
            cueFrames(tick, dt, n - 1, input, w1, w1 :: filmed)
        }
}
