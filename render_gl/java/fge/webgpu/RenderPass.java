package fge.webgpu;

/** 1 つの render pass に描く命令を積む物。end の後は使わない。 */
public interface RenderPass {
    void setPipeline(RenderPipeline pipeline);

    void setBindGroup(int index, BindGroup group);

    void setVertexBuffer(int slot, Buffer buffer, long offset, long size);

    void setIndexBuffer(Buffer buffer, IndexFormat format, long offset, long size);

    void setViewport(double x, double y, double width, double height, double minDepth, double maxDepth);

    void setScissorRect(int x, int y, int width, int height);

    void setStencilReference(int reference);

    void setBlendConstant(double r, double g, double b, double a);

    void draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance);

    void drawIndexed(int indexCount, int instanceCount, int firstIndex, int baseVertex, int firstInstance);

    void end();
}
