package fge.web;

import org.teavm.jso.JSBody;

/**
 * 音（WebAudio）。音は起動の前に fge-web.js がデコードし終えて名前で持つ（後回しの音は届いて解いた時に足す）。名前ごとに GainNode を 1 つ持ち、
 * 鳴らすたびに AudioBufferSourceNode を作り直す（使い捨ての物なので）。知らない名前は何もしない。
 */
public final class WebAudio {
    private WebAudio() { }

    /** 名前の音を持っているか。 */
    @JSBody(params = {"name"}, script = "return fgeAudio.has(name);")
    public static native boolean has(String name);

    /** 頭から鳴らし直す。 */
    @JSBody(params = {"name"}, script = "fgeAudio.play(name);")
    public static native void play(String name);

    @JSBody(params = {"name"}, script = "fgeAudio.stop(name);")
    public static native void stop(String name);

    @JSBody(params = {"name", "volume"}, script = "fgeAudio.setVolume(name, volume);")
    public static native void setVolume(String name, double volume);

    @JSBody(params = {"name", "pitch"}, script = "fgeAudio.setPitch(name, pitch);")
    public static native void setPitch(String name, double pitch);

    @JSBody(params = {"name", "loop"}, script = "fgeAudio.setLooping(name, loop);")
    public static native void setLooping(String name, boolean loop);

    /** 名前の音がループする設定か（project.json の looping か、後から setLooping した値）。無ければ false。 */
    @JSBody(params = {"name"}, script = "return fgeAudio.isLooping(name);")
    public static native boolean isLooping(String name);

    /** 全体の音量（0〜1）。 */
    @JSBody(params = {"gain"}, script = "fgeAudio.setMaster(gain);")
    public static native void setMaster(double gain);

    /** 音の長さ（秒）。無ければ 0。 */
    @JSBody(params = {"name"}, script = "return fgeAudio.seconds(name);")
    public static native double seconds(String name);
}
