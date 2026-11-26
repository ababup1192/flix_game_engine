// ブラウザ版の入口（bin/fge export-web だけが組む・make bench-web BENCH=physics2d）。PC と同じ場面を流し、結果を console へ "[bench] result {…}" で出す
// （bench/common/bench-overlay.js が拾って window.__bench に置き、bin/fge web-bench が取る）。コマは回さない。
// 2 回流して、2 回目が温まった後の値。指紋は PC と同じになるはず（JVM と wasm の決定性）。
mod WebMain {
    import fge.web.Browser

    pub def main(): Unit \ IO =
        PhysicsBench.runAll({ now = () -> Browser.now(), emit = line -> Browser.log(line) }, 2)
}
