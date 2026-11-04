package org.teavm.classlib.java.util.concurrent;

/** TeaVM 0.14.1 の classlib に無い ConcurrentLinkedQueue（Flix の Region が使う）。ブラウザの wasm は 1 本の糸なので LinkedList で足りる。 */
public class TConcurrentLinkedQueue<E> extends java.util.LinkedList<E> {
    public TConcurrentLinkedQueue() {
        super();
    }
}
