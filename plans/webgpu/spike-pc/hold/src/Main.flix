mod WgpuHold {
    import spike.wgpu.Wg
    import spike.wgpu.WgDevice
    import spike.wgpu.WgBuffer
    import spike.wgpu.WgPipeline
    import spike.wgpu.WgTexture
    import java.lang.Long

    /// backend の物を運ぶ record。pipeline は名前で引く。
    type alias Gpu = {
        device = WgDevice,
        target = WgTexture,
        rows = WgBuffer,
        pipelines = Map[String, WgPipeline]
    }

    pub def openGpu(nativeDir: String): Gpu \ IO =
        let device = Wg.open(nativeDir);
        let pipelines = Map.empty()
            |> Map.insert("orange", Wg.createTrianglePipeline(device, "orange", 1.0, 0.5, 0.25))
            |> Map.insert("teal", Wg.createTrianglePipeline(device, "teal", 0.0, 0.5, 0.5));
        { device = device, target = Wg.createTarget(device, 64, 64), rows = Wg.createBuffer(device, 65536i64), pipelines = pipelines }

    /// 名前の pipeline で描き、三角形の中 (32, 40) の画素を 0xRRGGBBAA で返す。
    pub def drawNamed(gpu: Gpu, name: String): Option[Int64] \ IO =
        Map.get(name, gpu#pipelines) |> Option.map(p -> Wg.drawAndReadPixel(gpu#device, gpu#target, p, 32, 40))

    def hex(v: Int64): String = Long.toHexString(v)

    def report(gpu: Gpu, name: String, expected: Int64): Bool \ IO =
        let got = drawNamed(gpu, name);
        let ok = got == Some(expected);
        let shown = got |> Option.map(hex) |> Option.getWithDefault("none");
        println("RESULT flix ${name} pixel=${shown} expected=${hex(expected)} ${if (ok) "OK" else "NG"}");
        ok

    pub def main(): Unit \ IO =
        let gpu = openGpu("native");
        println("device: ${gpu#device.describe()} rows=${Int64.toString(gpu#rows.size())}B pipelines=${Map.keysOf(gpu#pipelines) |> Set.toList |> List.join(",")}");
        // record を with で写した後も、同じ device の物として使える事を見る。
        let moved = { pipelines = Map.remove("teal", gpu#pipelines) | gpu };
        let okA = report(gpu, "orange", 0xff8040ffi64);
        let okB = report(gpu, "teal", 0x008080ffi64);
        let okC = drawNamed(moved, "teal") == None;
        let okD = report(moved, "orange", 0xff8040ffi64);
        println("RESULT flix moved-record teal-removed=${okC} errors=${Int32.toString(Wg.errorCount())}");
        println("RESULT flix all=${okA and okB and okC and okD and Wg.errorCount() == 0}")
}

def main(): Unit \ IO = WgpuHold.main()
