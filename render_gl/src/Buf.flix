// RenderBuf — GPU へ流す数値を書き溜める、使い回しの入れ物。
// 1 フレームぶんの頂点やインスタンスをここへ直に書き、そのまま GL へ渡す。
// 利用例: スプライトの一括描画 / 多角形の一括描画。

mod RenderBuf {
    import fge.gl.GlContext
    import fge.gl.GlContext
    import fge.gl.GlContext
    import java.nio.FloatBuffer

    /// 書き込み先の入れ物。中身を差し替えられるように 1 スロットの配列で持つ。
    /// Java の配列でなく直接メモリの入れ物を使うのは、書いた範囲だけを
    /// 位置と上限で切り出してそのまま GL へ渡せる（写し替えが要らない）ため。
    pub type alias Buf = { cell = Array[FloatBuffer, Static], room = Array[Int32, Static] }

    /// 入れ物を 1 つ作る（起動時に 1 回だけ）。
    pub def make(gl: GlContext, room: Int32): Buf \ IO =
        let n = Int32.max(1, room);
        { cell = Array#{gl.allocFloats(n)} @ Static, room = Array#{n} @ Static }

    /// いま入る数（float 何個ぶんか）。
    pub def room(b: Buf): Int32 \ IO = Array.get(0, b#room)

    /// 書き込み先そのもの。
    pub def buffer(b: Buf): FloatBuffer \ IO = Array.get(0, b#cell)

    /// need 個ぶん入るまで大きくする。**書きかけの中身は捨てられる**ので、
    /// 溜めているものが無いときにだけ呼ぶこと。
    /// 倍ずつ広げるのは、少しずつ足りなくなるたびに取り直すと、
    /// 場面が重くなる途中でずっと確保し直しが続くため。
    pub def ensure(gl: GlContext, b: Buf, need: Int32): Unit \ IO =
        let have = Array.get(0, b#room);
        if (have >= need) ()
        else {
            let grown = grow(have, need);
            gl.freeFloats(Array.get(0, b#cell));
            Array.put(gl.allocFloats(grown), 0, b#cell);
            Array.put(grown, 0, b#room)
        }

    def grow(have: Int32, need: Int32): Int32 =
        if (have >= need) have else grow(Int32.max(1, have) * 2, need)
}
