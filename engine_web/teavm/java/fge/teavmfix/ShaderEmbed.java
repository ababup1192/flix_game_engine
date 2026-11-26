package fge.teavmfix;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;
import org.teavm.asm.ClassWriter;
import org.teavm.asm.MethodTooLargeException;
import org.teavm.asm.MethodVisitor;
import org.teavm.asm.Opcodes;

/**
 * shader-bake の表（{ 鍵: 字 } の JSON の object 1 つ）から fge.web.ShaderLibraryData を作り、jar の中の空の版と差し替える。
 * 引数: 入る.jar 出る.jar 表.json。標準出力の `shaders <本数> <字の数>` を書き出しの道具が読む。
 */
public final class ShaderEmbed {
    private ShaderEmbed() { }

    private static final String TARGET = "fge/web/ShaderLibraryData.class";

    // WhyNot: 切れ端を長くしない — class の定数 1 つは modified UTF-8 で 65535 バイトまでで、全角の字は 3 バイトになる。
    private static final int CHUNK = 16000;

    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            System.err.println("usage: ShaderEmbed <in.jar> <out.jar> <table.json>");
            System.exit(2);
        }
        Map<String, String> sources;
        try {
            sources = parseObject(Files.readString(Path.of(args[2]), StandardCharsets.UTF_8));
        } catch (IllegalArgumentException e) {
            System.err.println("ShaderEmbed: " + args[2] + " を読めない（" + e.getMessage() + "）");
            System.exit(1);
            return;
        }
        List<String> table = new ArrayList<>();
        long chars = 0;
        for (Map.Entry<String, String> e : sources.entrySet()) {
            String text = e.getValue();
            List<String> chunks = new ArrayList<>();
            for (int at = 0; at < text.length(); at += CHUNK) {
                chunks.add(text.substring(at, Math.min(text.length(), at + CHUNK)));
            }
            table.add(e.getKey());
            table.add(Integer.toString(chunks.size()));
            table.addAll(chunks);
            chars += text.length();
        }
        byte[] cls;
        try {
            cls = buildClass(table.toArray(new String[0]));
        } catch (MethodTooLargeException e) {
            System.err.println("ShaderEmbed: シェーダーの表が class の関数に収まらない（表の " + table.size() + " 個）");
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
            System.err.println("ShaderEmbed: " + args[0] + " に " + TARGET + " が無い（engine_full_web の fge-web.jar が古い）");
            System.exit(1);
        }
        System.out.println("shaders " + sources.size() + " " + chars);
    }

    // WhyNot: javac で .java から組まない — Embed と同じく、配った版の書き出しは JRE だけで動く。
    private static byte[] buildClass(String[] table) {
        ClassWriter w = new ClassWriter(ClassWriter.COMPUTE_MAXS);
        w.visit(Opcodes.V17, Opcodes.ACC_PUBLIC | Opcodes.ACC_FINAL | Opcodes.ACC_SUPER, "fge/web/ShaderLibraryData", null, "java/lang/Object", null);
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

    /** 字の値だけを持つ JSON の object を、鍵の順の表にする。 */
    static Map<String, String> parseObject(String json) {
        Parser p = new Parser(json);
        Map<String, String> out = new TreeMap<>();
        p.skipSpace();
        p.expect('{');
        p.skipSpace();
        if (p.peek() == '}') {
            p.next();
            return out;
        }
        while (true) {
            p.skipSpace();
            String key = p.string();
            p.skipSpace();
            p.expect(':');
            p.skipSpace();
            out.put(key, p.string());
            p.skipSpace();
            char c = p.next();
            if (c == '}') {
                return out;
            }
            if (c != ',') {
                throw new IllegalArgumentException(p.at + " 字目に , か } が要る");
            }
        }
    }

    private static final class Parser {
        final String s;
        int at = 0;

        Parser(String s) { this.s = s; }

        char peek() {
            if (at >= s.length()) {
                throw new IllegalArgumentException("途中で終わった");
            }
            return s.charAt(at);
        }

        char next() {
            char c = peek();
            at++;
            return c;
        }

        void expect(char c) {
            if (next() != c) {
                throw new IllegalArgumentException(at + " 字目に " + c + " が要る");
            }
        }

        void skipSpace() {
            while (at < s.length() && Character.isWhitespace(s.charAt(at))) {
                at++;
            }
        }

        String string() {
            expect('"');
            StringBuilder b = new StringBuilder();
            while (true) {
                char c = next();
                if (c == '"') {
                    return b.toString();
                }
                if (c != '\\') {
                    b.append(c);
                    continue;
                }
                char e = next();
                switch (e) {
                    case 'n': b.append('\n'); break;
                    case 't': b.append('\t'); break;
                    case 'r': b.append('\r'); break;
                    case 'b': b.append('\b'); break;
                    case 'f': b.append('\f'); break;
                    case 'u':
                        if (at + 4 > s.length()) {
                            throw new IllegalArgumentException("\\u の後が短い");
                        }
                        b.append((char) Integer.parseInt(s.substring(at, at + 4), 16));
                        at += 4;
                        break;
                    default: b.append(e);
                }
            }
        }
    }
}
