package fge.webgpu;

/** render bundle に描く命令を積む物。finish の後は使わない。 */
public interface RenderBundleEncoder extends RenderCommands {
    RenderBundle finish();
}
