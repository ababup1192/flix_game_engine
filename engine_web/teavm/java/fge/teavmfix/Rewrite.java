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
 * TeaVM 0.16.0 に無い・壊れている JDK の呼び出しを、jar のバイトコードの中で付け替える（書き出しの道具の②）。
 * 使い方: java -cp teavm-relocated-libs-asm.jar:fge-web-tools.jar fge.teavmfix.Rewrite 入る.jar 出る.jar
 * 付け替える物:
 *   Thread.startVirtualThread         → VirtualThreads.startVirtualThread（TeaVM の Thread は緑スレッド）
 *   Checksum.update(byte[])           → Checksums.update（interface の default の関数が TeaVM の classlib に無い）
 *   Reference.refersTo                → References.refersTo（Java 16 の関数が無い）
 *   Float.float16ToFloat・floatToFloat16 → HalfFloats の同じ名前（Java 20 の関数が無い。.hdr の half の bit）
 *   ByteBuffer.allocateDirect         → DirectBuffers.allocateDirect（64 KiB の倍数の大きさで memory に余裕があっても落ちる）
 *   正規表現の字 "\R"                  → "\r\n|[\n\r]"（TeaVM の正規表現に無い。Flix 標準の String.lines が使う）
 *   instanceof dev/flix/runtime/Thunk$ → FlixThunks.isThunk（Flix の関数の呼び出しのたびに通る型の検査を、final の類 2 つの検査へ）
 * TeaVM 自身が持つ org/teavm/ の類は jar から落とす（Flix の依存の解決で同じ物が入り、TeaVM の物と二重になる）。
 * 付け替えた数を種類ごとに標準出力へ 1 行ずつ出す。
 */
public final class Rewrite {
    private Rewrite() { }

    private static final String FIX = "fge/teavmfix/";
    private static final String THUNK = "dev/flix/runtime/Thunk$";
    private static final String VALUE = "dev/flix/runtime/Value$";
    private static final String SUSPENSION = "dev/flix/runtime/Suspension$";
    private static final String THUNKS = FIX + "FlixThunks";

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
            if (counts.containsKey("instanceof-Thunk")) {
                out.putNextEntry(new ZipEntry(THUNKS + ".class"));
                out.write(flixThunksClass());
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

    /**
     * Thunk$ は Flix の関数の類（1 万を超える）がみな実装する interface で、TeaVM の wasm-gc は interface の instanceof を
     * 実装する類の番号の範囲を順に比べて答える（fps3d の部屋で 1 コマの CPU の 4 割がここ）。
     * Flix の生成する instanceof Thunk$ の相手はいつも Result$ で、Result$ を実装するのは Thunk$・Value$・Suspension$ だけ
     * （Value$ と Suspension$ は final）なので、「null でも Value$ でも Suspension$ でもない」と同じ答えになる。
     * WhyNot: Java のソースで書かない — Value$ と Suspension$ はゲームの jar を Flix が組む時に生まれ、tools の jar を組む時には無い。
     */
    private static byte[] flixThunksClass() {
        ClassWriter w = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        w.visit(Opcodes.V17, Opcodes.ACC_PUBLIC | Opcodes.ACC_FINAL | Opcodes.ACC_SUPER, THUNKS, null, "java/lang/Object", null);
        MethodVisitor m = w.visitMethod(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC, "isThunk", "(Ljava/lang/Object;)Z", null, null);
        m.visitCode();
        org.teavm.asm.Label no = new org.teavm.asm.Label();
        m.visitVarInsn(Opcodes.ALOAD, 0);
        m.visitJumpInsn(Opcodes.IFNULL, no);
        m.visitVarInsn(Opcodes.ALOAD, 0);
        m.visitTypeInsn(Opcodes.INSTANCEOF, VALUE);
        m.visitJumpInsn(Opcodes.IFNE, no);
        m.visitVarInsn(Opcodes.ALOAD, 0);
        m.visitTypeInsn(Opcodes.INSTANCEOF, SUSPENSION);
        m.visitJumpInsn(Opcodes.IFNE, no);
        m.visitInsn(Opcodes.ICONST_1);
        m.visitInsn(Opcodes.IRETURN);
        m.visitLabel(no);
        m.visitFrame(Opcodes.F_SAME, 0, null, 0, null);
        m.visitInsn(Opcodes.ICONST_0);
        m.visitInsn(Opcodes.IRETURN);
        m.visitMaxs(0, 0);
        m.visitEnd();
        w.visitEnd();
        return w.toByteArray();
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
        public void visitTypeInsn(int op, String type) {
            if (op == Opcodes.INSTANCEOF && type.equals(THUNK)) {
                note("instanceof-Thunk");
                super.visitMethodInsn(Opcodes.INVOKESTATIC, THUNKS, "isThunk", "(Ljava/lang/Object;)Z", false);
            } else {
                super.visitTypeInsn(op, type);
            }
        }

        @Override
        public void visitMethodInsn(int op, String owner, String name, String desc, boolean itf) {
            if (owner.equals("java/lang/Thread") && name.equals("startVirtualThread")) {
                note("startVirtualThread");
                super.visitMethodInsn(Opcodes.INVOKESTATIC, FIX + "VirtualThreads", name, desc, false);
            } else if (owner.equals("java/util/zip/Checksum") && name.equals("update") && desc.equals("([B)V")) {
                note("Checksum.update");
                super.visitMethodInsn(Opcodes.INVOKESTATIC, FIX + "Checksums", "update", "(Ljava/util/zip/Checksum;[B)V", false);
            } else if (name.equals("refersTo") && desc.equals("(Ljava/lang/Object;)Z") && owner.startsWith("java/lang/ref/")) {
                note("refersTo");
                super.visitMethodInsn(Opcodes.INVOKESTATIC, FIX + "References", "refersTo", "(Ljava/lang/ref/Reference;Ljava/lang/Object;)Z", false);
            } else if (owner.equals("java/lang/Float") && (name.equals("float16ToFloat") || name.equals("floatToFloat16"))) {
                note(name);
                super.visitMethodInsn(Opcodes.INVOKESTATIC, FIX + "HalfFloats", name, desc, false);
            } else if (owner.equals("java/nio/ByteBuffer") && name.equals("allocateDirect")) {
                note("allocateDirect");
                super.visitMethodInsn(Opcodes.INVOKESTATIC, FIX + "DirectBuffers", name, desc, false);
            } else {
                super.visitMethodInsn(op, owner, name, desc, itf);
            }
        }
    }
}
