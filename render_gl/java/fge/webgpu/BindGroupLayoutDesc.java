package fge.webgpu;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** createBindGroupLayout に渡す項目の並び。項目を足す関数は自分を返す（つないで書く）。 */
public final class BindGroupLayoutDesc {
    /** 項目の種類。 */
    public enum Kind { BUFFER, TEXTURE, SAMPLER }

    /** 1 項目。種類に合わない欄は null。 */
    public static final class Entry {
        public final int binding;
        public final int visibility;
        public final Kind kind;
        public final BufferBindingType bufferType;
        public final TextureSampleType sampleType;
        public final SamplerBindingType samplerType;
        /** BUFFER の時だけ意味がある。真なら setBindGroup の dynamicOffsets で位置を足す。 */
        public final boolean hasDynamicOffset;

        Entry(int binding, int visibility, Kind kind, BufferBindingType bufferType,
              TextureSampleType sampleType, SamplerBindingType samplerType, boolean hasDynamicOffset) {
            this.binding = binding;
            this.visibility = visibility;
            this.kind = kind;
            this.bufferType = bufferType;
            this.sampleType = sampleType;
            this.samplerType = samplerType;
            this.hasDynamicOffset = hasDynamicOffset;
        }
    }

    private final String label;
    private final List<Entry> entries = new ArrayList<>();

    public BindGroupLayoutDesc(String label) { this.label = label; }

    /** visibility は ShaderStage の旗。 */
    public BindGroupLayoutDesc buffer(int binding, int visibility, BufferBindingType type) {
        entries.add(new Entry(binding, visibility, Kind.BUFFER, type, null, null, false));
        return this;
    }

    /** buffer と同じ。位置は setBindGroup の dynamicOffsets で描くたびに渡す（group を位置ごとに作らない）。 */
    public BindGroupLayoutDesc dynamicBuffer(int binding, int visibility, BufferBindingType type) {
        entries.add(new Entry(binding, visibility, Kind.BUFFER, type, null, null, true));
        return this;
    }

    public BindGroupLayoutDesc texture(int binding, int visibility, TextureSampleType sampleType) {
        entries.add(new Entry(binding, visibility, Kind.TEXTURE, null, sampleType, null, false));
        return this;
    }

    public BindGroupLayoutDesc sampler(int binding, int visibility, SamplerBindingType type) {
        entries.add(new Entry(binding, visibility, Kind.SAMPLER, null, null, type, false));
        return this;
    }

    public String label() { return label; }

    public List<Entry> entries() { return Collections.unmodifiableList(entries); }
}
