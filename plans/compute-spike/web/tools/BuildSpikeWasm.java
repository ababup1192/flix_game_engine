import java.io.File;
import org.teavm.diagnostics.ProblemProvider;
import org.teavm.tooling.ConsoleTeaVMToolLog;
import org.teavm.tooling.TeaVMProblemRenderer;
import org.teavm.tooling.TeaVMTargetType;
import org.teavm.tooling.TeaVMTool;
import org.teavm.vm.TeaVMOptimizationLevel;

/** engine_web の fge.teavmfix.BuildWasm と同じ設定（WasmGC・ADVANCED）で、スパイクの類だけを wasm にする。 */
public final class BuildSpikeWasm {
    public static void main(String[] args) throws Exception {
        ConsoleTeaVMToolLog log = new ConsoleTeaVMToolLog(false);
        TeaVMTool tool = new TeaVMTool();
        tool.setTargetType(TeaVMTargetType.WEBASSEMBLY_GC);
        tool.setMainClass(args[0]);
        tool.setTargetDirectory(new File(args[1]));
        tool.setTargetFileName(args[2]);
        tool.setOptimizationLevel(TeaVMOptimizationLevel.ADVANCED);
        tool.setObfuscated(false);
        tool.setLog(log);
        tool.generate();
        ProblemProvider problems = tool.getProblemProvider();
        TeaVMProblemRenderer.describeProblems(tool.getDependencyInfo().getCallGraph(), problems, log);
        System.exit(problems.getSevereProblems().isEmpty() ? 0 : 1);
    }
}
