import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import org.lwjgl.system.MemoryUtil;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.Arrays;
import static org.lwjgl.opengl.GL33C.*;

public class GlBench {
    static final String VS = """
        #version 330 core
        uniform mat4 m;
        out vec4 col;
        const vec2 c[6] = vec2[6](vec2(-1,-1), vec2(1,-1), vec2(1,1), vec2(-1,-1), vec2(1,1), vec2(-1,1));
        void main() {
            gl_Position = m * vec4(c[gl_VertexID], 0.0, 1.0);
            col = vec4(m[3].xy * 0.5 + 0.5, 0.5, 1.0);
        }
        """;
    static final String FS = """
        #version 330 core
        in vec4 col; out vec4 o;
        void main() { o = col; }
        """;

    static int prog() {
        int vs = glCreateShader(GL_VERTEX_SHADER); glShaderSource(vs, VS); glCompileShader(vs);
        if (glGetShaderi(vs, GL_COMPILE_STATUS) == 0) throw new RuntimeException(glGetShaderInfoLog(vs));
        int fs = glCreateShader(GL_FRAGMENT_SHADER); glShaderSource(fs, FS); glCompileShader(fs);
        if (glGetShaderi(fs, GL_COMPILE_STATUS) == 0) throw new RuntimeException(glGetShaderInfoLog(fs));
        int p = glCreateProgram(); glAttachShader(p, vs); glAttachShader(p, fs); glLinkProgram(p);
        if (glGetProgrami(p, GL_LINK_STATUS) == 0) throw new RuntimeException(glGetProgramInfoLog(p));
        return p;
    }

    public static void run(int[] Ns) {
        if (!GLFW.glfwInit()) throw new IllegalStateException();
        GLFW.glfwDefaultWindowHints();
        GLFW.glfwWindowHint(GLFW.GLFW_VISIBLE, GLFW.GLFW_FALSE);
        GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR, 3);
        GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR, 3);
        GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE, GLFW.GLFW_OPENGL_CORE_PROFILE);
        GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_FORWARD_COMPAT, GLFW.GLFW_TRUE);
        long win = GLFW.glfwCreateWindow(64, 64, "gl", 0, 0);
        GLFW.glfwMakeContextCurrent(win);
        GLFW.glfwSwapInterval(0);
        GL.createCapabilities();
        System.out.println("GL_RENDERER=" + glGetString(GL_RENDERER) + " GL_VERSION=" + glGetString(GL_VERSION));
        int W = Bench.TARGET;
        int tex = glGenTextures(); glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, W, 0, GL_RGBA, GL_UNSIGNED_BYTE, (ByteBuffer) null);
        int fbo = glGenFramebuffers(); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
        int vao = glGenVertexArrays(); glBindVertexArray(vao);
        int p = prog(); glUseProgram(p);
        int loc = glGetUniformLocation(p, "m");
        glViewport(0, 0, W, W);
        for (int N : Ns) {
            ByteBuffer bb = ByteBuffer.allocateDirect(N * 64).order(ByteOrder.LITTLE_ENDIAN);
            FloatBuffer fb = bb.asFloatBuffer();
            long base = MemoryUtil.memAddress(bb);
            int warm = 40, meas = 100;
            double[] cpu = new double[meas], tot = new double[meas];
            for (int f = 0; f < warm + meas; f++) {
                Bench.fill(fb, N, 16, f);
                long t0 = System.nanoTime();
                glClearColor(0.05f, 0.05f, 0.08f, 1f); glClear(GL_COLOR_BUFFER_BIT);
                for (int k = 0; k < N; k++) {
                    nglUniformMatrix4fv(loc, 1, false, base + (long) k * 64);
                    glDrawArrays(GL_TRIANGLES, 0, 6);
                }
                glFlush();
                long t1 = System.nanoTime();
                glFinish();
                long t2 = System.nanoTime();
                if (f >= warm) { cpu[f - warm] = (t1 - t0) / 1e6; tot[f - warm] = (t2 - t0) / 1e6; }
            }
            double[] s1 = cpu.clone(); Arrays.sort(s1);
            System.out.printf("RESULT gl/OpenGL3.3 N=%d cpu_submit_ms median=%.3f p90=%.3f | with_gpu_wait median=%.3f | us/object(cpu)=%.3f%n",
                N, Bench.median(cpu), s1[meas * 9 / 10], Bench.median(tot), Bench.median(cpu) * 1000 / N);
        }
        GLFW.glfwDestroyWindow(win); GLFW.glfwTerminate();
        System.exit(0);
    }
}
