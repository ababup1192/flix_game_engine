package fge.webgpu;

/** GPU の上の buffer。 */
public interface Buffer {
    long size();

    void destroy();
}
