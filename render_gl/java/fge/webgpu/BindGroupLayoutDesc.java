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

        Entry(int binding, int visibility, Kind kind, BufferBindingType bufferType,
              TextureSampleType sampleType, SamplerBindingType samplerType) {
            this.binding = binding;
            this.visibility = visibility;
            this.kind = kind;
            this.bufferType = bufferType;
            this.sampleType = sampleType;
            this.samplerType = samplerType;
        }
    }

    private final String label;
    private final List<Entry> entries = new ArrayList<>();

    public BindGroupLayoutDesc(String label) { this.label = label; }

    /** visibility は ShaderStage の旗。 */
    public BindGroupLayoutDesc buffer(int binding, int visibility, BufferBindingType type) {
        entries.add(new Entry(binding, visibility, Kind.BUFFER, type, null, null));
        return this;
    }

    public BindGroupLayoutDesc texture(int binding, int visibility, TextureSampleType sampleType) {
        entries.add(new Entry(binding, visibility, Kind.TEXTURE, null, sampleType, null));
        return this;
    }

    public BindGroupLayoutDesc sampler(int binding, int visibility, SamplerBindingType type) {
        entries.add(new Entry(binding, visibility, Kind.SAMPLER, null, null, type));
        return this;
    }

    public String label() { return label; }

    public List<Entry> entries() { return Collections.unmodifiableList(entries); }
}
