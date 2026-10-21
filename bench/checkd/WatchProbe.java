// WatchProbe — JDK の WatchService が、ファイルの書き換えを何秒後に知らせるか（docs/checkd.md の作り直しの段 C-0・測る道具 3）。
//
//   java bench/checkd/WatchProbe.java <見張る木の根（パッケージの src/ など）> [回数=30]
//
// flix repl はソースの書き換えを WatchService の知らせでだけ取り込む（macOS の JDK は見回り = PollingWatchService）。
// この probe は同じ JDK の同じ API（感度の指定なし。flix の FileWatcher と同じく木の下のディレクトリを全部 register）で
// 見張り、木の根に置いた 1 ファイルを自分で書き換えては知らせが届くまでの
// 秒を測る。書き換えの間は 0〜3 秒のばらつきを入れて、見回りの周期とずらす。1 回ごとに「回・遅れの秒・その時の load average」を
// タブ区切りで、最後に最小・中央・最大と 10 秒を超えた回数を出す。
import java.lang.management.ManagementFactory;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

public class WatchProbe {
    public static void main(String[] args) throws Exception {
        Path dir = Paths.get(args[0]).toAbsolutePath();
        int rounds = args.length > 1 ? Integer.parseInt(args[1]) : 30;
        Files.createDirectories(dir);
        Path file = dir.resolve("watch-probe.flix");
        Files.writeString(file, "// probe 0\n");
        WatchService ws = FileSystems.getDefault().newWatchService();
        int[] dirs = {0};
        Files.walkFileTree(dir, new SimpleFileVisitor<Path>() {
            @Override public FileVisitResult preVisitDirectory(Path d, java.nio.file.attribute.BasicFileAttributes a) throws java.io.IOException {
                d.register(ws, StandardWatchEventKinds.ENTRY_CREATE, StandardWatchEventKinds.ENTRY_DELETE, StandardWatchEventKinds.ENTRY_MODIFY);
                dirs[0]++;
                return FileVisitResult.CONTINUE;
            }
        });
        System.out.println("# watch service: " + ws.getClass().getName() + "・見張るディレクトリ " + dirs[0]);
        Thread.sleep(12_000); // 最初の見回りで今の中身を覚えさせる
        drain(ws);
        Random rand = new Random(1);
        List<Double> lags = new ArrayList<>();
        for (int i = 1; i <= rounds; i++) {
            Thread.sleep(rand.nextInt(3000));
            long t0 = System.nanoTime();
            Files.writeString(file, "// probe " + i + "\n");
            double lag = waitFor(ws, file.getFileName(), t0);
            double load = ManagementFactory.getOperatingSystemMXBean().getSystemLoadAverage();
            lags.add(lag);
            System.out.printf("%d\t%.2f\t%.1f%n", i, lag, load);
        }
        Collections.sort(lags);
        long over = lags.stream().filter(x -> x > 10.0).count();
        System.out.printf("# %d 回: 最小 %.2f 秒・中央 %.2f 秒・最大 %.2f 秒・10 秒を超えた %d 回%n",
            rounds, lags.get(0), lags.get(lags.size() / 2), lags.get(lags.size() - 1), over);
        Files.deleteIfExists(file);
    }

    /// その名前のファイルの知らせが届くまで待って、書いた時刻からの秒を返す（60 秒で諦めて -1）。
    static double waitFor(WatchService ws, Path name, long t0) throws Exception {
        long deadline = t0 + TimeUnit.SECONDS.toNanos(60);
        while (System.nanoTime() < deadline) {
            WatchKey key = ws.poll(100, TimeUnit.MILLISECONDS);
            if (key == null) continue;
            boolean hit = false;
            for (WatchEvent<?> e : key.pollEvents()) if (name.equals(e.context())) hit = true;
            key.reset();
            if (hit) return (System.nanoTime() - t0) / 1e9;
        }
        return -1.0;
    }

    static void drain(WatchService ws) {
        WatchKey key;
        while ((key = ws.poll()) != null) { key.pollEvents(); key.reset(); }
    }
}
