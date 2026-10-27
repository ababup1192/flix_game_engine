// 生成物 — 手で直さない。bin/fge video-entries が Makefile の $(call video,入口,…) の行と
// Z_VIDEOS_EXTRA / Z_VIDEOS_SKIP から書く（動画の見回りが流す前に書き直す）。
mod VideoAuditEntries {

    /// 見回りで流す動画の入口を、Makefile に並んだ順に全部流す。
    pub def runAll(): Unit \ IO =
        VideoRender.frames()
}
