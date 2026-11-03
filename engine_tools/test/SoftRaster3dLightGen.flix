// SoftRaster3dLightGen — 生成した CPU の光の関数（gen/SoftRaster3dLight.flix）を作り直す口と、入っている物を読む口。
//
//   make gen-light3d（engine とこのファイルだけを束ねた作業場で `flix run --entrypoint SoftRaster3dLightGen.write`）が作り直し、
//   engine_tools の TestSoftRaster3dLight が「入っている物 = LightModel3d.Codegen.generateFlix()」を確かめる。
// WhyNot: engine の LightModel3d と、このファイルのほかの engine_tools の名前を呼ばない — make gen-light3d はそれだけで組む。
// WhyNot: engine_tools の src に置かない — src は fpkg でゲームへ配られる。ファイルを書く開発用の口は test の作業場にだけ置く。
pub mod SoftRaster3dLightGen {
    import java.io.File
    import java.io.FileOutputStream
    import java.nio.file.Files

    /// engine_tools の中のファイル path（engine_tools のフォルダからの相対）。
    // WhyNot: 今いるフォルダからの相対の道で書かない — .layers の作業場は src を 1 ファイルずつ symlink で束ねるので、
    //   新しいファイルは作業場の外の元のフォルダへ置く。flix.toml の symlink の先がその元のフォルダ。
    def packageFile(path: String): File \ IO =
        let packageDir = new File("flix.toml").getCanonicalFile().getParentFile();
        new File(packageDir, path)

    def sourcePath(): String = "src/gen/SoftRaster3dLight.flix"

    def casesPath(): String = "test/gen/SoftRaster3dLightCases.flix"

    /// 生成した関数が呼ぶ SoftRaster3d の名前。
    pub def hooks(): LightModel3d.Codegen.CpuHooks = { shadowType = "SoftRaster3d.SpotShadow", shadowFunction = "SoftRaster3d.shadowFactorAt" }

    /// 入っている gen/SoftRaster3dLight.flix の中身（無ければ None）。行の終わりは \n にそろえる。
    pub def readCurrent(): Option[String] \ IO = readFile(sourcePath())

    /// 入っている test/gen/SoftRaster3dLightCases.flix の中身（無ければ None）。
    pub def readCases(): Option[String] \ IO = readFile(casesPath())

    // WhyNot: 読んだ字をそのまま返さない — Windows の git が行の終わりを \r\n に替えて取り出すと、中身が同じでも比べが落ちる。
    def readFile(path: String): Option[String] \ IO =
        let file = packageFile(path);
        if (file.isFile()) Some(String.replace(src = "\r\n", dst = "\n", Files.readString(file.toPath()))) else None

    /// LightModel3d.Codegen.generateFlix・generateFlixCases を書く（`flix run --entrypoint` の入口）。
    pub def write(): Unit \ IO =
        writeFile(sourcePath(), LightModel3d.Codegen.generateFlix(hooks()));
        writeFile(casesPath(), LightModel3d.Codegen.generateFlixCases(hooks()))

    def writeFile(path: String, text: String): Unit \ IO =
        let file = packageFile(path);
        discard file.getParentFile().mkdirs();
        let out = new FileOutputStream(file);
        out.write(text.getBytes("UTF-8"));
        out.close();
        println("[gen-light3d] ${file.getPath()} を書いた（${String.length(text)} 字）")
}
