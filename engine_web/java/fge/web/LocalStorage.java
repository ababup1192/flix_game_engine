package fge.web;

import org.teavm.jso.JSBody;

/** localStorage（同期）。鍵の頭のゲームの id は呼ぶ側が付ける。使えない頁（ストレージを切った表示など）では読むと null・書くと false。 */
public final class LocalStorage {
    private LocalStorage() { }

    /** 鍵の中身。無ければ null。 */
    @JSBody(params = {"key"}, script = "try { return localStorage.getItem(key); } catch (e) { return null; }")
    public static native String get(String key);

    /** 書けたら true。 */
    @JSBody(params = {"key", "value"}, script = "try { localStorage.setItem(key, value); return true; } catch (e) { return false; }")
    public static native boolean set(String key, String value);

    /** 消せたら true（無くても true）。 */
    @JSBody(params = {"key"}, script = "try { localStorage.removeItem(key); return true; } catch (e) { return false; }")
    public static native boolean remove(String key);
}
