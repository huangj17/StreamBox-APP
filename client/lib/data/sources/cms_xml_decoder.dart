import 'package:xml/xml.dart';

/// 将苹果 CMS XML 方言转换为客户端内部使用的 JSON 字段结构。
Map<String, dynamic> decodeCmsXml(String source) {
  final document = XmlDocument.parse(source);
  final categories = document.findAllElements('ty').map((element) {
    return <String, dynamic>{
      'type_id': element.getAttribute('id') ?? _childText(element, ['id']),
      'type_name': element.innerText.trim(),
      'type_pid':
          element.getAttribute('pid') ?? element.getAttribute('parent') ?? '0',
    };
  }).toList();

  final videos = document.findAllElements('video').map(_decodeVideo).toList();
  final listElement = _firstElement(document.findAllElements('list'));
  final pageCount =
      listElement?.getAttribute('pagecount') ??
      _documentText(document, ['pagecount']) ??
      '1';
  final total =
      listElement?.getAttribute('recordcount') ??
      listElement?.getAttribute('total') ??
      _documentText(document, ['recordcount', 'total']) ??
      videos.length.toString();

  return <String, dynamic>{
    'class': categories,
    'list': videos,
    'pagecount': pageCount,
    'total': total,
  };
}

Map<String, dynamic> _decodeVideo(XmlElement video) {
  final playLines = video.findAllElements('dd').toList();
  final playFrom = playLines
      .map((line) => line.getAttribute('flag')?.trim() ?? '')
      .join(r'$$$');
  final playUrls = playLines.map((line) => line.innerText.trim()).join(r'$$$');

  String value(List<String> names) => _childText(video, names);

  return <String, dynamic>{
    'vod_id': value(['vod_id', 'id']),
    'vod_name': value(['vod_name', 'name']),
    'vod_pic': value(['vod_pic', 'pic']),
    'vod_year': value(['vod_year', 'year']),
    'vod_class': value(['vod_class', 'type']),
    'vod_remarks': value(['vod_remarks', 'note', 'state']),
    'vod_blurb': value(['vod_blurb', 'des']),
    'vod_content': value(['vod_content', 'des']),
    'vod_area': value(['vod_area', 'area']),
    'vod_lang': value(['vod_lang', 'lang']),
    'vod_director': value(['vod_director', 'director']),
    'vod_actor': value(['vod_actor', 'actor']),
    'vod_score': value(['vod_score', 'score']),
    'vod_douban_score': value(['vod_douban_score', 'db']),
    'vod_play_from': playFrom.isNotEmpty ? playFrom : value(['vod_play_from']),
    'vod_play_url': playUrls.isNotEmpty ? playUrls : value(['vod_play_url']),
    'parse': value(['parse']),
  };
}

String _childText(XmlElement parent, List<String> names) {
  final accepted = names.map((name) => name.toLowerCase()).toSet();
  for (final child in parent.childElements) {
    if (accepted.contains(child.name.local.toLowerCase())) {
      return child.innerText.trim();
    }
  }
  return '';
}

String? _documentText(XmlDocument document, List<String> names) {
  for (final name in names) {
    final element = _firstElement(document.findAllElements(name));
    if (element != null && element.innerText.trim().isNotEmpty) {
      return element.innerText.trim();
    }
  }
  return null;
}

XmlElement? _firstElement(Iterable<XmlElement> elements) {
  final iterator = elements.iterator;
  return iterator.moveNext() ? iterator.current : null;
}
