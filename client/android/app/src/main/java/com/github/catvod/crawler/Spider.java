package com.github.catvod.crawler;

import android.content.Context;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import okhttp3.Dns;
import okhttp3.OkHttpClient;

/** Binary contract shared with Android CatVod plugins. */
public abstract class Spider {
    public String siteKey;
    private String token = "";
    protected SpiderApi spiderApi;
    private static final OkHttpClient CLIENT = new OkHttpClient();
    public static Dns safeDns() { return Dns.SYSTEM; }
    public static OkHttpClient client() { return CLIENT; }
    public String getToken() { return token; }
    public void setToken(String token) { this.token = token; }
    public void initApi(SpiderApi api) { this.spiderApi = api; }
    public void init(Context context) throws Exception {}
    public void init(Context context, String ext) throws Exception { init(context); }
    public String homeContent(boolean filter) throws Exception { return "{}"; }
    public String homeVideoContent() throws Exception { return "{\"list\":[]}"; }
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception { return "{}"; }
    public String detailContent(List<String> ids) throws Exception { return "{\"list\":[]}"; }
    public String searchContent(String key, boolean quick) throws Exception { return "{\"list\":[]}"; }
    public String searchContent(String key, boolean quick, String pg) throws Exception { return searchContent(key, quick); }
    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception { return "{}"; }
    public String liveContent(String url) throws Exception { return ""; }
    public boolean manualVideoCheck() throws Exception { return false; }
    public boolean isVideoFormat(String url) throws Exception { return false; }
    public Object[] proxy(Map<String, String> params) throws Exception { return null; }
    public String action(String action) throws Exception { return null; }
    public void destroy() {}
}
