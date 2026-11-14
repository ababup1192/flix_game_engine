package fge.webgpu;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * createRenderPipeline に渡す中身。設定の関数は自分を返す（つないで書く）。
 * attribute は直前の vertexBuffer に、blend は直前の colorTarget に掛かる。
 * 既定: 三角形の列・CCW が表・間引かない・深度なし・標本 1。
 */
public final class RenderPipelineDesc {
    /** 頂点の属性 1 つ。 */
    public static final class Attribute {
        public final VertexFormat format;
        public final int offset;
        public final int location;

        Attribute(VertexFormat format, int offset, int location) {
            this.format = format;
            this.offset = offset;
            this.location = location;
        }
    }

    /** 頂点の buffer 1 本の形。 */
    public static final class VertexBuffer {
        public final int arrayStride;
        public final boolean perInstance;
        public final List<Attribute> attributes = new ArrayList<>();

        VertexBuffer(int arrayStride, boolean perInstance) {
            this.arrayStride = arrayStride;
            this.perInstance = perInstance;
        }
    }

    /** blend の片方（色か alpha）。 */
    public static final class BlendComponent {
        public final BlendFactor src;
        public final BlendFactor dst;
        public final BlendOperation operation;

        BlendComponent(BlendFactor src, BlendFactor dst, BlendOperation operation) {
            this.src = src;
            this.dst = dst;
            this.operation = operation;
        }
    }

    /** 描き先 1 枚。blend しない時は color と alpha が null。 */
    public static final class ColorTarget {
        public final TextureFormat format;
        public BlendComponent color;
        public BlendComponent alpha;

        ColorTarget(TextureFormat format) { this.format = format; }
    }

    /** stencil の表と裏に同じ物を使う（このエンジンは裏表で分けない）。 */
    public static final class Stencil {
        public final CompareFunction compare;
        public final StencilOperation failOp;
        public final StencilOperation depthFailOp;
        public final StencilOperation passOp;
        public final int readMask;
        public final int writeMask;

        Stencil(CompareFunction compare, StencilOperation failOp, StencilOperation depthFailOp,
                StencilOperation passOp, int readMask, int writeMask) {
            this.compare = compare;
            this.failOp = failOp;
            this.depthFailOp = depthFailOp;
            this.passOp = passOp;
            this.readMask = readMask;
            this.writeMask = writeMask;
        }
    }

    private final String label;
    private final List<BindGroupLayout> bindGroupLayouts = new ArrayList<>();
    private final List<VertexBuffer> vertexBuffers = new ArrayList<>();
    private final List<ColorTarget> colorTargets = new ArrayList<>();
    private ShaderModule vertexModule;
    private String vertexEntry = "vs_main";
    private ShaderModule fragmentModule;
    private String fragmentEntry = "fs_main";
    private PrimitiveTopology topology = PrimitiveTopology.TRIANGLE_LIST;
    private FrontFace frontFace = FrontFace.CCW;
    private CullMode cullMode = CullMode.NONE;
    private TextureFormat depthFormat;
    private boolean depthWrite;
    private CompareFunction depthCompare = CompareFunction.ALWAYS;
    private Stencil stencil;
    private int sampleCount = 1;

    public RenderPipelineDesc(String label) { this.label = label; }

    /** 足した順に group 0, 1, … になる。 */
    public RenderPipelineDesc bindGroupLayout(BindGroupLayout layout) {
        bindGroupLayouts.add(layout);
        return this;
    }

    public RenderPipelineDesc vertex(ShaderModule module, String entryPoint) {
        vertexModule = module;
        vertexEntry = entryPoint;
        return this;
    }

    public RenderPipelineDesc vertexBuffer(int arrayStride, boolean perInstance) {
        vertexBuffers.add(new VertexBuffer(arrayStride, perInstance));
        return this;
    }

    public RenderPipelineDesc attribute(VertexFormat format, int offset, int location) {
        if (vertexBuffers.isEmpty()) throw new IllegalStateException("attribute before vertexBuffer");
        vertexBuffers.get(vertexBuffers.size() - 1).attributes.add(new Attribute(format, offset, location));
        return this;
    }

    public RenderPipelineDesc fragment(ShaderModule module, String entryPoint) {
        fragmentModule = module;
        fragmentEntry = entryPoint;
        return this;
    }

    public RenderPipelineDesc colorTarget(TextureFormat format) {
        colorTargets.add(new ColorTarget(format));
        return this;
    }

    public RenderPipelineDesc blend(BlendFactor colorSrc, BlendFactor colorDst, BlendOperation colorOp,
                                    BlendFactor alphaSrc, BlendFactor alphaDst, BlendOperation alphaOp) {
        if (colorTargets.isEmpty()) throw new IllegalStateException("blend before colorTarget");
        ColorTarget t = colorTargets.get(colorTargets.size() - 1);
        t.color = new BlendComponent(colorSrc, colorDst, colorOp);
        t.alpha = new BlendComponent(alphaSrc, alphaDst, alphaOp);
        return this;
    }

    public RenderPipelineDesc primitive(PrimitiveTopology topology, FrontFace frontFace, CullMode cullMode) {
        this.topology = topology;
        this.frontFace = frontFace;
        this.cullMode = cullMode;
        return this;
    }

    public RenderPipelineDesc depthStencil(TextureFormat format, boolean depthWrite, CompareFunction depthCompare) {
        this.depthFormat = format;
        this.depthWrite = depthWrite;
        this.depthCompare = depthCompare;
        return this;
    }

    /** depthStencil の後に呼ぶ。 */
    public RenderPipelineDesc stencil(CompareFunction compare, StencilOperation failOp, StencilOperation depthFailOp,
                                      StencilOperation passOp, int readMask, int writeMask) {
        this.stencil = new Stencil(compare, failOp, depthFailOp, passOp, readMask, writeMask);
        return this;
    }

    public RenderPipelineDesc multisample(int count) {
        this.sampleCount = count;
        return this;
    }

    public String label() { return label; }
    public List<BindGroupLayout> bindGroupLayouts() { return Collections.unmodifiableList(bindGroupLayouts); }
    public List<VertexBuffer> vertexBuffers() { return Collections.unmodifiableList(vertexBuffers); }
    public List<ColorTarget> colorTargets() { return Collections.unmodifiableList(colorTargets); }
    public ShaderModule vertexModule() { return vertexModule; }
    public String vertexEntry() { return vertexEntry; }
    public ShaderModule fragmentModule() { return fragmentModule; }
    public String fragmentEntry() { return fragmentEntry; }
    public PrimitiveTopology topology() { return topology; }
    public FrontFace frontFace() { return frontFace; }
    public CullMode cullMode() { return cullMode; }
    public TextureFormat depthFormat() { return depthFormat; }
    public boolean depthWrite() { return depthWrite; }
    public CompareFunction depthCompare() { return depthCompare; }
    public Stencil stencilState() { return stencil; }
    public int sampleCount() { return sampleCount; }
}
