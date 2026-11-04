package org.teavm.classlib.java.util.concurrent;

/** TeaVM 0.14.1 の classlib に無い CyclicBarrier（Flix 標準の Channel が par の中で使う）。TeaVM の緑スレッドのモニタで待つ。 */
public class TCyclicBarrier {
    private final int parties;
    private int waiting;
    private int generation;

    public TCyclicBarrier(int parties) {
        this.parties = parties;
        this.waiting = parties;
    }

    public synchronized int await() throws InterruptedException {
        int index = --waiting;
        if (waiting == 0) {
            generation++;
            waiting = parties;
            notifyAll();
            return 0;
        }
        int seen = generation;
        while (seen == generation) wait();
        return index;
    }
}
