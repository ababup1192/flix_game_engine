// BenchAllocActiveDocs — ActiveDocs の毎フレームの変更検知 1 回ぶんの確保バイトを測る使い捨ての入口。
// 旧経路(毎フレーム JSON を組んで文字列比較)と新経路(指紋だけ組んで比較)を並べて出す。
// json は書き込みが要る瞬間しか呼ばれなくなったので、json の行が「前」・fingerprint の行が「後」。
// 実行: ../../bin/flix run --entrypoint BenchAllocActiveDocs.main
mod BenchAllocActiveDocs {

    use fge::{ActiveDocs, AllocMeter}

    pub def main(): Unit \ IO =
        let entries = testEntries();
        let jsonBytes = AllocMeter.measureBytes(5, () -> ActiveDocs.json(entries));
        let keyBytes = AllocMeter.measureBytes(5, () -> ActiveDocs.fingerprint(entries));
        println("entries=${List.length(entries)} JSON組み立て(前)=${jsonBytes}B 指紋(後)=${keyBytes}B")

    /// テンプレのゲームが名乗る規模(Doc 8 種・UI は複数パス)。
    def testEntries(): List[(String, List[String])] =
        ("theme", "assets/x.theme.json" :: Nil)
            :: ("sprite", "assets/chars.sprite.json" :: "assets/tiles.sprite.json" :: Nil)
            :: ("ui", "assets/ui/title.ui.json" :: "assets/ui/hud.ui.json" :: Nil)
            :: ("fx", "assets/burst.fx.json" :: Nil)
            :: ("shader", "assets/sky.shader.json" :: Nil)
            :: ("hit", "assets/stage.hit.json" :: Nil)
            :: ("sfx", "assets/se.sfx.json" :: Nil)
            :: ("kind", "assets/enemies.kind.json" :: Nil)
            :: Nil
}
