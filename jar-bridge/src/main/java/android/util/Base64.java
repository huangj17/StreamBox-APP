package android.util;

/**
 * 桥接 android.util.Base64 → java.util.Base64。
 */
public class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_WRAP = 2;
    public static final int NO_PADDING = 1;
    public static final int URL_SAFE = 8;

    public static byte[] decode(String str, int flags) {
        if (str == null) return new byte[0];
        try {
            String cleaned = str.replaceAll("[\\r\\n\\s]", "");
            if ((flags & URL_SAFE) != 0) {
                return java.util.Base64.getUrlDecoder().decode(cleaned);
            }
            return java.util.Base64.getDecoder().decode(cleaned);
        } catch (Exception e) {
            return new byte[0];
        }
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(new String(input), flags);
    }

    public static String encodeToString(byte[] input, int flags) {
        if (input == null) return "";
        java.util.Base64.Encoder encoder;
        if ((flags & URL_SAFE) != 0) {
            encoder = java.util.Base64.getUrlEncoder();
        } else {
            encoder = java.util.Base64.getEncoder();
        }
        if ((flags & NO_WRAP) != 0 || (flags & NO_PADDING) != 0) {
            encoder = encoder.withoutPadding();
        }
        return encoder.encodeToString(input);
    }

    public static byte[] encode(byte[] input, int flags) {
        return encodeToString(input, flags).getBytes();
    }
}
