import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/data/models/category.dart';
import 'package:streambox/data/models/site.dart';
import 'package:streambox/data/models/video_list_result.dart';
import 'package:streambox/data/sources/cms_api.dart';

void main() {
  const xmlSite = Site(
    key: 'xml',
    name: 'XML CMS',
    type: 0,
    api: 'https://cms.example/api.php',
  );

  test('CMS API decodes XML classes, lists and details', () async {
    final dio = Dio()..httpClientAdapter = _CmsXmlAdapter();
    final api = CmsApi(dio);

    final categories = await api.fetchCategories(xmlSite);
    expect(categories.single.id, '1');
    expect(categories.single.name, '电影');

    final page = await api.fetchVideoList(
      site: xmlSite,
      categoryId: '1',
      page: 2,
    );
    expect(page.total, 21);
    expect(page.pageCount, 3);
    expect(page.items.single.title, '测试影片');
    expect(page.items.single.year, '2026');

    final detail = await api.fetchVideoDetail(site: xmlSite, videoId: '7');
    expect(detail, isNotNull);
    expect(detail!.vodName, '测试影片');
    expect(detail.vodContent, '简介内容');
    expect(detail.sourceNames.single, contains('1080P'));
    expect(
      detail.episodeGroups.single.single.url,
      'http://media.example/1.m3u8',
    );
  });

  test('CMS JSON coercion accepts numeric strings and scalar text fields', () {
    final category = Category.fromJson({
      'type_id': 8,
      'type_name': 2026,
      'type_pid': '7',
    }, siteKey: 'site');
    final page = VideoListResult.fromJson({
      'total': '12',
      'pagecount': '3',
      'list': [
        {'vod_id': 1, 'vod_name': 2026, 'vod_pic': 123, 'vod_year': 2026},
      ],
    }, siteKey: 'site');

    expect(category.name, '2026');
    expect(category.typePid, 7);
    expect(page.total, 12);
    expect(page.pageCount, 3);
    expect(page.items.single.title, '2026');
    expect(page.items.single.year, '2026');
  });
}

class _CmsXmlAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = options.uri.queryParameters['ac'] == 'class'
        ? _classesXml
        : options.uri.queryParameters.containsKey('ids')
        ? _detailXml
        : _listXml;
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _classesXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="5.1"><class><ty id="1">电影</ty></class></rss>
''';

const _listXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="5.1"><list page="2" pagecount="3" recordcount="21">
  <video><id>7</id><name>测试影片</name><pic>https://img.example/7.jpg</pic>
  <year>2026</year><type>剧情</type><note>更新</note></video>
</list></rss>
''';

const _detailXml = r'''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="5.1"><list page="1" pagecount="1" recordcount="1">
  <video><id>7</id><name>测试影片</name><pic>https://img.example/7.jpg</pic>
  <des><![CDATA[简介<br>内容]]></des><year>2026</year>
  <dl><dd flag="1080P"><![CDATA[第1集$http://media.example/1.m3u8]]></dd></dl>
  </video>
</list></rss>
''';
