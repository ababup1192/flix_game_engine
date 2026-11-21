// RoomCaption — 画面の下に出す部屋の名前を、どの部屋にするかの決まり（純粋）と、出る・消えるの間の進め方。
//
// 決まり: (a) 部屋の中（表の rooms の四角・廊下と階段の四角を除く）にいる時は、その部屋の名前。
//         (b) 廊下（どの部屋の四角にも入っていない・廊下と階段の四角の中）にいる時は、見ている向きの近くの教室のプレート
//             （表の signs。戸口の上に突き出す名前の板）のうち、reach m 以内で、視線の正面から angleDeg 度以内の物。
//             いくつもあれば、角が小さい方を先に（同じ角なら近い方）。
//         どちらでもない時は出さない。
// WhyNot: 一番近いプレートを出さない — 廊下の両側に部屋が並ぶので、背中の側の部屋の名前が出て、入った部屋と字幕が食い違った。
mod RoomCaption {
    use fge::{Num, Vec3}

    /// 決まりの値（walk.kind.json）。reach = 廊下から見るプレートまでの距離・angleDeg = 視線の正面からの角の上限。
    pub type alias Rule = { reach = Float64, angleDeg = Float64 }

    /// 出す部屋の名前（出さない時は None）。feet = 足元・yaw = 左右の向き（ラジアン・0 で +Z・増えると +X へ）。
    pub def targetOf(layout: Layout.Layout, rule: Rule, feet: Vec3.Vec3, yaw: Float64): Option[String] =
        match roomIn(layout, feet) {
            case Some(name) => Some(name)
            case None       => facedSign(layout, rule, feet, yaw)
        }

    /// 足元が入っている部屋の名前（廊下と階段の四角は部屋に数えない）。
    def roomIn(layout: Layout.Layout, feet: Vec3.Vec3): Option[String] =
        let index = Layout.floorIndexAt(feet#y, layout);
        Layout.floorAt(index, layout) |> Option.flatMap(f ->
            f#rooms |> List.find(r -> r#kind != "corridor" and r#kind != "stairs"
                                      and feet#x >= r#min#x and feet#x <= r#max#x and feet#z >= r#min#y and feet#z <= r#max#y)
                |> Option.map(r -> r#name))

    /// 見ている向きの近くのプレートの名前。プレートは足元と同じ階（高さの差 1.6 m 以内の目の上の板）だけを見る。
    def facedSign(layout: Layout.Layout, rule: Rule, feet: Vec3.Vec3, yaw: Float64): Option[String] =
        let limit = rule#angleDeg * Num.pi() / 180.0;
        layout#signs
            |> List.filter(s -> Float64.abs(s#pos#y - feet#y - 2.0) < 1.6)
            |> List.filterMap(s -> {
                let dx = s#pos#x - feet#x;
                let dz = s#pos#z - feet#z;
                let dist = Num.sqrt(dx * dx + dz * dz);
                let off = Float64.abs(angleBetween(Num.atan2(dx, dz), yaw));
                if (dist <= rule#reach and off <= limit) Some((off, dist, s#text)) else None
            })
            |> List.minimumBy((a, b) -> { let (oa, da, _) = a; let (ob, db, _) = b; if (oa == ob) da <=> db else oa <=> ob })
            |> Option.map(e -> { let (_, _, text) = e; text })

    /// 2 つの向きの差（−π..π）。
    def angleBetween(a: Float64, b: Float64): Float64 =
        let d = a - b;
        Num.atan2(Num.sin(d), Num.cos(d))

    // ── 出る・消えるの間 ──

    /// 出ている字幕。shown = 出ている名前・alpha = 濃さ（0..1）・candidate = 決まりが今選んでいる名前・since = candidate が続いている秒。
    pub type alias State = { shown = Option[String], alpha = Float64, candidate = Option[String], since = Float64 }

    pub def empty(): State = { shown = None, alpha = 0.0, candidate = None, since = 0.0 }

    /// dt 秒進める。決まりの選ぶ名前が delay 秒続いたら替える。替える時は今の名前を fade 秒で消してから、新しい名前を fade 秒で出す。
    pub def step(target: Option[String], delay: Float64, fade: Float64, dt: Float64, s: State): State =
        let (candidate, since) = if (target == s#candidate) (target, s#since + dt) else (target, 0.0);
        let wanted = if (since >= delay) candidate else s#shown;
        let rate = dt / Float64.max(0.01, fade);
        if (wanted == s#shown)
            { shown = s#shown, alpha = if (Option.isEmpty(s#shown)) 0.0 else Float64.min(1.0, s#alpha + rate), candidate = candidate, since = since }
        else {
            let alpha = s#alpha - rate;
            if (alpha <= 0.0) { shown = wanted, alpha = 0.0, candidate = candidate, since = since }
            else { shown = s#shown, alpha = alpha, candidate = candidate, since = since }
        }
}
