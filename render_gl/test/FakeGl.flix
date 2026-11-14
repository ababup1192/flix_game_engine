// 2D の塗りのテストが使う、何も描かない GL。呼び出しを控える版は 3D のテストの Render3d.FakeGl。
pub mod FakeGl {
    import fge.gl.GlContext
    import fge.gl.GlConst
    import fge.gl.RecordingGl
    import java.lang.Boolean
    import java.lang.Integer
    import java.lang.Object
    import java.lang.reflect.InvocationHandler
    import java.lang.reflect.Method
    import java.lang.reflect.Proxy
    import java.nio.FloatBuffer
    import java.nio.IntBuffer

    /// 頭の引数（入れ物の長さ）。
    def intArg(args: Array[Object, Static]): Int32 \ IO =
        (unchecked_cast(Array.get(0, args) as Integer)).intValue()

    /// 何も描かない GL。FBO の検査は完成、数は 1、Bool は偽、float と int の入れ物は頼まれた長さで返す。
    pub def silent(): GlContext \ IO =
        let answers = new InvocationHandler {
            def invoke(_this: InvocationHandler, _proxy: Object, method: Method, args: Array[Object, Static]): Object \ IO =
                let name = method.getName();
                match method.getReturnType().getName() {
                    case "int" if name == "checkFramebufferStatus" => checked_cast(Integer.valueOf(GlConst.FRAMEBUFFER_COMPLETE))
                    case "int"                  => checked_cast(Integer.valueOf(1))
                    case "boolean"              => checked_cast(Boolean.valueOf(false))
                    case "java.nio.FloatBuffer" => checked_cast(FloatBuffer.allocate(intArg(args)))
                    case "java.nio.IntBuffer"   => checked_cast(IntBuffer.allocate(Int32.max(1, intArg(args))))
                    case _                      => checked_cast(null)
                }
        };
        let recording = (new RecordingGl(unchecked_cast(null as GlContext))).getClass();
        unchecked_cast(Proxy.newProxyInstance(recording.getClassLoader(), recording.getInterfaces(), answers) as GlContext)
}
