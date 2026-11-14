package fge.webgpu;

import java.nio.ByteBuffer;

/**
 * WebGPU の backend が呼ぶ device と queue の API。実装は PC の Dawn（{@link fge.webgpu.dawn.DawnWebGpu}）と、後でブラウザの JSO。
 * 名前は WebGPU の語をそのまま使う（RenderPipeline・BindGroup・RenderPass・Buffer・Texture・Sampler）。
 * 物は実装ごとの物を包む小さな型（このパッケージの interface）で運び、別の実装の物を混ぜて渡さない。
 * 呼ぶのは全部同じスレッドから。物の寿命は呼び手が持つ（release・destroy を呼ぶ。JNI の実装は GC では手放さない）。
 * 待つ関数（readBuffer・getCompilationInfo・waitIdle）は結果が出るまで返らない。ブラウザではコマの描き（requestAnimationFrame）の外、
 * effect の handler の中でしか呼べない。
 *
 * WhyNot: WebGPU の全部を写さない — backend が使う物だけにし、要る物はその段で足す（compute・render bundle・storage texture はまだ無い）。
 * WhyNot: descriptor を配列で渡さない — Flix から Java の物の配列を組む形は型が合わせにくいので、つないで書く Desc の類で渡す。
 * WhyNot: map を非同期の形で出さない — PC は待てば済み、ブラウザは TeaVM の JSPromise.await で同じ形に待てる。
 */
public interface WebGpu {

    // ── device ──
    /** adapter の名前と backend（診断に出す 1 行）。 */
    String adapterInfo();

    Limits limits();

    boolean hasTimestampQuery();

    boolean hasCoreFeaturesAndLimits();

    /** 拾われなかった GPU の誤り（検証の誤りなど）の数。数える前に溜まった知らせを受け取る。 */
    int errorCount();

    /** 最後の誤りの文（無ければ空）。 */
    String lastError();

    /** device を捨てる。この後この device の物は使えない。 */
    void destroy();

    // ── 物を作る ──
    /** usage は BufferUsage の旗。size は 4 の倍数。 */
    Buffer createBuffer(String label, long size, int usage);

    /** usage は TextureUsage の旗。 */
    Texture createTexture(String label, int width, int height, TextureFormat format, int usage,
                          int mipLevelCount, int sampleCount);

    Sampler createSampler(String label, FilterMode filter, FilterMode mipmapFilter, AddressMode address);

    ShaderModule createShaderModule(String label, String wgsl);

    /** WGSL を組んだ時の誤りと警告の文（無ければ空）。組み終わるまで待つ。 */
    String getCompilationInfo(ShaderModule module);

    BindGroupLayout createBindGroupLayout(BindGroupLayoutDesc desc);

    BindGroup createBindGroup(BindGroupDesc desc);

    RenderPipeline createRenderPipeline(RenderPipelineDesc desc);

    /** timestamp を count 個書ける所（hasTimestampQuery が真の時だけ）。 */
    QuerySet createTimestampQuerySet(String label, int count);

    CommandEncoder createCommandEncoder(String label);

    // ── queue ──
    /** data の [dataOffset, dataOffset + size) を buffer の offset へ写す（data は direct）。 */
    void writeBuffer(Buffer buffer, long offset, ByteBuffer data, int dataOffset, int size);

    /** data の dataOffset から行ごと bytesPerRow 刻みの画素を texture の段 mip の (x, y)-(x + width, y + height) へ写す（data は direct）。 */
    void writeTexture(Texture texture, int mip, int x, int y, int width, int height,
                      ByteBuffer data, int dataOffset, int bytesPerRow);

    void submit(CommandBuffer commands);

    /** MAP_READ の buffer の [offset, offset + size) を dst の先頭から写す（dst は direct）。読めるまで待つ。 */
    void readBuffer(Buffer buffer, long offset, int size, ByteBuffer dst);

    /** submit した仕事が終わるまで待つ。 */
    void waitIdle();
}
