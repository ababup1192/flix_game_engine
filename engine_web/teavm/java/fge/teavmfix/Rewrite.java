package fge.teavmfix;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.Map;
import java.util.TreeMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;
import org.teavm.asm.ClassReader;
import org.teavm.asm.ClassVisitor;
import org.teavm.asm.ClassWriter;
import org.teavm.asm.MethodVisitor;
import org.teavm.asm.Opcodes;

/**
 * TeaVM 0.14.1 に無い・壊れている JDK の呼び出しを、jar のバイトコードの中で付け替える（書き出しの道具の②）。
 * 使い方: java -cp teavm-relocated-libs-asm.jar:fge-web-tools.jar fge.teavmfix.Rewrite 入る.jar 出る.jar
 * 付け替える物:
 *   Thread.startVirtualThread         → VirtualThreads.startVirtualThread（TeaVM の Thread は緑スレッド）
 *   Arrays.copyOfRange                → CopyOfRange.copyOfRange（to が長さを超えると配列の外を読んで落ちる）
 *   Checksum.update(byte[])           → Checksums.update（interface の default の関数が TeaVM の classlib に無い）
 *   Reference.refersTo                → References.refersTo（Java 16 の関数が無い）
 *   正規表現の字 "\R"                  → "\r\n|[\n\r]"（TeaVM の正規表現に無い。Flix 標準の String.lines が使う）
 * TeaVM 自身が持つ org/teavm/ の類は jar から落とす（Flix の依存の解決で同じ物が入り、TeaVM の物と二重になる）。
 * 付け替えた数を種類ごとに標準出力へ 1 行ずつ出す。
 */
public final class Rewrite {
    private Rewrite() { }

    private static final String FIX = "fge/teavmfix/";

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("usage: Rewrite <in.jar> <out.jar>");
            System.exit(2);
        }
        Map<String, Integer> counts = new TreeMap<>();
        try (ZipInputStream in = new ZipInputStream(new FileInputStream(args[0]));
             ZipOutputStream out = new ZipOutputStream(new FileOutputStream(args[1]))) {
            ZipEntry entry;
            while ((entry = in.getNextEntry()) != null) {
                String name = entry.getName();
                if (name.startsWith("org/teavm/")) continue;
                byte[] bytes = in.readAllBytes();
                if (name.endsWith(".class")) bytes = rewriteClass(bytes, counts);
                out.putNextEntry(new ZipEntry(name));
                out.write(bytes);
            }
        }
        counts.forEach((kind, n) -> System.out.println("rewrite " + kind + " " + n));
    }

    private static byte[] rewriteClass(byte[] bytes, Map<String, Integer> counts) {
        ClassReader reader = new ClassReader(bytes);
        ClassWriter writer = new ClassWriter(0);
        reader.accept(new ClassVisitor(Opcodes.ASM9, writer) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String desc, String sig, String[] exceptions) {
                return new FixCalls(super.visitMethod(access, name, desc, sig, exceptions), counts);
            }
        }, 0);
        return writer.toByteArray();
    }

    private static final class FixCalls extends MethodVisitor {
        private final Map<String, Integer> counts;

        FixCalls(MethodVisitor inner, Map<String, Integer> counts) {
            super(Opcodes.ASM9, inner);
            this.counts = counts;
        }

        private void note(String kind) { counts.merge(kind, 1, Integer::sum); }

        @Override
        public void visitLdcInsn(Object value) {
            if ("\\R".equals(value)) {
                note("regex-R");
                super.visitLdcInsn("\r\n|[\n\r]");
            } else {
                super.visitLdcInsn(value);
            }
        }

        @Override
        public void visitMethodInsn(int op, String owner, String name, String desc, boolean itf) {
            if (owner.equals("java/lang/Thread") && name.equals("startVirtualThread")) {
                note("startVirtualThread");
                super.visitMethodInsn(Opcodes.INVOKESTATIC, FIX + "VirtualThreads", name, desc, false);
            } else if (owner.equals("java/util/Arrays") && name.equals("copyOfRange") && desc.contains("II)")) {
                note("copyOfRange");
                super.visitMethodInsn(Opcodes.INVOKESTATIC, FIX + "CopyOfRange", name, desc, false);
            } else if (owner.equals("java/util/zip/Checksum") && name.equals("update") && desc.equals("([B)V")) {
                note("Checksum.update");
                super.visitMethodInsn(Opcodes.INVOKESTATIC, FIX + "Checksums", "update", "(Ljava/util/zip/Checksum;[B)V", false);
            } else if (name.equals("refersTo") && desc.equals("(Ljava/lang/Object;)Z") && owner.startsWith("java/lang/ref/")) {
                note("refersTo");
                super.visitMethodInsn(Opcodes.INVOKESTATIC, FIX + "References", "refersTo", "(Ljava/lang/ref/Reference;Ljava/lang/Object;)Z", false);
            } else {
                super.visitMethodInsn(op, owner, name, desc, itf);
            }
        }
    }
}
