package fge.teavmfix;

import java.lang.ref.Reference;

/** Reference.refersTo（Java 16）の付け替え先。TeaVM の classlib には無い。 */
public final class References {
    private References() { }

    public static boolean refersTo(Reference<?> reference, Object target) {
        return reference.get() == target;
    }
}
