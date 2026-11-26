package fge.webgpu;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * createComputePipeline に渡す中身。設定の関数は自分を返す（つないで書く）。
 * WhyNot: layout を 'auto' にできる形にしない — auto の layout は pipeline ごとに別の物になり、同じ bind group を 2 つの pipeline で使い回せない。
 */
public final class ComputePipelineDesc {
    private final String label;
    private final List<BindGroupLayout> bindGroupLayouts = new ArrayList<>();
    private ShaderModule module;
    private String entryPoint = "cs_main";

    public ComputePipelineDesc(String label) { this.label = label; }

    /** 足した順に group 0, 1, … になる。 */
    public ComputePipelineDesc bindGroupLayout(BindGroupLayout layout) {
        bindGroupLayouts.add(layout);
        return this;
    }

    public ComputePipelineDesc compute(ShaderModule module, String entryPoint) {
        this.module = module;
        this.entryPoint = entryPoint;
        return this;
    }

    public String label() { return label; }
    public List<BindGroupLayout> bindGroupLayouts() { return Collections.unmodifiableList(bindGroupLayouts); }
    public ShaderModule module() { return module; }
    public String entryPoint() { return entryPoint; }
}
