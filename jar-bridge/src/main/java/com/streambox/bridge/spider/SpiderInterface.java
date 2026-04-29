package com.streambox.bridge.spider;

import java.util.HashMap;
import java.util.List;

/**
 * TVBox Spider 兼容接口。
 * JAR 插件的入口类必须实现此接口（或 TVBox 原版 Spider 接口）。
 */
public interface SpiderInterface {

    void init(Object context, String ext);

    String homeContent(boolean filter);

    String homeVideoContent();

    String categoryContent(String tid, String pg, boolean filter,
                           HashMap<String, String> extend);

    String detailContent(List<String> ids);

    String playerContent(String flag, String id, List<String> vipFlags);

    String searchContent(String key, boolean quick);

    default String searchContent(String key, boolean quick, String pg) {
        return searchContent(key, quick);
    }
}
