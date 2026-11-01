// Still — 部屋を CPU（SoftRaster）で 1 枚描いて debug/room.png に書く（窓を開かない）。
// 実機と同じ描き物の列を Render.softSceneOf で分け、HeadlessRender.renderPngSoft に渡す。
mod Still {
    use fge::{HeadlessFont, HeadlessRender, Render}

    import java.lang.System

    // WhyNot: 字を描かない場面でも字の表を空にしない — SoftRaster は塗る前に必ずフォントの表を組む。
    def ttf(): String = "assets/Xolonium-Regular.ttf"

    /// 書き出す倍率（design 320×180 → 960×540）。
    def scale(): Int32 = 3

    pub def write(): Unit \ IO =
        match (run { Room.loadMeshes() } with Fs.FileRead.runWithIO) {
            case Err(why) =>
                println("[scene3d] 家具を読めない: ${why}");
                System.exit(1)
            case Ok(meshes) =>
                let kit = Room.kitOf(meshes);
                let atlas = HeadlessFont.buildUiAtlas(ttf(), ttf());
                let cfg = { design = Room.design(), scale = scale(), outDir = "debug", fontTtf = ttf(), fontAtlas = atlas,
                            frameW = 320 * scale(), frameH = 180 * scale() | HeadlessRender.defaults() };
                let started = System.nanoTime();
                HeadlessRender.renderPngSoft(cfg, Render.softSceneOf(_ -> None, Room.items(kit, 0.0)), "room");
                let ms = Int64.toFloat64(System.nanoTime() - started) / 1000000.0;
                println("[scene3d] debug/room.png（${Int32.toString(Float64.round(ms) |> Float64.tryToInt32 |> Option.getWithDefault(0))} ms）")
        }
}
