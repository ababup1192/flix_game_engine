package fge.webgpu;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * beginRenderPass に渡す描き先。設定の関数は自分を返す（つないで書く）。resolveTo は直前の描き先に掛かる。
 * WhyNot: 前の中身を残すかを引数の真偽で渡さない — clear と load は欄の組が違い（load は色を持たない）、関数を分けた方が読み違えない。
 */
public final class RenderPassDesc {
    /** 色の描き先 1 枚。clear が偽なら前の中身を読んで描き足す。 */
    public static final class ColorAttachment {
        public final TextureView view;
        public final boolean clear;
        public final double r, g, b, a;
        public TextureView resolveTarget;

        ColorAttachment(TextureView view, boolean clear, double r, double g, double b, double a) {
            this.view = view;
            this.clear = clear;
            this.r = r;
            this.g = g;
            this.b = b;
            this.a = a;
        }
    }

    private final String label;
    private final List<ColorAttachment> colors = new ArrayList<>();
    private TextureView depthView;
    private boolean depthClear;
    private double depthClearValue;
    private int stencilClearValue;
    private boolean hasStencil;
    private QuerySet timestamps;
    private int timestampBegin;
    private int timestampEnd;

    public RenderPassDesc(String label) { this.label = label; }

    public RenderPassDesc clearColor(TextureView view, double r, double g, double b, double a) {
        colors.add(new ColorAttachment(view, true, r, g, b, a));
        return this;
    }

    public RenderPassDesc loadColor(TextureView view) {
        colors.add(new ColorAttachment(view, false, 0, 0, 0, 0));
        return this;
    }

    public RenderPassDesc resolveTo(TextureView target) {
        if (colors.isEmpty()) throw new IllegalStateException("resolveTo before a color attachment");
        colors.get(colors.size() - 1).resolveTarget = target;
        return this;
    }

    /** 深度だけの形（DEPTH24_PLUS・DEPTH32_FLOAT）。 */
    public RenderPassDesc clearDepth(TextureView view, double depth) {
        depthView = view;
        depthClear = true;
        depthClearValue = depth;
        hasStencil = false;
        return this;
    }

    /** 深度と stencil の形（DEPTH24_PLUS_STENCIL8）。 */
    public RenderPassDesc clearDepthStencil(TextureView view, double depth, int stencil) {
        depthView = view;
        depthClear = true;
        depthClearValue = depth;
        stencilClearValue = stencil;
        hasStencil = true;
        return this;
    }

    public RenderPassDesc loadDepthStencil(TextureView view, boolean hasStencil) {
        depthView = view;
        depthClear = false;
        this.hasStencil = hasStencil;
        return this;
    }

    /** pass の始めと終わりの時刻を querySet の begin・end 番に書く（timestamp-query がある device だけ）。 */
    public RenderPassDesc timestampWrites(QuerySet querySet, int begin, int end) {
        timestamps = querySet;
        timestampBegin = begin;
        timestampEnd = end;
        return this;
    }

    public String label() { return label; }
    public List<ColorAttachment> colors() { return Collections.unmodifiableList(colors); }
    public TextureView depthView() { return depthView; }
    public boolean depthClear() { return depthClear; }
    public double depthClearValue() { return depthClearValue; }
    public int stencilClearValue() { return stencilClearValue; }
    public boolean hasStencil() { return hasStencil; }
    public QuerySet timestamps() { return timestamps; }
    public int timestampBegin() { return timestampBegin; }
    public int timestampEnd() { return timestampEnd; }
}
