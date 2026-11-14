package fge.webgpu;

/** surface の present の待ち方（WebGPU の GPUPresentMode 相当）。 */
public enum PresentMode {
    FIFO, IMMEDIATE, MAILBOX
}
