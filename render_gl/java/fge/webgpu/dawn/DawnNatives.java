package fge.webgpu.dawn;

import com.github.xpenatan.jParser.loader.JParserLibraryLoader;
import com.github.xpenatan.webgpu.JWebGPUBackend;
import com.github.xpenatan.webgpu.JWebGPULoader;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Set;

/**
 * jWebGPU のネイティブ（jParser の runtime と Dawn）を、版と backend ごとの置き場へ書き出して読む。プロセスで 1 回。
 * WhyNot: jParser に書き出させない — jParser は ${java.io.tmpdir}/jParser${user.name} に同じ名前でその場で上書きし、
 * 版や backend の違う物を開いている別のプロセスを macOS が署名の不一致で落とす。
 * WhyNot: java.io.tmpdir を読み込みの間だけ差し替えない — プロセス全体の設定なので、同じ間に一時ファイルを作る別の糸の置き場まで動く。
 */
final class DawnNatives {
    private DawnNatives() {}

    /** jar の中の場所と、jParser の読み込み済みの表に入る名前の組。 */
    private record Library(String resource, String fileName, String loadedKey) {}

    private static String loadedDir;

    /**
     * dir に書き出して読み、jWebGPU の読み込みを済ませる。dir が空なら、読み済みならそれを・まだなら defaultDir を使う。
     * 2 回目は同じ dir なら何もしない。別の dir を名指しされたら IllegalStateException（ネイティブはプロセスで 1 回しか読めず、渡された置き場は使われない）。
     */
    static synchronized void load(String dir, String defaultDir) {
        if (dir.isEmpty() && loadedDir != null) return;
        String canonical = new File(dir.isEmpty() ? defaultDir : dir).getAbsoluteFile().toPath().normalize().toString();
        if (loadedDir != null) {
            if (!loadedDir.equals(canonical))
                throw new IllegalStateException("jWebGPU のネイティブは " + loadedDir + " から読み済みで、" + canonical + " は使えない");
            return;
        }
        Library[] libs = librariesForThisMachine();
        try {
            Files.createDirectories(Path.of(canonical));
            for (Library lib : libs) System.load(install(lib, Path.of(canonical)).toString());
        } catch (IOException e) {
            throw new IllegalStateException("jWebGPU のネイティブを " + canonical + " へ書き出せない", e);
        }
        markLoaded(libs);
        boolean[] ok = {false};
        Throwable[] why = {null};
        JWebGPULoader.init(JWebGPUBackend.DAWN, (success, e) -> { ok[0] = success; why[0] = e; });
        if (!ok[0]) throw new IllegalStateException("jWebGPU の初期化に失敗", why[0]);
        loadedDir = canonical;
    }

    // WhyNot: macOS arm64 のほかを推して名前を作らない — 配っているネイティブの jar がまだ macOS arm64 だけで、確かめていない名前は読めても別の物かもしれない。
    private static Library[] librariesForThisMachine() {
        String os = System.getProperty("os.name", "");
        String arch = System.getProperty("os.arch", "");
        if (os.startsWith("Mac") && (arch.equals("aarch64") || arch.equals("arm64")))
            return new Library[]{
                new Library("libruntimearm64.dylib", "libruntimearm64.dylib", "runtime"),
                new Library("native/dawn/libjWebGPUarm64.dylib", "libjWebGPUarm64.dylib", "native/dawn/jWebGPU")};
        throw new IllegalStateException("この機種（" + os + " " + arch + "）の WebGPU のネイティブはまだ配っていない");
    }

    /**
     * jar の中の物を置き場へ入れ、置き場の path を返す。中身が同じ物が既にあれば書かない。
     * WhyNot: 置き場の名前のまま書き込まない — 書いている途中の物を別のプロセスが読みに来る。一時の名前で書き終えてから名前を入れ替える
     * （入れ替えは開いている側の中身を変えない）。
     */
    private static Path install(Library lib, Path dir) throws IOException {
        byte[] bytes;
        try (InputStream in = DawnNatives.class.getClassLoader().getResourceAsStream(lib.resource())) {
            if (in == null) throw new IOException(lib.resource() + " が classpath に無い（webgpu-desktop-jni-dawn と runtime-desktop-jni の jar）");
            bytes = in.readAllBytes();
        }
        Path target = dir.resolve(lib.fileName());
        if (Files.isRegularFile(target) && Arrays.equals(digest(Files.readAllBytes(target)), digest(bytes))) return target;
        Path temp = Files.createTempFile(dir, lib.fileName(), ".part");
        try {
            Files.write(temp, bytes);
            Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(temp);
        }
        return target;
    }

    private static byte[] digest(byte[] bytes) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(bytes);
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * jParser の読み込み済みの表に名前を入れ、JWebGPULoader.init が書き出しも読み直しもしないようにする。
     * WhyNot: 表に入れずに init を呼ばない — init は表に無い物を自分の置き場へ書き出して読み、上の手当てが無駄になる。
     */
    @SuppressWarnings("unchecked")
    private static void markLoaded(Library[] libs) {
        try {
            Field f = JParserLibraryLoader.class.getDeclaredField("loadedLibraries");
            f.setAccessible(true);
            Set<String> loaded = (Set<String>) f.get(null);
            for (Library lib : libs) loaded.add(lib.loadedKey());
        } catch (ReflectiveOperationException | RuntimeException e) {
            throw new IllegalStateException("jParser の読み込み済みの表に届かない（jParser の版が変わった）", e);
        }
    }
}
