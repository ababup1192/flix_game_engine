// 空の場面（R2b・P8 の (5b)）: 殻を外した bench/scene3d の部屋の物を広い床に置き、空（Scene3d.gradientSky）の下で GL と WebGPU で比べる。
// 目を上へ向けて画面の半分ほどを空にする（地平の線・真上の色・床の向こうの真下の色が映る）。
mod V2Sky {

    /// 3 色の違いがはっきりした空（真上は濃い青・地平は淡い橙・真下は暗い緑）。
    def sky(curve: Float64): Scene3d.Sky3d =
        Scene3d.gradientSky(Color.rgb(0.12, 0.28, 0.75), Color.rgb(0.95, 0.78, 0.55), Color.rgb(0.18, 0.3, 0.16)) |> Scene3d.withSkyCurve(curve)

    /// 殻（床・壁・天井）を外した部屋の物を V2Shadows の広い床に置き、空 curve の下で目を yaw・pitch へ向けた場面（太陽と影は無い）。
    pub def yard(kit: Room.Kit, yaw: Float64, pitch: Float64, curve: Float64): Scene3d.Scene3dCmd =
        let room = Room.scene(kit, yaw);
        let props = room#instances |> List.filter(i -> Scene3d.instanceFieldsOf(i)#name != "shell");
        { instances = Scene3d.meshInstance(V2Shadows.floor(), Mat4.identity()) :: props, sky = Some(sky(curve)), camera = { pitch = pitch | room#camera } | room }
}
