package com.streambox.bridge.spider;

import java.util.HashMap;
import java.util.List;

/**
 * 最小测试 Spider，返回硬编码 JSON。
 * 用于端到端验证和集成测试。
 */
public class TestSpider implements SpiderInterface {

    @Override
    public void init(Object context, String ext) {
        // no-op
    }

    @Override
    public String homeContent(boolean filter) {
        return "{\"class\":[{\"type_id\":\"1\",\"type_name\":\"电影\"},{\"type_id\":\"2\",\"type_name\":\"电视剧\"}],\"list\":[{\"vod_id\":\"101\",\"vod_name\":\"测试电影\",\"vod_pic\":\"https://example.com/cover.jpg\",\"vod_remarks\":\"1080P\"}]}";
    }

    @Override
    public String homeVideoContent() {
        return "{\"list\":[{\"vod_id\":\"101\",\"vod_name\":\"测试电影\",\"vod_pic\":\"https://example.com/cover.jpg\",\"vod_remarks\":\"1080P\"}]}";
    }

    @Override
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) {
        return "{\"page\":" + pg + ",\"pagecount\":5,\"total\":50,\"list\":[{\"vod_id\":\"201\",\"vod_name\":\"分类视频" + tid + "\",\"vod_pic\":\"https://example.com/cat.jpg\",\"vod_remarks\":\"HD\"}]}";
    }

    @Override
    public String detailContent(List<String> ids) {
        String id = ids.isEmpty() ? "0" : ids.get(0);
        return "{\"list\":[{\"vod_id\":" + id + ",\"vod_name\":\"测试详情\",\"vod_pic\":\"https://example.com/detail.jpg\",\"vod_content\":\"这是测试简介\",\"vod_play_from\":\"测试线路\",\"vod_play_url\":\"第1集$https://example.com/ep1.m3u8#第2集$https://example.com/ep2.m3u8\",\"vod_year\":\"2024\",\"vod_class\":\"科幻\",\"vod_area\":\"中国\",\"vod_director\":\"导演\",\"vod_actor\":\"演员A,演员B\",\"vod_score\":\"8.5\"}]}";
    }

    @Override
    public String playerContent(String flag, String id, List<String> vipFlags) {
        return "{\"parse\":0,\"url\":\"" + id + "\",\"header\":{\"Referer\":\"https://example.com\"}}";
    }

    @Override
    public String searchContent(String key, boolean quick) {
        return "{\"list\":[{\"vod_id\":\"301\",\"vod_name\":\"搜索结果-" + key + "\",\"vod_pic\":\"https://example.com/search.jpg\",\"vod_remarks\":\"HD\"}]}";
    }
}
