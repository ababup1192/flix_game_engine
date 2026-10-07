// AllocMeter — 今のスレッドが割り当てたバイト数を測る。
//
// 時間ではなくバイト数を見るので、熱・JIT・GC・マシンの速さで動かない決定的な数字が取れる。
// List.append を畳み込みの中で呼ぶような、割り当てが O(N^2) に膨らむ形の検出に使う。
//
// 呼ぶのはテストからだけ。engine_world のテストからも同じ形で測れるように pub にしてあり、
// ゲームやエンジン本体の実行経路からは呼ばない。

pub mod AllocMeter {
    import java.lang.management.ManagementFactory
    import java.lang.management.{ThreadMXBean => JavaThreadMXBean}
    import com.sun.management.{ThreadMXBean => SunThreadMXBean}
    import java.lang.Thread

    /// この JVM でスレッドの割り当てバイト数を読めるか。false なら測っても 0 しか返らない。
    pub def isThreadAllocatedMemoryEnabled(): Bool =
        unchecked_cast(isEnabledIO() as _ \ {})

    /// `body` を 1 回動かす間に今のスレッドが割り当てたバイト数。
    /// `warmups` 回の暖機と、計測そのものが使うぶんの差し引きを含む。
    pub def measureBytes(warmups: Int32, body: Unit -> a): Int64 =
        unchecked_cast(measureBytesIO(warmups, body) as _ \ {})

    def getBean(): SunThreadMXBean \ IO =
        // 名前で引かず getThreadMXBean() の戻りを落とす。JDK が返す実体は同じ 1 つで、
        // 別経路で取り直すと有効/無効の設定が食い違う。
        unchecked_cast(ManagementFactory.getThreadMXBean() as SunThreadMXBean)

    def isEnabledIO(): Bool \ IO =
        let bean = getBean();
        bean.isThreadAllocatedMemorySupported() and bean.isThreadAllocatedMemoryEnabled()

    def getAllocatedBytes(bean: SunThreadMXBean): Int64 \ IO =
        bean.getThreadAllocatedBytes(Thread.currentThread().threadId())

    def measureBytesIO(warmups: Int32, body: Unit -> a): Int64 \ IO =
        region rc {
            let bean = getBean();
            let sink = Ref.fresh(rc, (None: Option[a]));
            // 戻り値を Ref へ置く。捨てると JIT が body ごと消せてしまう。
            List.forEach(_ -> Ref.put(Some(body()), sink), List.range(0, warmups));
            let baseA = getAllocatedBytes(bean);
            let baseB = getAllocatedBytes(bean);
            let overhead = baseB - baseA;
            let before = getAllocatedBytes(bean);
            Ref.put(Some(body()), sink);
            let after = getAllocatedBytes(bean);
            let _ = Ref.get(sink);
            Int64.max(0i64, (after - before) - overhead)
        }

}
