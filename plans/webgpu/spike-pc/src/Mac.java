import org.lwjgl.system.JNI;
import org.lwjgl.system.macosx.ObjCRuntime;

/** NSWindow から CAMetalLayer を作って contentView へ付ける。 */
public final class Mac {
    static final long MSG = ObjCRuntime.getLibrary().getFunctionAddress("objc_msgSend");
    static long sel(String s) { return ObjCRuntime.sel_getUid(s); }
    public static long contentView(long nsWindow) { return JNI.invokePPP(nsWindow, sel("contentView"), MSG); }
    public static long installMetalLayer(long nsWindow) {
        long view = contentView(nsWindow);
        long layer = JNI.invokePPP(ObjCRuntime.objc_getClass("CAMetalLayer"), sel("layer"), MSG);
        JNI.invokePPPV(view, sel("setWantsLayer:"), 1L, MSG);
        JNI.invokePPPV(view, sel("setLayer:"), layer, MSG);
        return layer;
    }
}
