package fge.web.webgpu;

import fge.web.webgpu.BrowserObjects.*;
import fge.webgpu.ComputePipelineDesc;
import java.util.List;
import org.teavm.jso.webgpu.GPUBindGroup;
import org.teavm.jso.webgpu.GPUCommandEncoder;
import org.teavm.jso.webgpu.GPUComputePassEncoder;
import org.teavm.jso.webgpu.GPUDescriptor;
import org.teavm.jso.webgpu.GPUDevice;
import org.teavm.jso.webgpu.GPUPipeline;

/**
 * ブラウザの compute（pipeline・pass）。device は BrowserWebGpu が渡す（外へは出さない）。
 * WhyNot: pass の命令を render pass のように Int32 の列へ積まない — compute の pass は 1 コマに数十の命令で、行き来の値段が効かない。
 */
final class BrowserCompute {
    private BrowserCompute() {}

    static final class BrowserComputePipeline implements fge.webgpu.ComputePipeline {
        final GPUPipeline.Compute pipeline;

        BrowserComputePipeline(GPUPipeline.Compute pipeline) { this.pipeline = pipeline; }

        @Override public void release() { }
    }

    static final class BrowserComputePass implements fge.webgpu.ComputePass {
        final GPUComputePassEncoder pass;

        BrowserComputePass(GPUComputePassEncoder pass) { this.pass = pass; }

        @Override public void setPipeline(fge.webgpu.ComputePipeline pipeline) {
            pass.setPipeline(((BrowserComputePipeline) pipeline).pipeline);
        }

        @Override public void setBindGroup(int index, fge.webgpu.BindGroup group) {
            pass.setBindGroup(index, ((BrowserBindGroup) group).group);
        }

        @Override public void dispatchWorkgroups(int x, int y, int z) { pass.dispatchWorkgroups(x, y, z); }

        @Override public void end() { pass.end(); }
    }

    // WhyNot: createComputePipelineAsync を待たない — 誤りの道が Dawn の側（uncapturederror と無効な pipeline）と分かれ、errorCount で拾えなくなる。
    static fge.webgpu.ComputePipeline createPipeline(GPUDevice device, ComputePipelineDesc desc) {
        List<fge.webgpu.BindGroupLayout> layoutList = desc.bindGroupLayouts();
        GPUBindGroup.Layout[] layouts = new GPUBindGroup.Layout[layoutList.size()];
        for (int i = 0; i < layouts.length; i++) layouts[i] = ((BrowserBindGroupLayout) layoutList.get(i)).layout;
        GPUDescriptor.PipelineLayout layoutDesc = GPUDescriptor.create();
        layoutDesc.setLabel(desc.label());
        layoutDesc.setBindGroupLayouts(layouts);
        GPUDescriptor.ProgrammableStage stage = GPUDescriptor.create();
        stage.setModule(((BrowserShaderModule) desc.module()).module);
        stage.setEntryPoint(desc.entryPoint());
        GPUDescriptor.ComputePipeline d = GPUDescriptor.create();
        d.setLabel(desc.label());
        d.setLayout(device.createPipelineLayout(layoutDesc));
        d.setCompute(stage);
        return new BrowserComputePipeline(device.createComputePipeline(d));
    }

    static fge.webgpu.ComputePass beginPass(GPUCommandEncoder encoder, String label, fge.webgpu.QuerySet timestamps, int beginIndex, int endIndex) {
        GPUDescriptor.ComputePass d = GPUDescriptor.create();
        d.setLabel(label);
        if (timestamps != null) {
            GPUDescriptor.ComputePassTimestampWrites writes = GPUDescriptor.create();
            writes.setQuerySet(((BrowserQuerySet) timestamps).querySet);
            writes.setBeginningOfPassWriteIndex(beginIndex);
            writes.setEndOfPassWriteIndex(endIndex);
            d.setTimestampWrites(writes);
        }
        return new BrowserComputePass(encoder.beginComputePass(d));
    }
}
