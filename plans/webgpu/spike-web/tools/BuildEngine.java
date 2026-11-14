import java.io.File;
import java.io.IOException;
import java.net.URL;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;
import org.teavm.tooling.*;
import org.teavm.vm.TeaVMOptimizationLevel;

// usage: BuildEngine <system|nojdk> <MainClass> <outdir>
// The classpath of this JVM (java -cp) is what TeaVM reads.
public class BuildEngine {
    // WhyNot: the system loader as-is lets TeaVM read real JDK class files (jrt:) for classes that teavm-classlib lacks.
    static final class NoJdkLoader extends ClassLoader {
        NoJdkLoader(ClassLoader parent) { super(parent); }
        static boolean isJdk(URL u) { return u != null && "jrt".equals(u.getProtocol()); }
        @Override public URL getResource(String name) {
            URL u = getParent().getResource(name);
            return isJdk(u) ? null : u;
        }
        @Override public Enumeration<URL> getResources(String name) throws IOException {
            List<URL> out = new ArrayList<>();
            for (URL u : Collections.list(getParent().getResources(name))) if (!isJdk(u)) out.add(u);
            return Collections.enumeration(out);
        }
    }

    public static void main(String[] a) throws Exception {
        long t0 = System.nanoTime();
        TeaVMTool t = new TeaVMTool();
        t.setTargetType(TeaVMTargetType.WEBASSEMBLY_GC);
        t.setMainClass(a[1]);
        t.setTargetDirectory(new File(a[2]));
        t.setTargetFileName("classes.wasm");
        t.setOptimizationLevel(TeaVMOptimizationLevel.valueOf(System.getProperty("opt", "ADVANCED")));
        t.setObfuscated(Boolean.getBoolean("obf"));
        t.setLog(new ConsoleTeaVMToolLog(false));
        if (a[0].equals("nojdk")) t.setClassLoader(new NoJdkLoader(BuildEngine.class.getClassLoader()));
        t.generate();
        var p = t.getProblemProvider();
        System.out.println("problems=" + p.getProblems().size() + " severe=" + p.getSevereProblems().size());
        for (var pr : p.getSevereProblems()) {
            System.out.println("SEVERE " + pr.getText() + " | " + java.util.Arrays.toString(pr.getParams()));
        }
        System.out.println("ms=" + (System.nanoTime() - t0) / 1_000_000);
        System.exit(p.getSevereProblems().isEmpty() ? 0 : 1);
    }
}
