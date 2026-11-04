package fge.teavmfix;

/** Thread.startVirtualThread の付け替え先（Rewrite が呼び出しを向ける）。TeaVM の Thread は緑スレッドなので普通の Thread で足りる。 */
public final class VirtualThreads {
    private VirtualThreads() { }

    public static Thread startVirtualThread(Runnable task) {
        Thread thread = new Thread(task);
        thread.start();
        return thread;
    }
}
