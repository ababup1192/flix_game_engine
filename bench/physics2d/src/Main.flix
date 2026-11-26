// PC の入口: 窓を開かずに PhysicsBench の場面を流し、場面ごとに 1 行の JSON を出す（3 回流して 2〜3 回目が温まった後の値）。
def main(): Unit \ IO =
    PhysicsBench.runAll({ now = () -> Int64.toFloat64(PhysicsBenchClock.nanoTime()) / 1.0e6, emit = line -> println(line) }, 3)

mod PhysicsBenchClock {
    import java.lang.System

    pub def nanoTime(): Int64 \ IO = System.nanoTime()
}
