// Markers — 画面の位置に名前を付けて引く（「盾アイコン」「スタンバイの枠 2」）。
// 描画と演出が同じ名前から同じ矩形を読むので、光る枠がカードからずれる・飛んだ物が
// アイコンの横に着く、のような「2 か所に座標を書いた」食い違いが起きない。
// Godot の Marker2D（名前の付いた位置）と同じ考え方で、矩形を持つ（中心・角・縁は pivot で引く）。
// Flex.rectsOf（keyed したノードの矩形）が返す Map もそのまま Markers として使える。
// 利用例: レイアウトを 1 か所で組んで Markers を作り、View とエフェクトが rectOf / pointOf で引く。
// Doc の演出が「飛んで着く先」を名前で書く（"to": "hud/shield"）ときの受け口にもなる。

pub mod Markers {

    /// 名前 → 矩形（左上と大きさ）。
    pub type alias Markers = Map[String, Rect2.Rect2]

    pub def empty(): Markers = Map.empty()

    /// 名前を付けて矩形を足す（同じ名前は上書き）。
    pub def withRect(name: String, rect: Rect2.Rect2, m: Markers): Markers = Map.insert(name, rect, m)

    /// (名前, 矩形) の列から作る。
    pub def fromList(entries: List[(String, Rect2.Rect2)]): Markers = List.toMap(entries)

    /// 列の i 番目の名前（"standby/2" の形）。並んだ枠に同じ書き方で名前を付けるための口。
    pub def indexed(prefix: String, i: Int32): String = "${prefix}/${Int32.toString(i)}"

    /// 名前の矩形（無ければ None）。
    pub def rectOf(name: String, m: Markers): Option[Rect2.Rect2] = Map.get(name, m)

    /// 名前の矩形の中の点。pivot = (0,0) 左上・(0.5,0.5) 中心・(1,1) 右下。
    pub def pointOf(name: String, pivot: Vec2.Vec2, m: Markers): Option[Vec2.Vec2] =
        rectOf(name, m) |> Option.map(r ->
            { x = r#position#x + r#size#x * pivot#x, y = r#position#y + r#size#y * pivot#y })

    /// 名前の矩形の中心。
    pub def centerOf(name: String, m: Markers): Option[Vec2.Vec2] = rectOf(name, m) |> Option.map(Rect2.center)
}
