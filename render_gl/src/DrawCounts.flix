// RenderDrawCounts — 2D の draw call の数と、前の draw call に続けられなかった理由ごとの数（FrameDiagnostics.Draw2dCounts の元）。
// 数は Int32 の配列 1 本に置く。数える所（RenderFrame）は draw call を 1 つ出すごとに足すだけで、描き物 1 個ごとには何もしない。
// 理由の決まり（優先の順）は FrameDiagnostics.Draw2dBatchBreaks。
mod RenderDrawCounts {

    /// 数の入れ物。前半（0〜6）= 前に取り出してからの数・後半（7〜13）= 最後に画面へ塗り終えた時の数の写し。
    /// 並びは drawCalls・target・kind・texture・blend・clip・mask。
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

    /// 全部 0 の入れ物。
    pub def fresh(): Holder \ IO = Array.repeat(Static, 2 * slots(), 0)

    /// holder の offset から slots() 個の数を読む。
    def countsAt(offset: Int32, holder: Holder): FrameDiagnostics.Draw2dCounts \ IO =
        let at = (slot: Int32) -> Array.get(offset + slot, holder);
        { drawCalls = at(drawCallsSlot()),
          batchBreaks = { target = at(targetSlot()), kind = at(kindSlot()), texture = at(textureSlot()),
                          blend = at(blendSlot()), clip = at(clipSlot()), mask = at(maskSlot()) } }

    /// 前に取り出してからの数を返し、0 に戻す。
    pub def take(holder: Holder): FrameDiagnostics.Draw2dCounts \ IO =
        let counts = countsAt(0, holder);
        reset(holder);
        counts

    /// 前に取り出してからの数を 0 に戻す（写しは残す）。
    pub def reset(holder: Holder): Unit \ IO =
        List.range(0, slots()) |> List.forEach(i -> Array.put(0, i, holder))

    /// 今の数を「最後に画面へ塗り終えた時の数」として写す。
    pub def markScreenFrame(holder: Holder): Unit \ IO =
        List.range(0, slots()) |> List.forEach(i -> Array.put(Array.get(i, holder), slots() + i, holder))

    /// 最後に画面へ塗り終えた時の数（取り出した後でも読める）。
    pub def lastScreenFrame(holder: Holder): FrameDiagnostics.Draw2dCounts \ IO = countsAt(slots(), holder)
}
