// RenderDrawCounts — 2D の draw call の数と、前の draw call に続けられなかった理由ごとの数（FrameDiagnostics.Draw2dCounts の元）。
// 数は Int32 の配列 1 本に置く。数える所（RenderFrame）は draw call を 1 つ出すごとに足すだけで、描き物 1 個ごとには何もしない。
// 理由の決まり（優先の順）は FrameDiagnostics.Draw2dBatchBreaks。
mod RenderDrawCounts {

    /// 数の入れ物。slots() 個ずつ 3 組: 今のコマ（Pass と画面を描いている途中の数）・最後に画面へ塗り終えたコマの数・
    /// 前に取り出してから塗り終えたコマの合計。組の中の並びは drawCalls・target・kind・texture・blend・clip・mask。
    // WhyNot: 取り出す時に今のコマの数を 0 に戻さない — 誰も取り出さない間（診断を集めていても App が止まっている時）に数がコマをまたいで溜まり、
    //   コマの最初の draw call が target の切れ目に数えられる。コマの区切りは画面へ塗り終えた時だけにする。
    pub type alias Holder = Array[Int32, Static]

    /// 数の種類の数（drawCalls と理由 6 つ）。
    pub def slots(): Int32 = 7

    pub def drawCallsSlot(): Int32 = 0
    pub def targetSlot(): Int32 = 1
    pub def kindSlot(): Int32 = 2
    pub def textureSlot(): Int32 = 3
    pub def blendSlot(): Int32 = 4
    pub def clipSlot(): Int32 = 5
    pub def maskSlot(): Int32 = 6

    def lastBase(): Int32 = slots()

    def totalBase(): Int32 = 2 * slots()

    /// 全部 0 の入れ物。
    pub def fresh(): Holder \ IO = Array.repeat(Static, 3 * slots(), 0)

    /// holder の offset から slots() 個の数を読む。
    def countsAt(offset: Int32, holder: Holder): FrameDiagnostics.Draw2dCounts \ IO =
        let at = (slot: Int32) -> Array.get(offset + slot, holder);
        { drawCalls = at(drawCallsSlot()),
          batchBreaks = { target = at(targetSlot()), kind = at(kindSlot()), texture = at(textureSlot()),
                          blend = at(blendSlot()), clip = at(clipSlot()), mask = at(maskSlot()) } }

    /// 画面へ塗り終えた: 今のコマの数を「最後のコマ」へ写し、取り出しを待つ合計へ足して、今のコマを 0 に戻す。
    pub def endScreenFrame(holder: Holder): Unit \ IO = endScreenFrameFrom(0, holder)

    // WhyNot: List.range と閉包で回さない — 診断を集めていなくても毎コマ通る所で、列と閉包の割り当てを足さない。
    def endScreenFrameFrom(i: Int32, holder: Holder): Unit \ IO =
        if (i >= slots()) ()
        else {
            let n = Array.get(i, holder);
            Array.put(n, lastBase() + i, holder);
            Array.put(Array.get(totalBase() + i, holder) + n, totalBase() + i, holder);
            Array.put(0, i, holder);
            endScreenFrameFrom(i + 1, holder)
        }

    /// 前に取り出してから塗り終えたコマの合計を返し、0 に戻す。
    pub def take(holder: Holder): FrameDiagnostics.Draw2dCounts \ IO =
        let counts = countsAt(totalBase(), holder);
        discardTotal(holder);
        counts

    /// 取り出しを待つ合計を 0 に戻す（誰も取り出さない間に溜め続けない）。
    pub def discardTotal(holder: Holder): Unit \ IO = discardTotalFrom(0, holder)

    def discardTotalFrom(i: Int32, holder: Holder): Unit \ IO =
        if (i >= slots()) ()
        else {
            Array.put(0, totalBase() + i, holder);
            discardTotalFrom(i + 1, holder)
        }

    /// 最後に画面へ塗り終えたコマの数（取り出した後でも読める）。
    pub def lastScreenFrame(holder: Holder): FrameDiagnostics.Draw2dCounts \ IO = countsAt(lastBase(), holder)
}
