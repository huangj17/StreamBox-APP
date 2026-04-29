package com.github.catvod.crawler;

import android.content.Context;

import java.util.HashMap;
import java.util.List;

/**
 * TVBox Spider 基类。
 * JAR 插件中的 Spider 类继承此类。
 * Bridge 提供此基类让 JAR 插件能正常加载。
 */
public abstract class Spider {

    public void init(Context context, String ext) throws Exception {
    }

    public String homeContent(boolean filter) throws Exception {
        return "";
    }

    public String homeVideoContent() throws Exception {
        return "";
    }

    public String categoryContent(String tid, String pg, boolean filter,
                                   HashMap<String, String> extend) throws Exception {
        return "";
    }

    public String detailContent(List<String> ids) throws Exception {
        return "";
    }

    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
        return "";
    }

    public String searchContent(String key, boolean quick) throws Exception {
        return "";
    }

    public String searchContent(String key, boolean quick, String pg) throws Exception {
        return searchContent(key, quick);
    }

    /**
     * 释放资源（部分插件实现）。
     */
    public void destroy() {
    }
}
