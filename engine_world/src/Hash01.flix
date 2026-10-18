// Hash01 — 2つの整数から、0以上1未満のばらついた数を1つ決める。
// 同じ入力なら結果は毎回同じなので、たくさんの似たものに「それぞれの個性」を、
// どこにも保存せず番号から即座に与えられる（種も生成も保存も要らない）。
// 利用例: 粒子ごとに速さや位相をずらす / タイルごとに色みを変える / 装飾を少しずつ散らす /
// 番号で列から 1 つ選ぶ（`Hash01.pickBy({ index = 敵の番号, channel = 0 }, 技の列)`・台詞の差分・タイルの柄）。
//
// なぜ乱数(seed を持つ乱数生成器)でなくハッシュか —リファレンス画像との決定性のため。座標→[0,1) の
// 写像なので種も内部状態も持たず、毎フレーム・何度生成し直しても「同じ位置に同じばらつき」が
// 出る(霧のむら・畑のゆらぎ・草の傾き等)。乱数だと呼ぶ順や回数で結果が変わり、
// gallery/ vs reference/ のバイト比較(bench)が安定しない。ばらつきが欲しいのに再現もしたい、
// を両立させる初学者向けの定石がこれ。
// 注意: 見た目がばらつく程度の簡易なもの。暗号用途や厳密な均一さには向かない。

pub mod Hash01 {

    /// 添字 `index`・チャンネル `channel` に対する [0, 1) の小数。同じ添字の二つの
    /// チャンネル（あるいは二つの添字の同じチャンネル）は無相関に見える値を返すので、一つの
    /// ものはチャンネルを変えるだけで独立した複数の数を引ける。決定論的: 同じ入力は常に
    /// 同じ出力へ写る。
    pub def at(index: Int32, channel: Int32): Float64 =
        let h = index * 374761393 + channel * 668265263 + 1442695041;
        Int32.toFloat64(Int32.modulo(h * (h + 30011), 100003)) / 100003.0

    /// indexOf / pickBy の鍵。index = 何番目の物か（敵の番号・日付・タイルの通し番号）、
    /// channel = 同じ物から別の選びを引くときの番号（台詞・色・向き）。
    pub type alias Key = { index = Int32, channel = Int32 }

    /// 鍵から 0..n-1 の添字を 1 つ選ぶ（n <= 0 なら 0）。同じ鍵と n なら毎回同じ。
    pub def indexOf(key: Key, n: Int32): Int32 =
        if (n <= 0) 0
        else {
            let scaled = Float64.floor(at(key#index, key#channel) * Int32.toFloat64(n));
            let picked = Float64.tryToInt32(scaled) |> Option.getWithDefault(0);
            Int32.max(0, Int32.min(n - 1, picked))
        }

    /// 鍵で列から 1 つ選ぶ（空なら None）。台詞の差分・敵の出す技・タイルの柄を、乱数の状態を
    /// 持たずに選ぶ。
    pub def pickBy(key: Key, xs: List[a]): Option[a] =
        List.nth(indexOf(key, List.length(xs)), xs)
}
