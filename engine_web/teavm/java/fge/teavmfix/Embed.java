package fge.teavmfix;

import fge.web.EmbeddedCodec;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;
import org.teavm.asm.ClassWriter;
import org.teavm.asm.MethodTooLargeException;
import org.teavm.asm.MethodVisitor;
import org.teavm.asm.Opcodes;

/**
 * project.json の web.embed の素材を符号にして fge.web.EmbeddedData を作り、jar の中の空の版と差し替える。
 * 引数: 入る.jar 出る.jar 鍵 (道 ファイル)...。標準出力の `embed <道> <元のバイト数> <符号のバイト数>` を書き出しの道具が読む。
 */
public final class Embed {
    private Embed() { }

    private static final String TARGET = "fge/web/EmbeddedData.class";

    public static void main(String[] args) throws Exception {
        if (args.length < 5 || (args.length - 3) % 2 != 0) {
            System.err.println("usage: Embed <in.jar> <out.jar> <seed> (<path> <file>)...");
            System.exit(2);
        }
        long seed = Long.parseLong(args[2]);
        List<String> table = new ArrayList<>();
        List<String> report = new ArrayList<>();
        for (int i = 3; i + 1 < args.length; i += 2) {
            String path = args[i];
            byte[] plain = Files.readAllBytes(Path.of(args[i + 1]));
            int index = (i - 3) / 2;
            String[] chunks = EmbeddedCodec.encode(plain, seed, index);
            byte[] back = EmbeddedCodec.decode(chunks, 0, chunks.length, seed, index);
            // WhyNot: 戻せるかを確かめずに書かない — 壊れた符号はブラウザで初めて「シナリオが無い」になる。
            if (back == null || !Arrays.equals(back, plain)) {
                System.err.println("Embed: " + path + " を符号にした物が元に戻らない");
                System.exit(1);
            }
            table.add(path);
            table.add(Integer.toString(chunks.length));
            int size = 0;
            for (String c : chunks) {
                table.add(c);
                size += c.length();
            }
            report.add("embed " + path + " " + plain.length + " " + size);
        }
        byte[] cls;
        try {
            cls = buildClass(seed, table.toArray(new String[0]));
        } catch (MethodTooLargeException e) {
            System.err.println("Embed: 埋め込む素材が多すぎて class の関数に収まらない（表の " + table.size() + " 個）。web.embed の glob を狭める");
            System.exit(1);
            return;
        }
        boolean replaced = false;
        try (ZipInputStream in = new ZipInputStream(new FileInputStream(args[0]));
             ZipOutputStream out = new ZipOutputStream(new FileOutputStream(args[1]))) {
            ZipEntry entry;
            while ((entry = in.getNextEntry()) != null) {
                byte[] bytes = in.readAllBytes();
                if (entry.getName().equals(TARGET)) {
                    bytes = cls;
                    replaced = true;
                }
                out.putNextEntry(new ZipEntry(entry.getName()));
                out.write(bytes);
            }
        }
        if (!replaced) {
            System.err.println("Embed: " + args[0] + " に " + TARGET + " が無い（engine_full_web の fge-web.jar が古い）");
            System.exit(1);
        }
        report.forEach(System.out::println);
    }

    // WhyNot: javac で .java から組まない — 配った版の書き出しは JRE だけで動き、javac が無いことがある。
    private static byte[] buildClass(long seed, String[] table) {
        ClassWriter w = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        w.visit(Opcodes.V17, Opcodes.ACC_PUBLIC | Opcodes.ACC_FINAL | Opcodes.ACC_SUPER, "fge/web/EmbeddedData", null, "java/lang/Object", null);

        MethodVisitor s = w.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "seed", "()J", null, null);
        s.visitCode();
        s.visitLdcInsn(seed);
        s.visitInsn(Opcodes.LRETURN);
        s.visitMaxs(0, 0);
        s.visitEnd();

        MethodVisitor t = w.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "table", "()[Ljava/lang/String;", null, null);
        t.visitCode();
        t.visitLdcInsn(table.length);
        t.visitTypeInsn(Opcodes.ANEWARRAY, "java/lang/String");
        for (int i = 0; i < table.length; i++) {
            t.visitInsn(Opcodes.DUP);
            t.visitLdcInsn(i);
            t.visitLdcInsn(table[i]);
            t.visitInsn(Opcodes.AASTORE);
        }
        t.visitInsn(Opcodes.ARETURN);
        t.visitMaxs(0, 0);
        t.visitEnd();

        w.visitEnd();
        return w.toByteArray();
    }
}
