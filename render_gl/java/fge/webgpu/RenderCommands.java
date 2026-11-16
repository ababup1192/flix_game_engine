package fge.webgpu;

/** render pass と render bundle に共通の、描く命令を積む物（行を流す所は どちらにも同じ命令で積む）。 */
public interface RenderCommands {
    void setPipeline(RenderPipeline pipeline);

    void setBindGroup(int index, BindGroup group);

    void setVertexBuffer(int slot, Buffer buffer, long offset, long size);

    void setIndexBuffer(Buffer buffer, IndexFormat format, long offset, long size);

    void draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance);

    void drawIndexed(int indexCount, int instanceCount, int firstIndex, int baseVertex, int firstInstance);
}
