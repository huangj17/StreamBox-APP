package com.github.catvod.crawler;
import android.util.Log;

public final class SpiderDebug {
    public static void log(String message) { if (message != null) Log.d("Spider", message); }
    public static void log(Throwable error) { if (error != null) Log.e("Spider", "Plugin error", error); }
    public static void log(String tag, String message, Object... args) {
        if (message != null) Log.d(tag, args.length == 0 ? message : String.format(message, args));
    }
}
