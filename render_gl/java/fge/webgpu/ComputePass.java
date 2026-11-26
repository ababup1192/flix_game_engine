package fge.webgpu;

/** 1 つの compute pass に dispatch を積む物。end の後は使わない。同じ pass の dispatch どうしの読み書きの順は WebGPU が保つ。 */
public interface ComputePass {
    void setPipeline(ComputePipeline pipeline);

    void setBindGroup(int index, BindGroup group);

    void dispatchWorkgroups(int x, int y, int z);

    void end();
}
