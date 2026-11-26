package fge.webgpu.dawn;

import com.github.xpenatan.webgpu.*;
import fge.webgpu.ComputePipelineDesc;
import fge.webgpu.dawn.DawnObjects.*;

/** Dawn の compute（pipeline・pass）。DawnWebGpu と DawnCommandEncoder が呼ぶ。 */
final class DawnCompute {
    private DawnCompute() {}

    static final class DawnComputePipeline implements fge.webgpu.ComputePipeline {
        final WGPUComputePipeline pipeline;
        private boolean released;

        DawnComputePipeline(WGPUComputePipeline pipeline) { this.pipeline = pipeline; }

        @Override public void release() {
            if (released) return;
            released = true;
            pipeline.release();
        }
    }

    static final class DawnComputePass implements fge.webgpu.ComputePass {
        final WGPUComputePassEncoder pass;

        DawnComputePass(WGPUComputePassEncoder pass) { this.pass = pass; }

        @Override public void setPipeline(fge.webgpu.ComputePipeline pipeline) {
            pass.setPipeline(((DawnComputePipeline) pipeline).pipeline);
        }

        @Override public void setBindGroup(int index, fge.webgpu.BindGroup group) {
            pass.setBindGroup(index, ((DawnBindGroup) group).group);
        }

        @Override public void dispatchWorkgroups(int x, int y, int z) { pass.setDispatchWorkgroups(x, y, z); }

        @Override public void end() {
            pass.end();
            pass.release();
        }
    }

    static fge.webgpu.ComputePipeline createPipeline(WGPUDevice device, ComputePipelineDesc desc) {
        WGPUVectorBindGroupLayout layouts = new WGPUVectorBindGroupLayout();
        for (fge.webgpu.BindGroupLayout l : desc.bindGroupLayouts()) layouts.push_back(((DawnBindGroupLayout) l).layout);
        WGPUPipelineLayoutDescriptor layoutDesc = new WGPUPipelineLayoutDescriptor();
        layoutDesc.setLabel(desc.label());
        layoutDesc.setBindGroupLayouts(layouts);
        WGPUPipelineLayout layout = new WGPUPipelineLayout();
        device.createPipelineLayout(layoutDesc, layout);
        WGPUComputePipelineDescriptor d = new WGPUComputePipelineDescriptor();
        d.setLabel(desc.label());
        d.setLayout(layout);
        d.getCompute().setNextInChain(WGPUChainedStruct.NULL);
        d.getCompute().setModule(((DawnShaderModule) desc.module()).module);
        d.getCompute().setEntryPoint(desc.entryPoint());
        d.getCompute().setConstants(WGPUVectorConstantEntry.NULL);
        WGPUComputePipeline pipeline = new WGPUComputePipeline();
        device.createComputePipeline(d, pipeline);
        // WhyNot: pipeline layout を pipeline と一緒に持ち回らない — pipeline が自分で参照を持つので、ここで手放してよい。
        layout.release();
        d.dispose();
        layoutDesc.dispose();
        layouts.dispose();
        return new DawnComputePipeline(pipeline);
    }

    static fge.webgpu.ComputePass beginPass(WGPUCommandEncoder encoder, String label, fge.webgpu.QuerySet timestamps, int beginIndex, int endIndex) {
        WGPUComputePassDescriptor d = new WGPUComputePassDescriptor();
        d.setNextInChain(WGPUChainedStruct.NULL);
        d.setLabel(label);
        WGPUComputePassEncoder pass = new WGPUComputePassEncoder();
        if (timestamps != null) {
            synchronized (DawnFormats.SHARED) {
                // WhyNot: 欄に 1 つ持たない — jWebGPU はこの型を obtain（共有の 1 個）でしか作らせない。
                WGPUPassTimestampWrites writes = WGPUPassTimestampWrites.obtain();
                writes.setQuerySet(((DawnQuerySet) timestamps).querySet);
                writes.setBeginningOfPassWriteIndex(beginIndex);
                writes.setEndOfPassWriteIndex(endIndex);
                d.setTimestampWrites(writes);
                encoder.beginComputePass(d, pass);
            }
        } else {
            d.setTimestampWrites(WGPUPassTimestampWrites.NULL);
            encoder.beginComputePass(d, pass);
        }
        d.dispose();
        return new DawnComputePass(pass);
    }
}
