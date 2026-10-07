// RandomUtil — 乱数を使うちょっとした操作をまとめる。リストから 1 つ選ぶ・範囲内の実数を引く。
// 毎回書きがちな長さ計算や範囲変換を隠すので、呼び側は「選ぶ」「範囲で引く」だけを書ける。
// 利用例: 敵の行動をランダムに選ぶ / 出現位置を範囲内でばらつかせる。
pub mod RandomUtil {
    use Math.Random

    pub def pick(l: List[a]): Option[a] \ Math.Random =
        let len = List.length(l);
        if (len == 0) None
        else
            let r = Math.Random.randomFloat64();
            let idx = Float64.truncateToInt32(Float64.floor(r * Int32.toFloat64(len)));
            List.nth(idx, l)
}
