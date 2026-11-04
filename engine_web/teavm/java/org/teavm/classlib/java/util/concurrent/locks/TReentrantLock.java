package org.teavm.classlib.java.util.concurrent.locks;

/**
 * TeaVM 0.14.1 の classlib に無い ReentrantLock（Flix 標準の Channel が par の中で使う）。
 * ブラウザの wasm は 1 本の糸の上の緑スレッドなので、モニタの wait と notify で足りる。
 */
public class TReentrantLock {
    final Object monitor = new Object();
    Thread owner;
    int holds;

    public TReentrantLock() { }

    public TReentrantLock(boolean fair) { }

    public void lock() {
        Thread current = Thread.currentThread();
        synchronized (monitor) {
            while (owner != null && owner != current) {
                try {
                    monitor.wait();
                } catch (InterruptedException e) {
                    // 割り込みは使わない（緑スレッドの間で起きない）
                }
            }
            owner = current;
            holds++;
        }
    }

    public void lockInterruptibly() throws InterruptedException {
        lock();
    }

    public boolean tryLock() {
        Thread current = Thread.currentThread();
        synchronized (monitor) {
            if (owner != null && owner != current) return false;
            owner = current;
            holds++;
            return true;
        }
    }

    public void unlock() {
        synchronized (monitor) {
            if (owner != Thread.currentThread()) throw new IllegalMonitorStateException();
            if (--holds == 0) {
                owner = null;
                monitor.notifyAll();
            }
        }
    }

    int releaseAll() {
        synchronized (monitor) {
            int held = holds;
            holds = 0;
            owner = null;
            monitor.notifyAll();
            return held;
        }
    }

    void reacquire(int held) {
        Thread current = Thread.currentThread();
        synchronized (monitor) {
            while (owner != null && owner != current) {
                try {
                    monitor.wait();
                } catch (InterruptedException e) {
                    // 割り込みは使わない（緑スレッドの間で起きない）
                }
            }
            owner = current;
            holds = held;
        }
    }

    public TCondition newCondition() {
        final TReentrantLock lock = this;
        return new TCondition() {
            final Object conditionMonitor = new Object();
            int generation;

            public void await() throws InterruptedException {
                int seen;
                synchronized (conditionMonitor) {
                    seen = generation;
                }
                int held = lock.releaseAll();
                synchronized (conditionMonitor) {
                    while (seen == generation) conditionMonitor.wait();
                }
                lock.reacquire(held);
            }

            public long awaitNanos(long nanos) throws InterruptedException {
                await();
                return 0;
            }

            public void signal() {
                synchronized (conditionMonitor) {
                    generation++;
                    conditionMonitor.notifyAll();
                }
            }

            public void signalAll() {
                signal();
            }
        };
    }
}
