import java.util.Arrays;
import org.teavm.jso.JSBody;
import org.teavm.jso.JSObject;
import org.teavm.jso.typedarrays.Float32Array;

public class MainGlOnly {
    @JSBody(script = "return performance.now();") static native double now();
    @JSBody(params = {"s"}, script = "window.__result = JSON.parse(s); document.title = 'done';") static native void report(String s);
    @JSBody(params = {"sz"}, script = "fgeSetupGl(sz);") static native void glSetup(int sz);
    @JSBody(script = "fgeGlBegin();") static native void glBegin();
    @JSBody(params = {"l", "t", "v"}, script = "fgeGl.uniformMatrix4fv(fgeU[l], t, v);") static native void glUniformMatrix4fv(int l, boolean t, JSObject v);
    @JSBody(params = {"m", "f", "c"}, script = "fgeGl.drawArrays(m, f, c);") static native void glDrawArrays(int m, int f, int c);
    @JSBody(script = "fgeGl.finish();") static native void glFinish();

    public static void main(String[] a) {
        glSetup(512);
        int n = 1000;
        float[] m = new float[16];
        double t0 = now();
        for (int f = 0; f < 10; f++) {
            glBegin();
            for (int i = 0; i < n; i++) { glUniformMatrix4fv(0, false, Float32Array.copyFromJavaArray(m)); glDrawArrays(4, 0, 6); }
            glFinish();
        }
        report("{\"ms\":" + (now() - t0) + "}");
    }
}
