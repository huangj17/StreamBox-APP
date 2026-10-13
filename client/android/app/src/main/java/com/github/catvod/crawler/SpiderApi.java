package com.github.catvod.crawler;

/** Legacy CatVod host callbacks used by Android Spider bundles. */
public interface SpiderApi {
    String getAddress(boolean local);
    String getPort();
    void log(String message);
    String webParse(String url, String headers);
}
