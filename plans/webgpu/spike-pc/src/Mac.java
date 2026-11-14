import org.lwjgl.system.JNI;
import org.lwjgl.system.macosx.ObjCRuntime;

/** NSWindow から CAMetalLayer を作って contentView へ付ける。 */
public final class Mac {
    static final long MSG = ObjCRuntime.getLibrary().getFunctionAddress("objc_msgSend");
    static long sel(String s) { return ObjCRuntime.sel_getUid(s); }
    public static long contentView(long nsWindow) { return JNI.invokePPP(nsWindow, sel("contentView"), MSG); }
    /** screencapture -l に渡す CGWindowID（[NSWindow windowNumber]）。 */
    public static long windowNumber(long nsWindow) { return JNI.invokePPP(nsWindow, sel("windowNumber"), MSG); }
    /** contentView の layer（createMacSurface の後なら CAMetalLayer のはず）。 */
    public static long viewLayer(long nsWindow) { return JNI.invokePPP(contentView(nsWindow), sel("layer"), MSG); }
    public static String className(long obj) {
        if (obj == 0) return "nil";
        long cls = JNI.invokePPP(obj, sel("class"), MSG);
        return ObjCRuntime.class_getName(cls);
    }
    /** [layer contentsScale]（CGFloat を返す msgSend を double として呼ぶ）。 */
    public static double contentsScale(long layer) { return JNI.invokePPD(layer, sel("contentsScale"), MSG); }
    public static double backingScale(long nsWindow) { return JNI.invokePPD(nsWindow, sel("backingScaleFactor"), MSG); }
    public static long installMetalLayer(long nsWindow) {
        long view = contentView(nsWindow);
        long layer = JNI.invokePPP(ObjCRuntime.objc_getClass("CAMetalLayer"), sel("layer"), MSG);
        JNI.invokePPPV(view, sel("setWantsLayer:"), 1L, MSG);
        JNI.invokePPPV(view, sel("setLayer:"), layer, MSG);
        return layer;
    }
}
