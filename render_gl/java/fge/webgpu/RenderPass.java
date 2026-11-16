package fge.webgpu;

/** 1 つの render pass に描く命令を積む物。end の後は使わない。 */
public interface RenderPass extends RenderCommands {
    void setViewport(double x, double y, double width, double height, double minDepth, double maxDepth);

    void setScissorRect(int x, int y, int width, int height);

    void setStencilReference(int reference);

    void setBlendConstant(double r, double g, double b, double a);

    /** bundle の命令を流す。流した後は pipeline・bind group・頂点と index の buffer を付け直してから描く。 */
    void executeBundle(RenderBundle bundle);

    void end();
}
