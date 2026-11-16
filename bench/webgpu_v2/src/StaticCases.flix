// 動かない物の集まりの場面（P9）: 既にある場面の置いた物を Scene3d.staticGroup の集まり 1 つへ移し、GL（集まりの物を instances の後ろに並べて描く）と
// WebGPU（持ち越した行で描く）を比べる。集まりの中の半透明の物と骨つきの物は、WebGPU でも毎コマ計画へ通る。
mod V2Static {

    /// scene の置いた物を名前 name の集まり 1 つへ移した場面（keep が真の物は instances に残す）。
    pub def grouped(name: String, keep: Scene3d.Instance3d -> Bool, scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        let (kept, moved) = List.partition(keep, scene#instances);
        { instances = kept, groups = Scene3d.staticGroup(name, moved |> List.mapWithIndex((i, x) -> (Int32.toString(i), x))) :: Nil | scene }

    /// 全部を集まりへ移す。
    pub def all(name: String, scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd = grouped(name, _ -> false, scene)

    /// 名前が "shell"（床・壁・天井）の物だけ instances に残し、残りを集まりへ移す（場面の行と持ち越した行が 1 つの pass に混ざる）。
    pub def propsOnly(name: String, scene: Scene3d.Scene3dCmd): Scene3d.Scene3dCmd =
        grouped(name, i -> Scene3d.instanceFieldsOf(i)#name == "shell", scene)
}
