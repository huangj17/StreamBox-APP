package android.util;

import org.slf4j.LoggerFactory;

/**
 * 桥接 android.util.Log → SLF4J。
 */
public class Log {
    private static final org.slf4j.Logger logger = LoggerFactory.getLogger("Spider");

    public static int v(String tag, String msg) {
        logger.trace("[{}] {}", tag, msg);
        return 0;
    }

    public static int d(String tag, String msg) {
        logger.debug("[{}] {}", tag, msg);
        return 0;
    }

    public static int i(String tag, String msg) {
        logger.info("[{}] {}", tag, msg);
        return 0;
    }

    public static int w(String tag, String msg) {
        logger.warn("[{}] {}", tag, msg);
        return 0;
    }

    public static int e(String tag, String msg) {
        logger.error("[{}] {}", tag, msg);
        return 0;
    }

    public static int e(String tag, String msg, Throwable tr) {
        logger.error("[{}] {}", tag, msg, tr);
        return 0;
    }
}
