package org.teavm.classlib.java.util.concurrent.locks;

/** TeaVM 0.14.1 の classlib に無い Condition（TReentrantLock が作る）。 */
public interface TCondition {
    void await() throws InterruptedException;

    long awaitNanos(long nanos) throws InterruptedException;

    void signal();

    void signalAll();
}
