package com.github.catvod.spider;

import android.content.Context;
import com.github.catvod.crawler.Spider;
import java.io.ByteArrayInputStream;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONObject;

/** Controlled test plugin, compiled separately by D8. No internet requests. */
public class FixtureSpider extends Spider {
    private String label;
    @Override public void init(Context context, String ext) throws Exception {
        if (!(context instanceof android.app.Application)) throw new IllegalStateException("Expected the real host Application");
        label = new JSONObject(ext).getString("label");
    }
    @Override public String homeContent(boolean filter) throws Exception {
        return new JSONObject().put("class", new JSONArray().put(
            new JSONObject().put("type_id", label).put("type_name", label))).toString();
    }
    @Override public String categoryContent(String tid, String pg, boolean filter, HashMap<String,String> extend) throws Exception {
        return searchContent(tid, false);
    }
    @Override public String searchContent(String keyword, boolean quick) throws Exception {
        return new JSONObject().put("list", new JSONArray().put(
            new JSONObject().put("vod_id", "episode").put("vod_name", label))).toString();
    }
    @Override public String detailContent(List<String> ids) throws Exception {
        return new JSONObject().put("list", new JSONArray().put(new JSONObject()
            .put("vod_id", ids.get(0)).put("vod_name", label).put("vod_play_from", "HD")
            .put("vod_play_url", "Episode$https://example.com/watch/episode"))).toString();
    }
    @Override public String playerContent(String flag, String id, List<String> flags) throws Exception {
        return new JSONObject().put("parse", 0)
            .put("url", spiderApi.getAddress(true) + "/proxy?do=fixture")
            .put("header", new JSONObject().put("Referer", "https://example.com/")).toString();
    }
    @Override public Object[] proxy(Map<String,String> params) {
        if ("playlist".equals(params.get("do"))) {
            String text = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"http://127.0.0.1:9978/proxy?do=key\"\n#EXTINF:4,\nhttp://127.0.0.1:9978/proxy?do=segment\n#EXTINF:4,\nrelative.ts\n";
            return new Object[]{200, "application/vnd.apple.mpegurl", new ByteArrayInputStream(text.getBytes()),
                Map.of("Content-Length", String.valueOf(text.length()))};
        }
        boolean range = "bytes=0-3".equals(params.get("range"));
        return new Object[]{range ? 206 : 200, "video/mp2t", new ByteArrayInputStream(label.getBytes()),
            Map.of("Content-Length", String.valueOf(label.length()), "Accept-Ranges", "bytes")};
    }
}
