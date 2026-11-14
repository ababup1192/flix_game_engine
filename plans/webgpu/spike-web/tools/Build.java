import java.io.File;
import org.teavm.tooling.*;
import org.teavm.vm.TeaVMOptimizationLevel;

public class Build {
    public static void main(String[] a) throws Exception {
        TeaVMTool t = new TeaVMTool();
        t.setTargetType(TeaVMTargetType.WEBASSEMBLY_GC);
        t.setMainClass(a[0]);
        t.setTargetDirectory(new File(a[1]));
        t.setTargetFileName("classes.wasm");
        t.setOptimizationLevel(TeaVMOptimizationLevel.FULL);
        t.setObfuscated(true);
        t.setLog(new ConsoleTeaVMToolLog(false));
        t.generate();
        var p = t.getProblemProvider();
        System.out.println("problems=" + p.getProblems().size() + " severe=" + p.getSevereProblems().size());
        for (var pr : p.getSevereProblems()) System.out.println("SEVERE " + pr.getText() + " " + pr.getLocation());
        System.exit(p.getSevereProblems().isEmpty() ? 0 : 1);
    }
}
