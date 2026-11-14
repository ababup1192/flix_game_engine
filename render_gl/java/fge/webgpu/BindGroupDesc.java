package fge.webgpu;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** createBindGroup に渡す中身。項目を足す関数は自分を返す（つないで書く）。 */
public final class BindGroupDesc {
    /** 1 項目。buffer・view・sampler のどれか 1 つだけが null でない。 */
    public static final class Entry {
        public final int binding;
        public final Buffer buffer;
        public final long offset;
        public final long size;
        public final TextureView view;
        public final Sampler sampler;

        Entry(int binding, Buffer buffer, long offset, long size, TextureView view, Sampler sampler) {
            this.binding = binding;
            this.buffer = buffer;
            this.offset = offset;
            this.size = size;
            this.view = view;
            this.sampler = sampler;
        }
    }

    private final String label;
    private final BindGroupLayout layout;
    private final List<Entry> entries = new ArrayList<>();

    public BindGroupDesc(String label, BindGroupLayout layout) {
        this.label = label;
        this.layout = layout;
    }

    public BindGroupDesc buffer(int binding, Buffer buffer, long offset, long size) {
        entries.add(new Entry(binding, buffer, offset, size, null, null));
        return this;
    }

    public BindGroupDesc textureView(int binding, TextureView view) {
        entries.add(new Entry(binding, null, 0, 0, view, null));
        return this;
    }

    public BindGroupDesc sampler(int binding, Sampler sampler) {
        entries.add(new Entry(binding, null, 0, 0, null, sampler));
        return this;
    }

    public String label() { return label; }

    public BindGroupLayout layout() { return layout; }

    public List<Entry> entries() { return Collections.unmodifiableList(entries); }
}
