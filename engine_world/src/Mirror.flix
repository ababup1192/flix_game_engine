// Mirror — 面（夜のガラス・鏡・磨いた床・水たまり）に映る姿を、ドット絵の走り
// （PxSprite.Run）から組む。映り込み用の絵を別に描かずに済むので、元の絵を直せば
// 映るほうも一緒に直る。
// 利用例: 水槽のガラスに主人公の顔が映る / 夜の窓ガラスに自分が映る / 磨いた廊下に足もとが映る。  jargon-ok: 物理的な窓ガラスの例で、エンジンの窓・パネル・範囲とは無関係
// 注意: 映るかどうか（距離・向き・場面）と、どのコマをどこへ置くかは呼び側が決める。
//
// アトラスの 1 クアッド（PxSprite.drawQuad）の絵は映せない — 明るい色と暗い色で重ね方を
// 分けるには画素ごとの色が要り、クアッドの色は GPU の中にしかないため。同じ絵をただ薄く
// 置き直すだけなら Render.fade + blended + clippedAll の合成で足りる（この関数は要らない）。
//
// 刈るのを Render.clippedAll に任せないのは、clip 矩形は走りを**落とせない**から — 面から
// 外れた走りと、縁で幅の消えた走りを捨てるふるいがどのみち要る。
pub mod Mirror {

    /// 面の返し方。alpha = 濃さ、lit = これ以上明るい色は光として面に足す、
    /// floor = これより暗い色は返さない、dim = 影として重ねる側の減衰。
    ///
    /// 夜の面は、明るいところは**光として返し**（Add。向こう側の色に足す）、髪や瞳のような
    /// 暗いところは**向こうを隠す影**になる（Normal）。全部を薄く足すと面にとけた白い染みに
    /// しかならず、姿に見えない。いちばん暗い輪郭まで返すと、今度は面に紙を貼ったように見える。
    pub type alias Style = { alpha = Float64, lit = Float64, floor = Float64, dim = Float64 }

    /// 夜のガラス。明暗を強く分ける（暗い部屋を背にした面の見え方）。
    pub def glassStyle(): Style =
        { alpha = 0.8, lit = 0.35, floor = 0.1, dim = 0.95 }

    /// 明暗を分けない素の面（磨いた床・ためし置き）。全部を同じ濃さで薄く返す。
    pub def plainStyle(alpha: Float64): Style =
        { alpha = alpha, lit = 2.0, floor = 0.0, dim = 1.0 }

    /// 走りの列を面に映す。走りは**面の上の座標に置いてから**渡すこと
    /// （どのコマのどこを面のどこへ合わせるかは呼び側の決めごと）。
    /// 面から縦にはみ出した走りは落とし、横にはみ出した走りは縁で刈る。
    ///
    /// 水面のゆらぎのような「行ごとの横ずれ」は、渡す前に走りの x を動かして作る
    /// （Sway と組み合わせる）— 面の性質ではなく映す側の前処理なので、ここには持たせない。
    pub def runs(spec: { runs = List[PxSprite.Run], glass = Rect2.Rect2, style = Style,
                         resolver = String -> Color, z = Int32 }): List[Render.PlacedItem] =
        spec#runs |> List.filterMap(span ->
            one(spec#glass, spec#style, spec#resolver, spec#z, span))

    /// 走り 1 本ぶん。返さない走りは None（面の外・暗すぎ・縁で幅が消えた）。
    def one(glass: Rect2.Rect2, style: Style, resolver: String -> Color, z: Int32,
            span: PxSprite.Run): Option[Render.PlacedItem] =
        let color = resolver(span#key);
        let lum = Color.brightness(color);
        if (span#y < glass#position#y or span#y > Rect2.end(glass)#y or lum < style#floor) None
        else {
            // 横だけ面と交わらせる（縦は上で「丸ごと落とすか残すか」を決めたあと）。
            let cut = Rect2.intersect(glass,
                { position = { x = span#x, y = span#y }, size = { x = span#w, y = span#h } });
            if (cut#size#x < 1.0) None
            else {
                let lit = lum >= style#lit;
                let box = RawDraw.box({ x = cut#size#x, y = span#h }, color, z)
                    |> Render.fade(
                           if (lit) style#alpha * lum else style#alpha * style#dim);
                Some({ at = { x = cut#position#x, y = span#y },
                       item = if (lit) Render.blended(DrawCmd.BlendMode.Add, box) else box })
            }
        }
}
