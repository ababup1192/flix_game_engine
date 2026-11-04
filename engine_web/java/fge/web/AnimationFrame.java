package fge.web;

import org.teavm.interop.Async;
import org.teavm.interop.AsyncCallback;
import org.teavm.jso.JSBody;
import org.teavm.jso.browser.Window;

/**
 * ブラウザの描き替え（requestAnimationFrame）に合わせてゲームのループを止めて待つ口。
 * ループは止まる形のまま回り、ここで待つ間だけ wasm がブラウザへ手を返す（TeaVM のコルーチン変換）。
 * 1 コマで wasm が使った時間（待ちから戻ってから次に待つまで）を数え、fge-web.js の fgeStats へ渡す。
 */
public final class AnimationFrame {
    private AnimationFrame() { }

    /** 前に進めたコマの時刻（ms）。0 はまだ 1 度も待っていない。 */
    private static double lastTick = 0;
    /** 次に進めるべき時刻（ms）。間引きの基準。 */
    private static double nextTick = 0;
    /** 待ちから戻った時刻（ms）。1 コマの CPU の起点。 */
    private static double resumedAt = 0;

    /** 次の描き替えまで止まる。戻り値は描き替えの時刻（ms）。 */
    @Async
    public static native double waitFrame();

    private static void waitFrame(AsyncCallback<Double> callback) {
        Window.requestAnimationFrame(time -> callback.complete(time));
    }

    /**
     * ゲームの 1 コマを進めてよい描き替えまで待つ。hz = 1 秒に進めるコマの上限（0 以下なら描き替えごと）。
     * 速い画面（120Hz・165Hz）では描き替えを飛ばして hz に近づける。飛ばした描き替えでは何も描かないので、前のコマの絵が残る。
     * 戻り値は前に進めたコマからの経過（秒）。
     */
    public static double waitTick(double hz) {
        double cpuFrom = resumedAt;
        double before = Browser.now();
        if (cpuFrom > 0) noteCpu(before - cpuFrom);
        double interval = hz > 0 ? 1000.0 / hz : 0;
        double time = nextFrame();
        // WhyNot: 前のコマから interval が経つまでで比べない — 165Hz で 3 回目（18ms）まで待つと 55 コマになる。
        //   予定の時刻に、描き替えの間隔の半分の手前から乗る形にして、平均で hz にそろえる。
        if (interval > 0 && nextTick > 0) {
            while (time < nextTick - rafGap / 2) time = nextFrame();
        }
        if (interval > 0) {
            nextTick = (nextTick <= 0 || time - nextTick > interval * 4) ? time + interval : nextTick + interval;
        }
        double elapsed = lastTick > 0 ? (time - lastTick) / 1000.0 : 0;
        lastTick = time;
        resumedAt = Browser.now();
        return elapsed;
    }

    /** 描き替えの間隔（ms）の見積もり。続けて来た描き替えの間だけで直す（初めは 60Hz と見る）。 */
    private static double rafGap = 16.7;
    /** 前の描き替えの時刻（ms）。 */
    private static double lastRaf = 0;

    /** 次の描き替えまで待ち、間隔の見積もりを直す。 */
    private static double nextFrame() {
        double time = waitFrame();
        double gap = time - lastRaf;
        if (lastRaf > 0 && gap > 2 && gap < rafGap * 1.5) rafGap = rafGap * 0.9 + gap * 0.1;
        else if (lastRaf > 0 && gap > 2 && gap < 40 && gap < rafGap) rafGap = gap;
        lastRaf = time;
        return time;
    }

    @JSBody(params = {"ms"}, script = "if (window.fgeStats) fgeStats.cpu(ms);")
    private static native void noteCpu(double ms);
}
