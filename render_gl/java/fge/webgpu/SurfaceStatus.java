package fge.webgpu;

/** surface の getCurrentTexture の結果。 */
public enum SurfaceStatus {
    SUCCESS_OPTIMAL, SUCCESS_SUBOPTIMAL, TIMEOUT, OUTDATED, LOST, ERROR
}
