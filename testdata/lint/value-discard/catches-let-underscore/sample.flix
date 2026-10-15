// 鳴る: 純粋な知らせ・式が次の行にある形・bug! の止め。鳴らない: コメントと文字列と discard と _x。
mod Sample {
    def warned(x: Int32): Int32 =
        let _ = Log.warn("消える");
        x

    def nextLine(x: Int32): Int32 =
        let _ =
            Log.warn("これも消える");
        x

    def guard(x: Int32): Int32 =
        let _ = if (x < 0) bug!("負") else ();
        x

    // let _ = Log.warn(..) と書かない
    def quiet(_unused: Int32, xs: Array[Int32, Static]): Unit \ IO =
        let msg = "let _ = は消える";
        discard Array.length(xs);
        println(msg)
}
