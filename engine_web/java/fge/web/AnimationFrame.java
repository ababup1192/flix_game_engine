package fge.web;

import java.util.Arrays;
import org.teavm.interop.Async;
import org.teavm.interop.AsyncCallback;
import org.teavm.jso.JSBody;
import org.teavm.jso.browser.Window;

/**
 * ブラウザの描き替え（requestAnimationFrame）に合わせてゲームのループを止めて待つ API。
 * ループは止まる形のまま回り、ここで待つ間だけ wasm がブラウザへ手を返す（TeaVM のコルーチン変換）。
 * 1 コマで wasm が使った時間（待ちから戻ってから次に待つまで）と、描き替えから戻るまでの遅れを fge-web.js の fgeStats へ渡す。
 */
public final class AnimationFrame {
    private AnimationFrame() { }

    private static double lastTick = 0;
    private static double nextTick = 0;
    private static double resumedAt = 0;
    private static double lastRaf = 0;
    private static final double[] gaps = new double[16];
    private static int gapCount = 0;

    /** 次の描き替えまで止まる。戻り値は描き替えの時刻（ms）。 */
    @Async
    public static native double waitFrame();

    private static void waitFrame(AsyncCallback<Double> callback) {
        Window.requestAnimationFrame(time -> callback.complete(time));
    }

    /**
     * ゲームの 1 コマを進めてよい描き替えまで待つ。hz = 1 秒に進めるコマの上限（0 以下なら描き替えごと）。
     * 速い画面（120Hz・165Hz）では描き替えを飛ばして hz に近づける。飛ばした描き替えでは何も描かないので、前のコマの絵が残る。
     * 戻り値は前に進めたコマからの経過（秒）。初めの 1 回は 1 コマ分（dt で割るゲームが 0 で割らないように）。
     */
    public static double waitTick(double hz) {
        if (resumedAt > 0) noteCpu(Browser.now() - resumedAt);
        double interval = hz > 0 ? 1000.0 / hz : 0;
        double time = nextFrame();
        double gap = rafGap();
        // WhyNot: 前のコマから interval が経つまでで比べない — 165Hz で 3 回目（18ms）まで待つと 55 コマになる。
        //   予定の時刻に、描き替えの間隔の半分の手前から乗る形にして、平均で hz にそろえる。
        // WhyNot: 60Hz に近い画面で間引かない — 59.9Hz などで時々 1 回飛ばすとカクつく。
        boolean thinOut = interval > 0 && gap < interval * 0.9;
        if (thinOut && nextTick > 0) {
            while (time < nextTick - gap / 2) time = nextFrame();
        }
        if (thinOut) {
            nextTick = (nextTick <= 0 || time - nextTick > interval * 4) ? time + interval : nextTick + interval;
        }
        double elapsed = lastTick > 0 ? (time - lastTick) / 1000.0 : (interval > 0 ? interval : 1000.0 / 60) / 1000.0;
        lastTick = time;
        resumedAt = Browser.now();
        noteLag(resumedAt - time);
        return elapsed;
    }

    /** 描き替えの間隔（ms）の見積もり。直近の間隔の下から 4 分の 1 の値（ゲームが重くて 1 回飛んだ間隔に引きずられない）。 */
    private static double rafGap() {
        if (gapCount == 0) return 1000.0 / 60;
        int n = Math.min(gapCount, gaps.length);
        double[] sorted = Arrays.copyOf(gaps, n);
        Arrays.sort(sorted);
        return sorted[n / 4];
    }

    private static double nextFrame() {
        double time = waitFrame();
        double gap = time - lastRaf;
        if (lastRaf > 0 && gap > 2 && gap < 40) {
            gaps[gapCount % gaps.length] = gap;
            gapCount++;
        }
        lastRaf = time;
        return time;
    }

    @JSBody(params = {"ms"}, script = "if (window.fgeStats) fgeStats.cpu(ms);")
    private static native void noteCpu(double ms);

    @JSBody(params = {"ms"}, script = "if (window.fgeStats) fgeStats.lag(ms);")
    private static native void noteLag(double ms);
}
