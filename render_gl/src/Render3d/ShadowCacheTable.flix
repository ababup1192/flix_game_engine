// Render3d.ShadowCacheTable — 影の地図の控え（Render3d.GlShadowCache・Render3d.WebGpuShadowCache）の表を、GL と WebGPU が同じ関数で引く・外す。
// 鍵（Render3d.ShadowMaps.cacheKeyOf）→ 控えを引く・コマの終わりに残す数を超えた古い物を選ぶ・描き直しが続いたら知らせる、をここに置く。
// 控えの中身（GL の FBO・WebGPU の texture と group）を作る・捨てるのは backend。
// WhyNot: 選んだ控えをここで捨てない — WebGPU は同じコマの後の pass がまだ読んでいる事があり、1 コマ遅らせて捨てる。捨て方は backend ごとに違う。
mod Render3d.ShadowCacheTable {

    /// 控え 1 つと、最後に使った世代。
    pub type alias Slot[e: Type] = { entry = e, lastUsed = Ref[Int64, Static] }

    /// 表。slots = 鍵 → 控え・usedThisFrame = 今のコマに使った控えの数（残す数の目安）・
    /// redrawnThisFrame = 今のコマに描き直したか・missStreak と missWarned = 描き直しが続いた数と知らせたか（Render3d.ShadowMaps.noteCacheMisses）。
    pub type alias Table[e: Type] = {
        slots = Ref[Map[String, Slot[e]], Static], usedThisFrame = Ref[Int32, Static],
        redrawnThisFrame = Ref[Bool, Static], missStreak = Ref[Int32, Static], missWarned = Ref[Bool, Static]
    }

    /// 控えを残す数の下限（点光源 2 本の 6 面と太陽が入る）。
    def minKept(): Int32 = 16

    pub def fresh(): Table[e] \ IO =
        { slots = Ref.fresh(Static, Map.empty()), usedThisFrame = Ref.fresh(Static, 0),
          redrawnThisFrame = Ref.fresh(Static, false), missStreak = Ref.fresh(Static, 0), missWarned = Ref.fresh(Static, false) }

    /// 鍵 key の控え（無ければ create で作る）と、今作ったか。どちらでも最後に使った世代を gen にする。
    pub def ensure(t: Table[e], gen: Int64, key: String, create: Unit -> e \ IO): (e, Bool) \ IO =
        Ref.put(Ref.get(t#usedThisFrame) + 1, t#usedThisFrame);
        match Map.get(key, Ref.get(t#slots)) {
            case Some(s) =>
                Ref.put(gen, s#lastUsed);
                (s#entry, false)
            case None =>
                Ref.put(true, t#redrawnThisFrame);
                let made = create();
                Ref.put(Map.insert(key, { entry = made, lastUsed = Ref.fresh(Static, gen) }, Ref.get(t#slots)), t#slots);
                (made, true)
        }

    /// 画面のコマの終わりに 1 回: 使った数の 2 倍（下限 minKept()）を超える控えを、古く使った物から表から外して返す（捨てるのは呼ぶ側）。
    pub def endFrame(t: Table[e]): List[e] \ IO =
        if (Ref.get(t#usedThisFrame) > 0) Render3d.ShadowMaps.noteCacheMisses(t#missStreak, t#missWarned, Ref.get(t#redrawnThisFrame)) else ();
        Ref.put(false, t#redrawnThisFrame);
        let kept = Int32.max(minKept(), 2 * Ref.get(t#usedThisFrame));
        Ref.put(0, t#usedThisFrame);
        let all = Ref.get(t#slots);
        let over = Map.size(all) - kept;
        if (over <= 0) Nil
        else {
            let byAge = Map.toList(all) |> List.map(kv -> (Ref.get(snd(kv)#lastUsed), kv)) |> Sort.sortStableBy(fst);
            let dropped = List.take(over, byAge) |> List.map(snd);
            Ref.put(List.foldLeft((m, kv) -> Map.remove(fst(kv), m), all, dropped), t#slots);
            List.map(kv -> snd(kv)#entry, dropped)
        }

    /// 表の控えを全部外して返す（描き手を手放す時。捨てるのは呼ぶ側）。
    pub def takeAll(t: Table[e]): List[e] \ IO =
        let all = Ref.get(t#slots) |> Map.valuesOf |> List.map(s -> s#entry);
        Ref.put(Map.empty(), t#slots);
        all

    /// 控えの数。
    pub def sizeOf(t: Table[e]): Int32 \ IO = Map.size(Ref.get(t#slots))
}
