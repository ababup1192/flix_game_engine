package fge.webgpu;

/**
 * 積んだ命令の束（render pass の executeBundle で何コマでも流す）。中では scissor・viewport・stencil の比べる値・blend の定数を変えられず、
 * 流した後の pass は pipeline・bind group・頂点の buffer を付け直す。
 */
public interface RenderBundle {
    void release();
}
