package fge.teavmfix;

import java.io.File;
import org.teavm.diagnostics.ProblemProvider;
import org.teavm.tooling.ConsoleTeaVMToolLog;
import org.teavm.tooling.TeaVMProblemRenderer;
import org.teavm.tooling.TeaVMTargetType;
import org.teavm.tooling.TeaVMTool;
import org.teavm.vm.TeaVMOptimizationLevel;

/**
 * TeaVM で jar を wasm-gc へ訳す（書き出しの道具の③）。TeaVM が読むのはこの JVM の classpath。
 * 使い方: java -cp fge-web-tools.jar:TeaVM の jar:入る.jar fge.teavmfix.BuildWasm 入口の類 出すフォルダ 出す名前
 * 穴は TeaVM の CLI と同じ形（`ERROR` で始まる行）で出し、重い穴が 1 件でもあれば終わりの番号 1。
 */
public final class BuildWasm {
    private BuildWasm() { }

    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            System.err.println("usage: BuildWasm <main class> <out dir> <file name>");
            System.exit(2);
        }
        ConsoleTeaVMToolLog log = new ConsoleTeaVMToolLog(false);
        TeaVMTool tool = new TeaVMTool();
        tool.setTargetType(TeaVMTargetType.WEBASSEMBLY_GC);
        tool.setMainClass(args[0]);
        tool.setTargetDirectory(new File(args[1]));
        tool.setTargetFileName(args[2]);
        // WhyNot: FULL にしない — engine 全体の wasm が倍（約 16 MB）になり、訳す時間も延びる。
        tool.setOptimizationLevel(TeaVMOptimizationLevel.ADVANCED);
        tool.setObfuscated(false);
        tool.setLog(log);
        tool.generate();
        ProblemProvider problems = tool.getProblemProvider();
        TeaVMProblemRenderer.describeProblems(tool.getDependencyInfo().getCallGraph(), problems, log);
        System.exit(problems.getSevereProblems().isEmpty() ? 0 : 1);
    }
}
