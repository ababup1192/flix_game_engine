// Scene3d.Internal.MaterialFlags — ゲームの API に出さない材質の旗を立てる。

/// 材質の内側の旗。ゲームは呼ばない。
pub mod Scene3d.Internal.MaterialFlags {

    /// 半透明でも画面の上の SSAO を受ける材質（デカールの板。下の不透明な面と同じ暗さになる）。
    // WhyNot: ゲームの with… にしない — 奥行きの絵に入らない半透明の物が受けると、その奥の面の暗さを拾って嘘の影になる。
    //   真下に面が貼りついている板だけが、その暗さを自分の物として受けてよい。
    pub def withScreenAoOnBlend(m: Scene3d.Material3d): Scene3d.Material3d =
        let Scene3d.MaterialData.MaterialData(r) = m;
        Scene3d.MaterialData.MaterialData({ screenAoOnBlend = true | r })
}
