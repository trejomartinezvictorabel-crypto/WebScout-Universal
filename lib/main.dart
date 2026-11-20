// WebScout Universal — Buscador, Vista Dinámica y Gestor Ligero Blindado.
// Pensado para Samsung Galaxy A06 / Android 16 (edge-to-edge, SAF, MediaStore).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:webview_flutter/webview_flutter.dart';

import 'parental/parental.dart';

// ============================================================================
// CONSTANTES
// ============================================================================

/// Tope duro de elementos simultáneos en RAM (resultados + miniaturas + enlaces).
const int kMaxItems = 12;

/// Umbral de advertencia para GeoJSON pesado en móvil.
const int kGeoWarnBytes = 150 * 1024 * 1024;
const int kGeoStrongBytes = 200 * 1024 * 1024;

/// Máximo de bytes de un GeoJSON para el chequeo de balanceo en streaming.
const int kGeoDepthMaxBytes = 400 * 1024 * 1024;

/// Perfil neutro: UA genérico, sin Accept-Language, sin cookies persistentes.
const String kUA =
    'Mozilla/5.0 (Linux; Android 16; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

const Color kBlack = Color(0xFF000000);
const Color kWhite = Color(0xFFFFFFFF);
const Color kPanel = Color(0xFF0D0D0D);
const Color kLine = Color(0x3DFFFFFF);
const Color kDim = Color(0xB3FFFFFF);
const Color kOk = Color(0xFF4ADE80);
const Color kWarn = Color(0xFFFBBF24);
const Color kBad = Color(0xFFF87171);

const List<String> kMultiExt = ['osm.pbf', 'tar.gz', 'tar.xz', 'tar.bz2'];

const Set<String> kFileExts = {
  'mbtiles', 'geojson', 'osm.pbf', 'pbf', 'pdf', 'mp4', 'mkv', 'webm', 'mp3',
  'zip', 'tar.gz', 'tar.xz', 'tar.bz2', 'tgz', 'gz', '7z', 'rar', 'apk', 'apks',
  'xapk', 'epub', 'docx', 'xlsx', 'pptx', 'csv', 'json', 'gpkg', 'kml', 'gpx',
  'shp', 'mov', 'avi', 'flac', 'ogg', 'wav', 'm4a', 'exe', 'msi', 'dmg', 'iso',
  'jar', 'xz', 'bz2', 'tif', 'tiff', 'txt', 'md',
};

/// Tipos ejecutables/instalables: exigen doble confirmación antes de guardarse.
const Set<String> kRisky = {
  'apk', 'apks', 'xapk', 'exe', 'msi', 'dmg', 'jar', 'bat', 'cmd', 'sh', 'scr', 'dex',
};

const List<String> kPriorityExts = ['mbtiles', 'geojson', 'osm.pbf', 'pbf'];

String? extOfPath(String path) {
  final p = path.toLowerCase();
  for (final m in kMultiExt) {
    if (p.endsWith('.$m')) return m;
  }
  final i = p.lastIndexOf('.');
  if (i < 0 || i < p.lastIndexOf('/')) return null;
  final e = p.substring(i + 1);
  return kFileExts.contains(e) ? e : null;
}

String mimeFor(String ext) {
  switch (ext) {
    case 'pdf':
      return 'application/pdf';
    case 'mp4':
      return 'video/mp4';
    case 'mkv':
      return 'video/x-matroska';
    case 'webm':
      return 'video/webm';
    case 'mp3':
      return 'audio/mpeg';
    case 'zip':
      return 'application/zip';
    case 'apk':
      return 'application/vnd.android.package-archive';
    case 'epub':
      return 'application/epub+zip';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'csv':
      return 'text/csv';
    case 'txt':
      return 'text/plain';
    case 'md':
      return 'text/markdown';
    case 'geojson':
      return 'application/geo+json';
    case 'json':
      return 'application/json';
    default:
      return 'application/octet-stream';
  }
}

String fmtBytes(num b) {
  if (b < 1024) return '${b.toInt()} B';
  const u = ['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024.0;
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${u[i]}';
}

// ============================================================================
// MODELOS
// ============================================================================

enum Level { info, ok, warn, danger }

class Finding {
  final Level level;
  final String title;
  final String detail;
  const Finding(this.level, this.title, [this.detail = '']);
}

Level worst(Iterable<Finding> fs) {
  var w = Level.ok;
  for (final f in fs) {
    if (f.level.index > w.index) w = f.level;
  }
  return w;
}

String verdictLabel(Level l) =>
    l == Level.danger ? 'ALERTA' : (l == Level.warn ? 'PRECAUCIÓN' : 'SIN ALERTAS');

Color levelColor(Level l) {
  switch (l) {
    case Level.danger:
      return kBad;
    case Level.warn:
      return kWarn;
    case Level.ok:
      return kOk;
    case Level.info:
      return kDim;
  }
}

IconData levelIcon(Level l) {
  switch (l) {
    case Level.danger:
      return Icons.dangerous_outlined;
    case Level.warn:
      return Icons.warning_amber_rounded;
    case Level.ok:
      return Icons.check_circle_outline;
    case Level.info:
      return Icons.info_outline;
  }
}

class SearchItem {
  final String title;
  final String url;
  final String snippet;
  final String? ext;
  const SearchItem(this.title, this.url, this.snippet, this.ext);
  String get host {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return '';
    }
  }
}

class ImageItem {
  final String title;
  final String thumb;
  final String full;
  const ImageItem(this.title, this.thumb, this.full);
}

class LinkItem {
  final String url;
  final String label;
  final String ext;
  const LinkItem(this.url, this.label, this.ext);
}

class DynTool {
  final String title;
  final String html;
  const DynTool(this.title, this.html);
}

class ChipDef {
  final String key;
  final String label;
  final List<String> exts;
  final String terms;
  const ChipDef(this.key, this.label, this.exts, this.terms);
}

const List<ChipDef> kChips = [
  ChipDef('all', 'Todo', [], ''),
  ChipDef('img', 'Imágenes', [], ''),
  ChipDef('mbtiles', '.mbtiles', ['mbtiles'], 'mbtiles vector tiles pbf download'),
  ChipDef('geojson', '.geojson', ['geojson'], 'geojson roads network download'),
  ChipDef('osmpbf', '.osm.pbf', ['osm.pbf', 'pbf'], 'osm.pbf extract download'),
  ChipDef('graph', 'Grafos', ['zip', 'tar.gz'], 'graphhopper OR osrm OR valhalla routing graph download'),
  ChipDef('pdf', '.pdf', ['pdf'], 'pdf download'),
  ChipDef('video', 'Video', ['mp4', 'mkv', 'webm'], 'mp4 OR mkv OR webm download'),
  ChipDef('audio', 'Audio', ['mp3'], 'mp3 download'),
  ChipDef('zip', '.zip', ['zip'], 'zip download'),
  ChipDef('apk', '.apk', ['apk'], 'apk download'),
  ChipDef('epub', '.epub', ['epub'], 'epub download'),
  ChipDef('docx', '.docx', ['docx'], 'docx download'),
  ChipDef('csv', '.csv', ['csv'], 'csv dataset download'),
];

ChipDef? detectChip(String raw) {
  final q = raw.toLowerCase();
  ChipDef byKey(String k) => kChips.firstWhere((c) => c.key == k);
  if (q.contains('osm.pbf')) return byKey('osmpbf');
  if (q.contains('graphhopper') || q.contains('osrm') || q.contains('valhalla') || q.contains('grafo')) {
    return byKey('graph');
  }
  if (q.contains('mbtiles') || q.contains('pbf') || q.contains('mvt') || q.contains('teselas')) {
    return byKey('mbtiles');
  }
  if (q.contains('geojson') || q.contains('red vial') || q.contains('routing') || q.contains('enrutamiento')) {
    return byKey('geojson');
  }
  final m = RegExp(r'(?:filetype:|\.)([a-z0-9]{2,6})\b').firstMatch(q);
  if (m != null) {
    final e = m.group(1)!;
    for (final c in kChips) {
      if (c.exts.contains(e)) return c;
    }
  }
  return null;
}

// ============================================================================
// RED (perfil neutro: sin cookies, sin Accept-Language, redirecciones manuales)
// ============================================================================

class NetResp {
  final Uri finalUri;
  final int status;
  final String contentType;
  final Uint8List bytes;
  final bool truncated;
  final List<Uri> chain;
  NetResp(this.finalUri, this.status, this.contentType, this.bytes, this.truncated, this.chain);
  String get text => utf8.decode(bytes, allowMalformed: true);
}

class HeadInfo {
  final Uri finalUri;
  final List<Uri> chain;
  final int status;
  final int? length;
  final String? contentType;
  final bool acceptRanges;
  final String? disposition;
  HeadInfo(this.finalUri, this.chain, this.status, this.length, this.contentType, this.acceptRanges, this.disposition);
}

class Net {
  static HttpClient _client() {
    final c = HttpClient();
    c.userAgent = kUA;
    c.connectionTimeout = const Duration(seconds: 12);
    c.idleTimeout = const Duration(seconds: 3);
    return c;
  }

  static Future<(HttpClientResponse, List<Uri>)> _follow(
    HttpClient c,
    String method,
    Uri start, {
    Map<String, String>? headers,
    int maxRedirects = 6,
  }) async {
    var uri = start;
    final chain = <Uri>[start];
    for (var i = 0; i <= maxRedirects; i++) {
      final req = await c.openUrl(method, uri);
      req.followRedirects = false;
      headers?.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close().timeout(const Duration(seconds: 25));
      final code = res.statusCode;
      final loc = res.headers.value('location');
      if (code >= 300 && code < 400 && loc != null) {
        await res.drain<void>();
        uri = uri.resolve(loc);
        chain.add(uri);
        continue;
      }
      return (res, chain);
    }
    throw const HttpException('Demasiadas redirecciones');
  }

  static Future<NetResp> getBytes(
    Uri uri, {
    int maxBytes = 2 * 1024 * 1024,
    Map<String, String>? headers,
  }) async {
    final c = _client();
    try {
      final (res, chain) = await _follow(c, 'GET', uri, headers: headers);
      final b = BytesBuilder(copy: false);
      var truncated = false;
      await for (final chunk in res.timeout(const Duration(seconds: 25))) {
        b.add(chunk);
        if (b.length >= maxBytes) {
          truncated = true;
          break;
        }
      }
      return NetResp(
        chain.last,
        res.statusCode,
        (res.headers.contentType?.mimeType ?? '').toLowerCase(),
        b.takeBytes(),
        truncated,
        chain,
      );
    } finally {
      c.close(force: true);
    }
  }

  static HeadInfo _headFrom(HttpClientResponse res, List<Uri> chain) {
    final h = res.headers;
    int? len;
    if (res.statusCode == 206) {
      final cr = h.value('content-range');
      if (cr != null && cr.contains('/')) len = int.tryParse(cr.split('/').last.trim());
    } else {
      len = int.tryParse(h.value('content-length') ?? '');
    }
    final ar = (h.value('accept-ranges') ?? '').toLowerCase().contains('bytes') || res.statusCode == 206;
    return HeadInfo(
      chain.last,
      chain,
      res.statusCode,
      len,
      h.contentType?.mimeType.toLowerCase(),
      ar,
      h.value('content-disposition'),
    );
  }

  /// HEAD con reintento por GET Range 0-0 si el servidor no admite HEAD.
  static Future<HeadInfo> head(Uri uri) async {
    final c = _client();
    try {
      try {
        final (res, chain) = await _follow(c, 'HEAD', uri, headers: {'Accept-Encoding': 'identity'});
        await res.drain<void>();
        if (res.statusCode >= 200 && res.statusCode < 300) return _headFrom(res, chain);
      } catch (_) {}
      final (res2, chain2) = await _follow(
        c,
        'GET',
        uri,
        headers: {'Range': 'bytes=0-0', 'Accept-Encoding': 'identity'},
      );
      final info = _headFrom(res2, chain2);
      await res2.listen((_) {}).cancel();
      return info;
    } finally {
      c.close(force: true);
    }
  }

  /// Lee solo un rango de bytes (no descarga el archivo completo).
  static Future<Uint8List> rangeBytes(Uri uri, int start, int endInclusive) async {
    final c = _client();
    try {
      final (res, _) = await _follow(
        c,
        'GET',
        uri,
        headers: {'Range': 'bytes=$start-$endInclusive', 'Accept-Encoding': 'identity'},
      );
      if (res.statusCode != 206 && res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      if (res.statusCode == 200 && start > 0) {
        await res.listen((_) {}).cancel();
        throw const HttpException('El servidor ignoró Range');
      }
      final want = endInclusive - start + 1;
      final b = BytesBuilder(copy: false);
      await for (final chunk in res) {
        b.add(chunk);
        if (b.length >= want) break;
      }
      var out = b.takeBytes();
      if (out.length > want) out = Uint8List.sublistView(out, 0, want);
      return out;
    } finally {
      c.close(force: true);
    }
  }

  static Future<Map<String, dynamic>?> dohJson(String endpoint, String name) async {
    final uri = Uri.parse(endpoint).replace(queryParameters: {'name': name, 'type': 'A'});
    final r = await getBytes(uri, maxBytes: 64 * 1024, headers: {'Accept': 'application/dns-json'});
    if (r.status != 200) return null;
    return jsonDecode(r.text) as Map<String, dynamic>;
  }
}

// ============================================================================
// BÚSQUEDA (DuckDuckGo HTML sin región, Wikipedia de respaldo, Commons imágenes)
// ============================================================================

class SearchService {
  static Future<List<SearchItem>> wikipedia(String q, int limit) => _wiki(q, limit);

  /// kp: SafeSearch de DuckDuckGo (1 = estricto, -2 = desactivado, null = predeterminado).
  static Future<List<SearchItem>> web(String q, {int limit = kMaxItems, String? kp}) async {
    try {
      final uri = Uri.https('html.duckduckgo.com', '/html/', {'q': q, 'kl': 'wt-wt', if (kp != null) 'kp': kp});
      final r = await Net.getBytes(uri, maxBytes: 1500000);
      if (r.status == 200) {
        final items = _parseDdg(r.text, limit);
        if (items.isNotEmpty) return items;
      }
    } catch (_) {}
    return _wiki(q, limit);
  }

  static List<SearchItem> _parseDdg(String body, int limit) {
    final doc = html_parser.parse(body);
    final out = <SearchItem>[];
    final seen = <String>{};
    for (final r in doc.querySelectorAll('div.result')) {
      if (r.classes.contains('result--ad')) continue;
      final a = r.querySelector('a.result__a');
      if (a == null) continue;
      final url = _decodeDdg(a.attributes['href'] ?? '');
      if (url.isEmpty || !url.startsWith('http') || url.contains('duckduckgo.com/y.js')) continue;
      if (!seen.add(url)) continue;
      final title = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      final snip = (r.querySelector('.result__snippet')?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
      String? ext;
      try {
        ext = extOfPath(Uri.parse(url).path);
      } catch (_) {}
      out.add(SearchItem(title.isEmpty ? url : title, url, snip, ext));
      if (out.length >= limit) break;
    }
    return out;
  }

  static String _decodeDdg(String href) {
    var h = href;
    if (h.startsWith('//')) h = 'https:$h';
    try {
      final u = Uri.parse(h);
      if (u.host.contains('duckduckgo.com') && u.path.startsWith('/l/')) {
        return u.queryParameters['uddg'] ?? '';
      }
    } catch (_) {}
    return h;
  }

  static Future<List<SearchItem>> _wiki(String q, int limit) async {
    final uri = Uri.https('en.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'list': 'search',
      'srsearch': q,
      'srlimit': '$limit',
      'format': 'json',
      'utf8': '1',
    });
    final r = await Net.getBytes(uri, maxBytes: 600000);
    if (r.status != 200) return [];
    final j = jsonDecode(r.text) as Map<String, dynamic>;
    final list = ((j['query'] as Map?)?['search'] as List?) ?? [];
    final out = <SearchItem>[];
    for (final e in list) {
      final m = e as Map;
      final snip = (m['snippet']?.toString() ?? '').replaceAll(RegExp(r'<[^>]*>'), '').replaceAll('&quot;', '"');
      out.add(SearchItem(m['title'].toString(), 'https://en.wikipedia.org/?curid=${m['pageid']}', snip, null));
    }
    return out;
  }

  static Future<List<ImageItem>> images(String q, int limit) async {
    final uri = Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'generator': 'search',
      'gsrnamespace': '6',
      'gsrsearch': q,
      'gsrlimit': '${limit + 4}',
      'prop': 'imageinfo',
      'iiprop': 'url|mime',
      'iiurlwidth': '250',
      'format': 'json',
      'formatversion': '2',
    });
    final r = await Net.getBytes(uri, maxBytes: 800000);
    if (r.status != 200) return [];
    final j = jsonDecode(r.text) as Map<String, dynamic>;
    final pages = ((j['query'] as Map?)?['pages'] as List?) ?? [];
    final sorted = pages.cast<Map>().toList()
      ..sort((a, b) => ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0));
    final out = <ImageItem>[];
    for (final p in sorted) {
      final ii = (p['imageinfo'] as List?)?.first as Map?;
      if (ii == null) continue;
      final mime = (ii['mime'] ?? '').toString();
      if (!mime.startsWith('image/')) continue;
      final thumb = (ii['thumburl'] ?? ii['url'] ?? '').toString();
      final full = (ii['url'] ?? '').toString();
      if (thumb.isEmpty || full.isEmpty) continue;
      out.add(ImageItem(p['title'].toString().replaceFirst('File:', ''), thumb, full));
      if (out.length >= limit) break;
    }
    return out;
  }
}

// ============================================================================
// RESUMEN DE TEXTO + EXTRACCIÓN DE PÁGINAS (Rayos X)
// ============================================================================

class Summarizer {
  static const Set<String> _stop = {
    'the', 'and', 'for', 'that', 'with', 'this', 'are', 'was', 'were', 'from', 'have', 'has', 'not',
    'but', 'you', 'your', 'can', 'will', 'all', 'its', 'their', 'there', 'which', 'when', 'what',
    'los', 'las', 'del', 'que', 'con', 'para', 'por', 'una', 'uno', 'unos', 'unas', 'como', 'más',
    'pero', 'sus', 'este', 'esta', 'estos', 'estas', 'ese', 'esa', 'son', 'fue', 'ser', 'hay', 'muy',
    'también', 'entre', 'sobre', 'sin', 'desde', 'hasta', 'cuando', 'donde', 'donde', 'porque',
  };

  static String summarize(String text, {int maxSentences = 5, int maxChars = 900}) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxChars) return clean;
    final sentences = clean
        .split(RegExp(r'(?<=[.!?])\s+'))
        .where((s) => s.length >= 40 && s.length <= 400)
        .take(120)
        .toList();
    if (sentences.isEmpty) return '${clean.substring(0, maxChars)}…';
    if (sentences.length <= maxSentences) return _cut(sentences.join(' '), maxChars);
    final wordRe = RegExp(r'[\p{L}\p{N}]{3,}', unicode: true);
    final freq = <String, int>{};
    for (final s in sentences) {
      for (final m in wordRe.allMatches(s.toLowerCase())) {
        final w = m.group(0)!;
        if (_stop.contains(w)) continue;
        freq[w] = (freq[w] ?? 0) + 1;
      }
    }
    final scored = <MapEntry<int, double>>[];
    for (var i = 0; i < sentences.length; i++) {
      final words = wordRe.allMatches(sentences[i].toLowerCase()).map((m) => m.group(0)!).where((w) => !_stop.contains(w)).toList();
      if (words.isEmpty) continue;
      var sc = 0.0;
      for (final w in words) {
        sc += (freq[w] ?? 0);
      }
      sc = sc / math.pow(words.length, 0.7) + (i == 0 ? 2 : 0);
      scored.add(MapEntry(i, sc));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    final pick = scored.take(maxSentences).map((e) => e.key).toList()..sort();
    return _cut(pick.map((i) => sentences[i]).join(' '), maxChars);
  }

  static String _cut(String s, int max) => s.length <= max ? s : '${s.substring(0, max).trimRight()}…';
}

class PageData {
  final String title;
  final String text;
  final List<LinkItem> links;
  PageData(this.title, this.text, this.links);
}

class PageExtractor {
  static final RegExp _adRe = RegExp(
    r'(^|[-_ ])(ads?|advert\w*|banner|cookie\w*|promo\w*|sponsor\w*|popup|modal|newsletter|subscribe)([-_ ]|$)',
    caseSensitive: false,
  );

  static PageData extract(String htmlText, Uri base) {
    final doc = html_parser.parse(htmlText);
    final title = (doc.querySelector('title')?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

    // 1) Enlaces descargables (antes de limpiar el DOM).
    final links = <LinkItem>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = (a.attributes['href'] ?? '').trim();
      if (href.isEmpty || href.startsWith('#') || href.startsWith('javascript:') || href.startsWith('mailto:')) continue;
      Uri u;
      try {
        u = base.resolve(href);
      } catch (_) {
        continue;
      }
      if (u.scheme != 'http' && u.scheme != 'https') continue;
      final ext = extOfPath(u.path);
      if (ext == null) continue;
      final key = u.toString();
      if (!seen.add(key)) continue;
      var label = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (label.isEmpty) label = u.pathSegments.isNotEmpty ? u.pathSegments.last : u.host;
      if (label.length > 90) label = '${label.substring(0, 90)}…';
      links.add(LinkItem(key, label, ext));
    }
    links.sort((a, b) {
      final pa = kPriorityExts.contains(a.ext) ? 0 : 1;
      final pb = kPriorityExts.contains(b.ext) ? 0 : 1;
      return pa.compareTo(pb);
    });

    // 2) Texto principal sin publicidad ni ruido.
    for (final sel in ['script', 'style', 'noscript', 'nav', 'footer', 'aside', 'form', 'iframe', 'svg', 'header']) {
      for (final e in doc.querySelectorAll(sel)) {
        e.remove();
      }
    }
    for (final e in doc.querySelectorAll('div,section,aside,ul,p')) {
      final s = '${e.className} ${e.id}'.trim();
      if (s.isNotEmpty && _adRe.hasMatch(s)) e.remove();
    }
    var text = _mainText(doc);
    if (text.length < 200) {
      final d2 = html_parser.parse(htmlText);
      for (final sel in ['script', 'style', 'noscript', 'svg']) {
        for (final e in d2.querySelectorAll(sel)) {
          e.remove();
        }
      }
      text = _mainText(d2);
    }
    if (text.length > 60000) text = text.substring(0, 60000);
    return PageData(title, text, links);
  }

  static String _mainText(dom.Document d) {
    final main = d.querySelector('article') ?? d.querySelector('main') ?? d.body;
    if (main == null) return '';
    final ps = main
        .querySelectorAll('p, li, h1, h2, h3')
        .map((e) => e.text.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((t) => t.length >= 40)
        .toList();
    var t = ps.join(' ');
    if (t.length < 200) t = main.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }
}

// ============================================================================
// ESCÁNER ANTI-MALWARE DE FILTRO MEDIO
// ============================================================================

class Heur {
  static const Set<String> shorteners = {
    'bit.ly', 't.co', 'tinyurl.com', 'goo.gl', 'ow.ly', 'is.gd', 'buff.ly', 'rebrand.ly',
    'cutt.ly', 'shorturl.at', 'tiny.cc', 't.ly', 'rb.gy', 'lnkd.in', 's.id',
  };
  static const Set<String> badTlds = {
    'zip', 'mov', 'tk', 'ml', 'ga', 'cf', 'gq', 'click', 'country', 'kim', 'loan', 'men',
  };

  static bool isIp(String host) => InternetAddress.tryParse(host) != null;

  static String registrable(String host) {
    final p = host.split('.');
    return p.length <= 2 ? host : p.sublist(p.length - 2).join('.');
  }

  static List<Finding> url(Uri u) {
    final f = <Finding>[];
    if (u.scheme == 'https') {
      f.add(const Finding(Level.ok, 'Conexión segura (HTTPS)'));
    } else {
      f.add(Finding(Level.danger, 'Conexión sin cifrar (${u.scheme})',
          'El archivo podría ser alterado en tránsito. Se bloquea la descarga.'));
    }
    final host = u.host.toLowerCase();
    if (u.userInfo.isNotEmpty) {
      f.add(const Finding(Level.danger, 'La URL contiene credenciales/@', 'Técnica habitual para ocultar el dominio real.'));
    }
    if (isIp(host)) {
      f.add(const Finding(Level.warn, 'Dirección IP en lugar de dominio', 'Los sitios legítimos suelen usar dominios.'));
    }
    if (host.contains('xn--')) {
      f.add(const Finding(Level.warn, 'Dominio con caracteres internacionales (punycode)', 'Posible suplantación visual de otro sitio.'));
    }
    if (host.split('.').length > 5) {
      f.add(const Finding(Level.warn, 'Demasiados subdominios', 'Patrón frecuente en sitios engañosos.'));
    }
    if (u.hasPort && u.port != 443 && u.port != 80) {
      f.add(Finding(Level.warn, 'Puerto poco común (${u.port})'));
    }
    if (shorteners.contains(host)) {
      f.add(const Finding(Level.warn, 'Acortador de enlaces', 'El destino real está oculto; se sigue la redirección para revisarlo.'));
    }
    final tld = host.contains('.') ? host.split('.').last : '';
    if (badTlds.contains(tld)) {
      f.add(Finding(Level.warn, 'Dominio .$tld', 'Extensión con alta tasa de abuso.'));
    }
    if (RegExp(r'\.(pdf|jpe?g|png|mp4|docx?|xlsx?|mp3)\.(exe|apk|bat|scr|js|sh|cmd|msi)$', caseSensitive: false).hasMatch(u.path)) {
      f.add(const Finding(Level.danger, 'Doble extensión engañosa', 'Parece un documento pero es ejecutable.'));
    }
    return f;
  }
}

class Rep {
  /// Reputación de dominio: compara DNS sin filtro vs. DNS con bloqueo de malware
  /// (Cloudflare 1.1.1.1 vs 1.1.1.2 por DNS-over-HTTPS, sin API key).
  static Future<Finding> domain(String host) async {
    if (Heur.isIp(host)) {
      return const Finding(Level.info, 'Reputación de dominio no aplicable (IP directa)');
    }
    try {
      final plain = await Net.dohJson('https://cloudflare-dns.com/dns-query', host);
      final sec = await Net.dohJson('https://security.cloudflare-dns.com/dns-query', host);
      if (plain == null || sec == null) {
        return Finding(Level.info, 'No se pudo consultar reputación de $host', 'Sin respuesta del servicio de amenazas.');
      }
      final plainAns = (plain['Answer'] as List?) ?? [];
      final plainOk = plain['Status'] == 0 && plainAns.isNotEmpty;
      final secAns = (sec['Answer'] as List?) ?? [];
      final blocked = sec['Status'] == 3 || secAns.any((a) => (a as Map)['data']?.toString() == '0.0.0.0');
      if (plainOk && blocked) {
        return Finding(Level.danger, 'Dominio marcado como malicioso', '$host está en las listas de malware/phishing de Cloudflare Security.');
      }
      if (!plainOk) {
        return Finding(Level.warn, 'El dominio no resuelve', 'No se pudo confirmar $host en DNS.');
      }
      return Finding(Level.ok, 'Dominio sin reportes de amenazas', '$host no figura en listas de malware/phishing consultadas.');
    } catch (e) {
      return Finding(Level.info, 'No se pudo consultar reputación de $host', _short(e));
    }
  }

  /// Reputación de hash: VirusTotal (si el usuario puso su API key) y CIRCL hashlookup (sin key).
  static Future<Finding> hash(String sha, String vtKey) async {
    if (vtKey.trim().isNotEmpty) {
      try {
        final r = await Net.getBytes(
          Uri.parse('https://www.virustotal.com/api/v3/files/$sha'),
          maxBytes: 400000,
          headers: {'x-apikey': vtKey.trim()},
        );
        if (r.status == 200) {
          final j = jsonDecode(r.text) as Map<String, dynamic>;
          final st = (((j['data'] as Map?)?['attributes'] as Map?)?['last_analysis_stats'] as Map?) ?? {};
          final mal = (st['malicious'] as num?)?.toInt() ?? 0;
          final sus = (st['suspicious'] as num?)?.toInt() ?? 0;
          if (mal > 0) return Finding(Level.danger, 'Hash en VirusTotal: ALERTA', '$mal motores lo marcan como malicioso.');
          if (sus > 0) return Finding(Level.warn, 'Hash en VirusTotal: PRECAUCIÓN', '$sus motores lo marcan como sospechoso.');
          return const Finding(Level.ok, 'Hash en VirusTotal: sin reportes', '0 detecciones en el análisis más reciente.');
        }
        if (r.status == 404) {
          // Desconocido para VT: continúa con CIRCL.
        } else if (r.status == 401 || r.status == 403) {
          return const Finding(Level.warn, 'API key de VirusTotal inválida', 'Revisa la clave en Ajustes.');
        }
      } catch (_) {}
    }
    try {
      final r = await Net.getBytes(
        Uri.parse('https://hashlookup.circl.lu/lookup/sha256/$sha'),
        maxBytes: 200000,
        headers: {'Accept': 'application/json'},
      );
      if (r.status == 200) {
        final j = jsonDecode(r.text) as Map<String, dynamic>;
        if (j.containsKey('KnownMalicious')) {
          return Finding(Level.danger, 'Hash conocido como malicioso (CIRCL)', j['KnownMalicious'].toString());
        }
        return const Finding(Level.ok, 'Hash conocido en bases públicas (CIRCL)', 'Aparece como archivo legítimo catalogado.');
      }
      if (r.status == 404) {
        return const Finding(Level.ok, 'Hash sin reportes', 'No aparece en las fuentes consultadas. Esto no garantiza que sea seguro.');
      }
    } catch (_) {}
    return const Finding(Level.info, 'No se pudo consultar la reputación del hash', 'Sin conexión con los servicios de hash.');
  }
}

String _short(Object e) {
  final s = e.toString().replaceAll('\n', ' ');
  return s.length > 140 ? '${s.substring(0, 140)}…' : s;
}

const Map<String, Set<String>> kExpected = {
  'mbtiles': {'sqlite'},
  'geojson': {'json'},
  'json': {'json'},
  'osm.pbf': {'osmpbf'},
  'pbf': {'osmpbf', 'unknown'},
  'pdf': {'pdf'},
  'zip': {'zip'},
  'apk': {'zip'},
  'apks': {'zip'},
  'xapk': {'zip'},
  'docx': {'zip'},
  'xlsx': {'zip'},
  'pptx': {'zip'},
  'epub': {'zip'},
  'jar': {'zip'},
  'tar.gz': {'gzip'},
  'tgz': {'gzip'},
  'gz': {'gzip'},
  'mp4': {'mp4'},
  'mov': {'mp4'},
  'mkv': {'matroska'},
  'webm': {'matroska'},
  'mp3': {'mp3'},
  'csv': {'text'},
  'txt': {'text', 'json'},
  'md': {'text'},
  'kml': {'text'},
  'gpx': {'text'},
  'png': {'png'},
  'exe': {'exe'},
  'msi': {'unknown'},
  '7z': {'7z'},
  'rar': {'rar'},
};

class Magic {
  static bool _starts(Uint8List b, List<int> sig, [int off = 0]) {
    if (b.length < off + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[off + i] != sig[i]) return false;
    }
    return true;
  }

  static String detect(Uint8List b) {
    if (b.isEmpty) return 'empty';
    if (_starts(b, [0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00])) return 'sqlite';
    if (_starts(b, [0x25, 0x50, 0x44, 0x46])) return 'pdf';
    if (_starts(b, [0x50, 0x4B, 0x03, 0x04]) || _starts(b, [0x50, 0x4B, 0x05, 0x06])) return 'zip';
    if (_starts(b, [0x1F, 0x8B])) return 'gzip';
    if (_starts(b, [0x4D, 0x5A])) return 'exe';
    if (_starts(b, [0x7F, 0x45, 0x4C, 0x46])) return 'elf';
    if (_starts(b, [0x1A, 0x45, 0xDF, 0xA3])) return 'matroska';
    if (_starts(b, [0x66, 0x74, 0x79, 0x70], 4)) return 'mp4';
    if (_starts(b, [0x89, 0x50, 0x4E, 0x47])) return 'png';
    if (_starts(b, [0xFF, 0xD8, 0xFF])) return 'jpeg';
    if (_starts(b, [0x47, 0x49, 0x46, 0x38])) return 'gif';
    if (_starts(b, [0x37, 0x7A, 0xBC, 0xAF])) return '7z';
    if (_starts(b, [0x52, 0x61, 0x72, 0x21])) return 'rar';
    if (_starts(b, [0x49, 0x44, 0x33]) || (b.length > 1 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0)) return 'mp3';
    if (b.length >= 16 && latin1.decode(b.sublist(4, math.min(b.length, 40)), allowInvalid: true).contains('OSMHeader')) {
      return 'osmpbf';
    }
    final headStr = latin1.decode(b.sublist(0, math.min(b.length, 512)), allowInvalid: true).toLowerCase().trimLeft();
    if (headStr.contains('<!doctype html') || headStr.contains('<html')) return 'html';
    if (headStr.startsWith('#!')) return 'script';
    var i = 0;
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) i = 3;
    while (i < b.length && (b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09)) {
      i++;
    }
    if (i < b.length && (b[i] == 0x7B || b[i] == 0x5B)) return 'json';
    if (_mostlyText(b)) return 'text';
    return 'unknown';
  }

  static bool _mostlyText(Uint8List b) {
    final n = math.min(b.length, 512);
    if (n == 0) return false;
    var good = 0;
    for (var i = 0; i < n; i++) {
      final c = b[i];
      if (c == 0) return false;
      if (c == 9 || c == 10 || c == 13 || (c >= 32 && c < 127) || c >= 128) good++;
    }
    return good / n > 0.92;
  }

  static const Map<String, String> _human = {
    'sqlite': 'base SQLite', 'pdf': 'PDF', 'zip': 'ZIP/Office/APK', 'gzip': 'GZIP', 'exe': 'ejecutable de Windows',
    'elf': 'ejecutable Linux', 'matroska': 'Matroska/WebM', 'mp4': 'MP4/MOV', 'png': 'PNG', 'jpeg': 'JPEG',
    'gif': 'GIF', '7z': '7-Zip', 'rar': 'RAR', 'mp3': 'MP3', 'osmpbf': 'OSM PBF', 'html': 'página HTML',
    'script': 'script', 'json': 'JSON', 'text': 'texto', 'unknown': 'binario desconocido', 'empty': 'vacío',
  };

  static List<Finding> check(Uint8List head, String ext) {
    final kind = detect(head);
    final label = _human[kind] ?? kind;
    final exp = kExpected[ext];
    if (kind == 'empty') {
      return [const Finding(Level.danger, 'Archivo vacío', 'El servidor no entregó bytes.')];
    }
    if (kind == 'html' && ext != 'html' && ext != 'htm') {
      return [Finding(Level.danger, 'Es una página web, no un archivo .$ext', 'Los primeros bytes son HTML (típico de páginas de anuncios o bloqueos).')];
    }
    if ((kind == 'exe' || kind == 'elf' || kind == 'script') && !(exp?.contains(kind) ?? false)) {
      return [Finding(Level.danger, 'Ejecutable disfrazado', 'La firma real es $label pero se presenta como .${ext.isEmpty ? 'desconocido' : ext}.')];
    }
    if (exp != null && !exp.contains(kind)) {
      return [Finding(Level.danger, 'La firma no coincide con la extensión', 'Se anuncia .$ext pero los primeros bytes corresponden a: $label.')];
    }
    if (exp != null) {
      return [Finding(Level.ok, 'Firma real coincide (Magic Bytes)', 'Verificado por Range: $label.')];
    }
    return [Finding(Level.info, 'Tipo detectado por firma: $label')];
  }
}

class PreScan {
  final Uri finalUri;
  final String name;
  final String ext;
  final int? length;
  final bool resumable;
  final List<Finding> findings;
  PreScan(this.finalUri, this.name, this.ext, this.length, this.resumable, this.findings);
  Level get level => worst(findings);
}

class PostScan {
  final List<Finding> findings;
  final String sha;
  PostScan(this.findings, this.sha);
  Level get level => worst(findings);
}

class Scanner {
  static String _sanitize(String n) {
    var s = n.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (s.length > 120) s = s.substring(s.length - 120);
    return s.isEmpty ? 'archivo' : s;
  }

  static String? _dispositionName(String? d) {
    if (d == null) return null;
    final m = RegExp(r'''filename\*?=(?:UTF-8'')?"?([^";]+)"?''', caseSensitive: false).firstMatch(d);
    if (m == null) return null;
    try {
      return Uri.decodeComponent(m.group(1)!.trim());
    } catch (_) {
      return m.group(1)!.trim();
    }
  }

  static const Map<String, String> _ctToExt = {
    'application/pdf': 'pdf', 'application/zip': 'zip', 'video/mp4': 'mp4', 'audio/mpeg': 'mp3',
    'application/vnd.android.package-archive': 'apk', 'application/epub+zip': 'epub',
    'application/geo+json': 'geojson', 'text/csv': 'csv', 'video/webm': 'webm', 'video/x-matroska': 'mkv',
    'application/gzip': 'gz', 'application/x-gzip': 'gz',
  };

  static const Set<String> _genericCt = {
    'application/octet-stream', 'binary/octet-stream', 'application/download',
    'application/force-download', 'application/x-download', 'application/x-binary', '',
  };

  static const Map<String, Set<String>> _major = {
    'pdf': {'application'}, 'mp4': {'video', 'audio'}, 'mkv': {'video'}, 'webm': {'video', 'audio'},
    'mp3': {'audio', 'application'}, 'zip': {'application'}, 'apk': {'application'}, 'epub': {'application'},
    'docx': {'application'}, 'mbtiles': {'application'},
  };

  static Future<PreScan> preScan(Uri input) async {
    final f = <Finding>[];
    var uri = input;

    // Auto-actualizar http -> https si es posible.
    if (uri.scheme == 'http') {
      final https = uri.replace(scheme: 'https');
      try {
        final h = await Net.head(https);
        if (h.status >= 200 && h.status < 400) {
          uri = https;
          f.add(const Finding(Level.info, 'Enlace actualizado a HTTPS', 'El servidor ofrece versión cifrada; se usará esa.'));
        }
      } catch (_) {}
    }

    // 1) Heurística de URL.
    f.addAll(Heur.url(uri));

    // 2) HEAD: peso real, tipo, redirecciones.
    HeadInfo? h;
    try {
      h = await Net.head(uri);
    } catch (e) {
      f.add(Finding(Level.warn, 'No se pudieron leer las cabeceras', _short(e)));
    }
    final finalUri = h?.finalUri ?? uri;
    if (h != null) {
      if (h.status >= 400) {
        f.add(Finding(Level.danger, 'El servidor respondió HTTP ${h.status}', 'El archivo no está disponible en ese enlace.'));
      }
      if (h.chain.length > 1) {
        final sameSite = Heur.registrable(uri.host) == Heur.registrable(finalUri.host);
        if (finalUri.scheme != 'https') {
          f.add(const Finding(Level.danger, 'Redirige a una conexión sin cifrar'));
        }
        if (!sameSite) {
          f.add(Finding(Level.warn, 'Redirección a otro dominio', '${uri.host} → ${finalUri.host} (${h.chain.length - 1} saltos).'));
          f.addAll(Heur.url(finalUri).where((x) => x.level.index >= Level.warn.index));
        } else if (h.chain.length > 3) {
          f.add(Finding(Level.warn, 'Muchas redirecciones (${h.chain.length - 1})'));
        } else {
          f.add(Finding(Level.info, 'Redirección en el mismo sitio', 'Destino final: ${finalUri.host}.'));
        }
      }
    }

    // 3) Reputación de dominio (solo con conexión).
    final hosts = <String>{uri.host.toLowerCase(), finalUri.host.toLowerCase()};
    for (final host in hosts) {
      f.add(await Rep.domain(host));
    }

    // 4) Nombre y extensión.
    var name = _dispositionName(h?.disposition) ??
        (finalUri.pathSegments.isNotEmpty ? Uri.decodeComponent(finalUri.pathSegments.last) : '');
    var ext = extOfPath(name) ?? extOfPath(finalUri.path) ?? _ctToExt[h?.contentType ?? ''] ?? '';
    name = _sanitize(name);
    if (ext.isNotEmpty && extOfPath(name) == null) name = '$name.$ext';

    // 5) Peso + alerta de RAM para GeoJSON.
    final len = h?.length;
    if (len != null && len >= 0) {
      f.add(Finding(Level.info, 'Peso real (HEAD): ${fmtBytes(len)}'));
      if ((ext == 'geojson' || ext == 'json') && len > kGeoWarnBytes) {
        f.add(Finding(
          Level.warn,
          'GeoJSON muy pesado para un móvil (${fmtBytes(len)})',
          'Superar ${kGeoStrongBytes ~/ (1024 * 1024)} MB puede causar Out of Memory al abrirlo en el equipo. '
              'Considera buscar un extracto más ligero (por municipio o estado). Tú decides si continúas.',
        ));
      } else if (len > 1024 * 1024 * 1024) {
        f.add(Finding(Level.warn, 'Archivo muy grande (${fmtBytes(len)})', 'Verifica espacio libre y usa una red estable.'));
      }
    } else {
      f.add(const Finding(Level.warn, 'El servidor no informa el peso', 'No se puede estimar el tamaño antes de descargar.'));
    }

    // 6) Reanudación.
    final resumable = h?.acceptRanges ?? false;
    if (h != null) {
      f.add(resumable
          ? const Finding(Level.ok, 'Descarga reanudable (HTTP Range)', 'Si cae la señal, Android retomará donde quedó.')
          : const Finding(Level.warn, 'Sin soporte de reanudación', 'Si cae la señal, la descarga podría reiniciarse.'));
    }

    // 7) Coherencia de Content-Type.
    final ct = h?.contentType ?? '';
    if (h != null && h.status < 400) {
      if (ct == 'text/html' && ext != 'html' && ext != 'htm') {
        f.add(const Finding(Level.danger, 'El servidor devuelve una página HTML', 'No es el archivo anunciado; suele ser publicidad, captcha o redirección engañosa.'));
      } else if (!_genericCt.contains(ct) && _major[ext] != null && !_major[ext]!.contains(ct.split('/').first)) {
        f.add(Finding(Level.warn, 'Content-Type inesperado', 'Se anuncia "$ct" para un archivo .$ext.'));
      } else if (ct.isNotEmpty) {
        f.add(Finding(Level.info, 'Content-Type: $ct'));
      }
    }

    // 8) Magic Bytes por Range (solo los primeros 4 KB).
    if (h != null && h.status < 400 && finalUri.scheme == 'https') {
      try {
        final head = await Net.rangeBytes(finalUri, 0, 4095);
        f.addAll(Magic.check(head, ext));
      } catch (e) {
        f.add(Finding(Level.warn, 'No se pudo verificar la firma (Range)', _short(e)));
      }
    }
    return PreScan(finalUri, name, ext, len, resumable, f);
  }

  /// Antes de abrir/guardar: tamaño, firma local, estructura, SHA-256 en streaming y reputación.
  static Future<PostScan> postScan(
    File file,
    String ext,
    int? expectedLen,
    String vtKey, {
    void Function(String)? onStep,
  }) async {
    final f = <Finding>[];
    onStep?.call('Comprobando tamaño y firma…');
    final len = await file.length();
    f.add(Finding(Level.info, 'Tamaño descargado: ${fmtBytes(len)}'));
    if (expectedLen != null && expectedLen > 0 && expectedLen != len) {
      f.add(Finding(Level.warn, 'El tamaño no coincide con lo anunciado', 'Esperado ${fmtBytes(expectedLen)}, recibido ${fmtBytes(len)}.'));
    }
    final raf = await file.open();
    Uint8List head;
    try {
      head = await raf.read(math.min(len, 4096));
    } finally {
      await raf.close();
    }
    f.addAll(Magic.check(head, ext));

    onStep?.call('Inspeccionando estructura interna…');
    f.addAll(await Inspector.inspect(file, ext));

    onStep?.call('Calculando SHA-256 por fragmentos…');
    final sha = (await sha256.bind(file.openRead()).first).toString();

    onStep?.call('Consultando reputación del hash…');
    f.add(await Rep.hash(sha, vtKey));
    return PostScan(f, sha);
  }
}

class Inspector {
  static const Set<String> _execExt = {
    'exe', 'dll', 'bat', 'cmd', 'ps1', 'vbs', 'js', 'jse', 'wsf', 'msi', 'scr', 'com', 'sh', 'jar', 'lnk', 'apk', 'dex',
  };
  static const Set<String> _riskyPerms = {
    'SEND_SMS', 'READ_SMS', 'RECEIVE_SMS', 'BIND_ACCESSIBILITY_SERVICE', 'BIND_DEVICE_ADMIN',
    'REQUEST_INSTALL_PACKAGES', 'SYSTEM_ALERT_WINDOW', 'READ_CONTACTS', 'RECORD_AUDIO', 'READ_CALL_LOG',
    'MANAGE_EXTERNAL_STORAGE', 'READ_PHONE_STATE', 'CALL_PHONE', 'BIND_NOTIFICATION_LISTENER_SERVICE',
    'WRITE_SETTINGS', 'CAMERA',
  };

  static Future<List<Finding>> inspect(File f, String ext) async {
    try {
      switch (ext) {
        case 'zip':
        case 'apk':
        case 'apks':
        case 'xapk':
        case 'docx':
        case 'xlsx':
        case 'pptx':
        case 'epub':
        case 'jar':
          return await _zip(f, ext);
        case 'pdf':
          return await _pdf(f);
        case 'mbtiles':
          return await _mbtiles(f);
        case 'geojson':
        case 'json':
          return await _geojson(f);
        case 'osm.pbf':
        case 'pbf':
          return await _pbf(f);
        case 'csv':
          return await _csv(f);
        default:
          return [Finding(Level.info, 'Sin inspección profunda para ${ext.isEmpty ? 'este tipo' : '.$ext'}', 'Se validaron firma y hash.')];
      }
    } catch (e) {
      return [Finding(Level.warn, 'No se pudo completar la inspección estructural', _short(e))];
    }
  }

  // ---- ZIP / APK / Office / EPUB: solo directorio central, sin descomprimir todo ----
  static Future<List<Finding>> _zip(File f, String ext) async {
    final out = <Finding>[];
    final raf = await f.open();
    try {
      final len = await raf.length();
      final tailLen = math.min(len, 65557);
      await raf.setPosition(len - tailLen);
      final tail = await raf.read(tailLen);
      var eocd = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) {
        return [const Finding(Level.danger, 'ZIP corrupto o incompleto', 'No se encontró el directorio central.')];
      }
      final bd = ByteData.sublistView(tail);
      final entries = bd.getUint16(eocd + 10, Endian.little);
      final cdSize = bd.getUint32(eocd + 12, Endian.little);
      final cdOffset = bd.getUint32(eocd + 16, Endian.little);
      if (entries == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
        return [const Finding(Level.warn, 'ZIP64: inspección interna omitida', 'Archivo demasiado grande para el análisis ligero.')];
      }
      if (cdSize > 8 * 1024 * 1024) {
        return [const Finding(Level.warn, 'Directorio ZIP muy grande: inspección omitida')];
      }
      await raf.setPosition(cdOffset);
      final cd = await raf.read(cdSize);
      final cdv = ByteData.sublistView(cd);
      var pos = 0;
      var count = 0;
      var totalUncompressed = 0;
      final execs = <String>[];
      final doubles = <String>[];
      var traversal = false;
      var macro = false;
      int? manifestOffset;
      int manifestComp = 0;
      int manifestMethod = 0;
      while (pos + 46 <= cd.length && cdv.getUint32(pos, Endian.little) == 0x02014b50) {
        final method = cdv.getUint16(pos + 10, Endian.little);
        final comp = cdv.getUint32(pos + 20, Endian.little);
        final uncomp = cdv.getUint32(pos + 24, Endian.little);
        final nl = cdv.getUint16(pos + 28, Endian.little);
        final xl = cdv.getUint16(pos + 30, Endian.little);
        final cl = cdv.getUint16(pos + 32, Endian.little);
        final off = cdv.getUint32(pos + 42, Endian.little);
        if (pos + 46 + nl > cd.length) break;
        final name = utf8.decode(cd.sublist(pos + 46, pos + 46 + nl), allowMalformed: true);
        count++;
        totalUncompressed += uncomp;
        final lower = name.toLowerCase();
        if (name.contains('../') || name.startsWith('/') || name.contains('..\\')) traversal = true;
        final e = lower.contains('.') ? lower.split('.').last : '';
        final isApkLike = ext == 'apk' || ext == 'apks' || ext == 'xapk' || ext == 'jar';
        if (!isApkLike && _execExt.contains(e) && execs.length < 6) execs.add(name);
        if (RegExp(r'\.(pdf|jpe?g|png|docx?|txt|mp4)\.(exe|bat|scr|js|sh|cmd|apk)$').hasMatch(lower) && doubles.length < 3) {
          doubles.add(name);
        }
        if (lower.endsWith('vbaproject.bin')) macro = true;
        if (name == 'AndroidManifest.xml') {
          manifestOffset = off;
          manifestComp = comp;
          manifestMethod = method;
        }
        pos += 46 + nl + xl + cl;
      }
      out.add(Finding(Level.ok, 'Estructura ZIP válida', '$count entradas en el directorio central.'));
      if (count > 20000) out.add(Finding(Level.warn, 'Cantidad inusual de entradas ($count)'));
      if (len > 0 && totalUncompressed / len > 150) {
        out.add(Finding(Level.warn, 'Ratio de compresión extremo', 'Posible "zip bomb": ${fmtBytes(totalUncompressed)} descomprimidos.'));
      }
      if (traversal) out.add(const Finding(Level.danger, 'Rutas peligrosas dentro del ZIP (../)', 'Podría escribir fuera de la carpeta al extraer.'));
      if (doubles.isNotEmpty) out.add(Finding(Level.danger, 'Doble extensión oculta dentro del archivo', doubles.join(', ')));
      if (execs.isNotEmpty) {
        out.add(Finding(Level.warn, 'Contiene ejecutables o scripts', execs.join(', ')));
      }
      if (macro) out.add(const Finding(Level.warn, 'Documento con macros (vbaProject.bin)', 'Las macros pueden ejecutar código.'));
      if (ext == 'apk' && manifestOffset != null) {
        out.addAll(await _apkPerms(raf, manifestOffset, manifestComp, manifestMethod));
      }
      return out;
    } finally {
      await raf.close();
    }
  }

  static Future<List<Finding>> _apkPerms(RandomAccessFile raf, int off, int comp, int method) async {
    try {
      if (comp <= 0 || comp > 2 * 1024 * 1024) return [];
      await raf.setPosition(off);
      final lh = await raf.read(30);
      if (lh.length < 30) return [];
      final lhv = ByteData.sublistView(lh);
      if (lhv.getUint32(0, Endian.little) != 0x04034b50) return [];
      final nl = lhv.getUint16(26, Endian.little);
      final xl = lhv.getUint16(28, Endian.little);
      await raf.setPosition(off + 30 + nl + xl);
      final data = await raf.read(comp);
      List<int> raw = data;
      if (method == 8) {
        raw = ZLibDecoder(raw: true).convert(data);
      } else if (method != 0) {
        return [];
      }
      final s = String.fromCharCodes(raw.where((x) => x != 0));
      final perms = RegExp(r'android\.permission\.([A-Z_]+)').allMatches(s).map((m) => m.group(1)!).toSet();
      if (perms.isEmpty) {
        return [const Finding(Level.info, 'APK: no se pudieron leer los permisos', 'Manifiesto en formato no estándar.')];
      }
      final risky = perms.where(_riskyPerms.contains).toList()..sort();
      if (risky.isEmpty) {
        return [Finding(Level.info, 'APK pide ${perms.length} permisos', 'Ninguno de alto riesgo.')];
      }
      return [
        Finding(
          Level.warn,
          'APK con ${risky.length} permisos sensibles',
          risky.join(', '),
        ),
      ];
    } catch (_) {
      return [];
    }
  }

  // ---- PDF ----
  static Future<List<Finding>> _pdf(File f) async {
    final out = <Finding>[];
    final len = await f.length();
    final raf = await f.open();
    try {
      final head = latin1.decode(await raf.read(math.min(len, 1024)), allowInvalid: true);
      if (!head.startsWith('%PDF-')) {
        return [const Finding(Level.danger, 'Cabecera PDF inválida')];
      }
      out.add(Finding(Level.ok, 'Cabecera PDF válida', head.substring(0, math.min(8, head.length)).trim()));
      await raf.setPosition(math.max(0, len - 2048));
      final tail = latin1.decode(await raf.read(math.min(len, 2048)), allowInvalid: true);
      if (tail.contains('%%EOF') && tail.contains('startxref')) {
        out.add(const Finding(Level.ok, 'Estructura final del PDF presente (startxref/%%EOF)'));
      } else {
        out.add(const Finding(Level.warn, 'PDF sin marcador final', 'Puede estar incompleto o dañado.'));
      }
      await raf.setPosition(0);
      const tokens = ['/JavaScript', '/JS', '/Launch', '/OpenAction', '/EmbeddedFile', '/RichMedia'];
      final flags = <String>{};
      var scanned = 0;
      var carry = '';
      const limit = 48 * 1024 * 1024;
      while (scanned < len && scanned < limit) {
        final bytes = await raf.read(256 * 1024);
        if (bytes.isEmpty) break;
        scanned += bytes.length;
        final s = carry + latin1.decode(bytes, allowInvalid: true);
        for (final t in tokens) {
          if (s.contains(t)) flags.add(t);
        }
        carry = s.substring(math.max(0, s.length - 24));
        await Future<void>.delayed(Duration.zero);
      }
      if (flags.contains('/Launch')) {
        out.add(const Finding(Level.danger, 'PDF con acción /Launch', 'Puede lanzar programas externos.'));
      }
      final soft = flags.where((t) => t != '/Launch').toList();
      if (soft.isNotEmpty) {
        out.add(Finding(Level.warn, 'PDF con contenido activo', soft.join(', ')));
      } else if (!flags.contains('/Launch')) {
        out.add(const Finding(Level.ok, 'Sin JavaScript ni archivos incrustados visibles', 'Análisis ligero (objetos comprimidos no se expanden).'));
      }
      return out;
    } finally {
      await raf.close();
    }
  }

  // ---- MBTiles (SQLite) ----
  static Future<List<Finding>> _mbtiles(File f) async {
    final len = await f.length();
    final raf = await f.open();
    try {
      final hdr = await raf.read(100);
      if (hdr.length < 100) return [const Finding(Level.danger, 'MBTiles truncado', 'Cabecera SQLite incompleta.')];
      final bd = ByteData.sublistView(hdr);
      var ps = bd.getUint16(16, Endian.big);
      if (ps == 1) ps = 65536;
      final pages = bd.getUint32(28, Endian.big);
      final out = <Finding>[];
      if (ps < 512 || (ps & (ps - 1)) != 0) {
        return [const Finding(Level.danger, 'Tamaño de página SQLite inválido')];
      }
      out.add(Finding(Level.ok, 'Cabecera SQLite válida', 'Páginas de ${fmtBytes(ps)}.'));
      if (pages > 0) {
        final expected = ps * pages;
        if (len < expected) {
          out.add(Finding(Level.danger, 'MBTiles incompleto', 'Esperado ${fmtBytes(expected)}, hay ${fmtBytes(len)}.'));
        } else if (len > expected) {
          out.add(const Finding(Level.warn, 'Tamaño mayor al declarado por SQLite', 'Puede tener datos extra al final.'));
        } else {
          out.add(const Finding(Level.ok, 'Tamaño consistente con el número de páginas'));
        }
      }
      await raf.setPosition(0);
      final first = latin1.decode(await raf.read(math.min(len, ps)), allowInvalid: true);
      final hasTiles = first.contains('tiles');
      final hasMeta = first.contains('metadata');
      if (hasTiles && hasMeta) {
        out.add(const Finding(Level.ok, 'Esquema MBTiles detectado', 'Tablas "tiles" y "metadata" presentes.'));
      } else {
        out.add(const Finding(Level.warn, 'No se detectó el esquema MBTiles', 'No se ven las tablas tiles/metadata en la primera página.'));
      }
      return out;
    } finally {
      await raf.close();
    }
  }

  // ---- GeoJSON ----
  static Future<List<Finding>> _geojson(File f) async {
    final out = <Finding>[];
    final len = await f.length();
    final raf = await f.open();
    String headStr;
    String tailStr;
    try {
      headStr = utf8.decode(await raf.read(math.min(len, 65536)), allowMalformed: true);
      await raf.setPosition(math.max(0, len - 2048));
      tailStr = utf8.decode(await raf.read(math.min(len, 2048)), allowMalformed: true).trimRight();
    } finally {
      await raf.close();
    }
    final h = headStr.trimLeft();
    if (!(h.startsWith('{') || h.startsWith('\uFEFF{'))) {
      return [const Finding(Level.danger, 'No inicia como objeto JSON')];
    }
    final hasType = headStr.contains('"FeatureCollection"') ||
        headStr.contains('"Feature"') ||
        headStr.contains('"GeometryCollection"') ||
        headStr.contains('"LineString"');
    out.add(hasType
        ? const Finding(Level.ok, 'Estructura GeoJSON reconocida', 'Tipo FeatureCollection/Feature detectado.')
        : const Finding(Level.warn, 'JSON sin tipo GeoJSON visible al inicio'));
    if (headStr.contains('LineString')) {
      out.add(const Finding(Level.info, 'Contiene geometrías lineales', 'Apto para red vial/enrutamiento.'));
    }
    if (!tailStr.endsWith('}')) {
      out.add(const Finding(Level.danger, 'GeoJSON truncado', 'No termina con "}" (descarga incompleta).'));
    }
    if (len <= kGeoDepthMaxBytes) {
      var depth = 0;
      var inStr = false;
      var esc = false;
      var bad = false;
      await for (final chunk in f.openRead()) {
        for (var i = 0; i < chunk.length; i++) {
          final c = chunk[i];
          if (inStr) {
            if (esc) {
              esc = false;
            } else if (c == 0x5C) {
              esc = true;
            } else if (c == 0x22) {
              inStr = false;
            }
          } else if (c == 0x22) {
            inStr = true;
          } else if (c == 0x7B || c == 0x5B) {
            depth++;
          } else if (c == 0x7D || c == 0x5D) {
            depth--;
            if (depth < 0) bad = true;
          }
        }
        await Future<void>.delayed(Duration.zero);
      }
      if (depth == 0 && !bad && !inStr) {
        out.add(const Finding(Level.ok, 'Llaves y corchetes balanceados', 'Recorrido en streaming sin cargar el archivo en RAM.'));
      } else {
        out.add(const Finding(Level.danger, 'Estructura JSON desbalanceada', 'El archivo está dañado o incompleto.'));
      }
    } else {
      out.add(const Finding(Level.info, 'Chequeo completo omitido por tamaño', 'Solo se validaron inicio y final.'));
    }
    return out;
  }

  static Future<List<Finding>> _pbf(File f) async {
    final raf = await f.open();
    try {
      final b = await raf.read(64);
      if (b.length < 16) return [const Finding(Level.danger, 'PBF truncado')];
      final hl = ByteData.sublistView(b).getUint32(0, Endian.big);
      final txt = latin1.decode(b.sublist(4), allowInvalid: true);
      if (hl > 0 && hl < 65536 && txt.contains('OSMHeader')) {
        return [const Finding(Level.ok, 'Cabecera OSM PBF válida (OSMHeader)')];
      }
      return [const Finding(Level.warn, 'Cabecera OSM PBF no reconocida', 'Puede ser otro tipo de protobuf.')];
    } finally {
      await raf.close();
    }
  }

  static Future<List<Finding>> _csv(File f) async {
    final len = await f.length();
    final raf = await f.open();
    try {
      final b = await raf.read(math.min(len, 65536));
      if (b.contains(0)) return [const Finding(Level.warn, 'El CSV contiene bytes binarios')];
      final s = utf8.decode(b, allowMalformed: true);
      final lines = const LineSplitter().convert(s).where((l) => l.trim().isNotEmpty).length;
      return [Finding(Level.ok, 'CSV de texto plano', '$lines filas leídas en la muestra.')];
    } finally {
      await raf.close();
    }
  }
}

// ============================================================================
// PUENTE NATIVO (DownloadManager, SAF, MediaStore)
// ============================================================================

class Native {
  static const MethodChannel _ch = MethodChannel('webscout/native');

  static Future<String?> pickFolder() => _ch.invokeMethod<String>('pickFolder');

  static Future<int> enqueue(String url, String name) async {
    final id = await _ch.invokeMethod<int>('enqueue', {'url': url, 'name': name, 'ua': kUA});
    return id!;
  }

  static Future<Map<String, dynamic>> query(int id) async {
    final r = await _ch.invokeMethod<Map<Object?, Object?>>('query', {'id': id});
    return Map<String, dynamic>.from(r ?? {'status': -1});
  }

  static Future<void> cancel(int id) => _ch.invokeMethod<bool>('cancel', {'id': id});

  static Future<void> deleteTemp(String path) => _ch.invokeMethod<bool>('deleteTemp', {'path': path});

  static Future<String> saveToDownloads(String path, String name, String mime) async {
    final r = await _ch.invokeMethod<String>('saveToDownloads', {'path': path, 'name': name, 'mime': mime});
    return r ?? 'Descargas/$name';
  }

  static Future<String> saveToTree(String path, String tree, String name, String mime) async {
    final r = await _ch.invokeMethod<String>('saveToTree', {'path': path, 'tree': tree, 'name': name, 'mime': mime});
    return r ?? name;
  }
}

class PendingDl {
  final int id;
  final String url;
  final String name;
  final String ext;
  final String? folderUri;
  final String? folderName;
  final int? length;
  const PendingDl({
    required this.id,
    required this.url,
    required this.name,
    required this.ext,
    this.folderUri,
    this.folderName,
    this.length,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'ext': ext,
        'folderUri': folderUri,
        'folderName': folderName,
        'length': length,
      };

  factory PendingDl.fromJson(Map<String, dynamic> j) => PendingDl(
        id: (j['id'] as num).toInt(),
        url: j['url'] as String,
        name: j['name'] as String,
        ext: (j['ext'] as String?) ?? '',
        folderUri: j['folderUri'] as String?,
        folderName: j['folderName'] as String?,
        length: (j['length'] as num?)?.toInt(),
      );
}

class PendingStore {
  static const String _k = 'pending_dl';

  static Future<List<PendingDl>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_k);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => PendingDl.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<PendingDl> l) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_k, jsonEncode(l.map((e) => e.toJson()).toList()));
  }

  static Future<void> add(PendingDl d) async {
    final l = await load();
    l.removeWhere((x) => x.id == d.id);
    l.add(d);
    await _save(l);
  }

  static Future<void> remove(int id) async {
    final l = await load();
    l.removeWhere((x) => x.id == id);
    await _save(l);
  }
}

// ============================================================================
// UI GENERATIVA AL VUELO (HTML/CSS/JS en memoria, negro y blanco)
// ============================================================================

class DynamicTools {
  static String _n(String s) => s
      .toLowerCase()
      .replaceAll('á', 'a')
      .replaceAll('é', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ü', 'u')
      .replaceAll('ñ', 'n');

  static DynTool? match(String raw) {
    final q = _n(raw);
    bool has(List<String> k) => k.any((x) => q.contains(x));
    bool word(String pattern) => RegExp(pattern).hasMatch(q);

    if ((q.contains('invers') && has(['recuper', 'retorno', 'payback', 'tasa', 'interes'])) || q.contains('payback')) {
      return DynTool('Recuperación de inversión', _page('Recuperación de inversión', _paybackBody, _paybackJs));
    }
    if (has(['prestamo', 'credito', 'hipoteca', 'amortiz', 'financiamiento', 'cuota mensual'])) {
      return DynTool('Préstamo / cuota', _page('Préstamo / cuota mensual', _loanBody, _loanJs));
    }
    if (has(['interes compuesto', 'meta de ahorro', 'ahorro', 'rendimiento', 'compuesto'])) {
      return DynTool('Ahorro e interés compuesto', _page('Ahorro e interés compuesto', _compoundBody, _compoundJs));
    }
    if (has(['convertidor', 'conversor', 'convertir', 'unidades'])) {
      return DynTool('Convertidor de unidades', _page('Convertidor de unidades', _convBody, _convJs));
    }
    if (word(r'\b(iva|propina|descuento|porcentaje)\b')) {
      return DynTool('Porcentajes', _page('Porcentajes, descuentos y propina', _pctBody, _pctJs));
    }
    if (word(r'\b(imc|masa corporal)\b')) {
      return DynTool('IMC', _page('Índice de masa corporal', _bmiBody, _bmiJs));
    }
    if (has(['tabla de multiplicar', 'tablas de multiplicar'])) {
      return DynTool('Tabla de multiplicar', _page('Tabla de multiplicar', _tableBody, _tableJs));
    }
    if (has(['calculadora', 'calcular', 'herramienta', 'simulador', 'vista interactiva'])) {
      return DynTool('Calculadora', _page('Calculadora', _calcBody, _calcJs));
    }
    return null;
  }

  static String _page(String title, String body, String script) => '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
*{box-sizing:border-box}
html,body{margin:0;background:#000;color:#fff;font-family:system-ui,-apple-system,Roboto,sans-serif}
body{padding:14px 14px 40px}
h1{font-size:19px;margin:0 0 14px;letter-spacing:.3px;border-bottom:1px solid #fff;padding-bottom:8px}
label{display:block;font-size:13px;margin:12px 0 4px;color:#ddd}
input,select{width:100%;padding:12px;font-size:17px;background:#000;color:#fff;border:1px solid #fff;border-radius:10px;outline:none}
button{margin-top:14px;width:100%;padding:13px;font-size:17px;font-weight:700;background:#fff;color:#000;border:0;border-radius:10px}
.out{margin-top:16px;padding:12px;border:1px dashed #fff;border-radius:10px;font-size:16px;line-height:1.45}
.row{display:flex;gap:8px}.row>*{flex:1}
table{width:100%;border-collapse:collapse;margin-top:10px;font-size:14px}
th,td{border:1px solid #666;padding:6px 8px;text-align:right}
th{background:#fff;color:#000}
b{color:#fff}
.sec{margin-top:22px;padding-top:6px;border-top:1px solid #444}
</style></head><body>
<h1>$title</h1>
$body
<script>
function g(id){return document.getElementById(id);}
function v(id){return parseFloat(String(g(id).value).replace(',','.'));}
function fmt(n){return isFinite(n)?n.toLocaleString(undefined,{maximumFractionDigits:2}):'—';}
$script
</script></body></html>''';

  // ---------- Recuperación de inversión ----------
  static const String _paybackBody = r'''
<label>Inversión inicial</label><input id="inv" inputmode="decimal" value="100000">
<label>Ingreso neto mensual que genera</label><input id="cf" inputmode="decimal" value="3000">
<label>Tasa de interés anual (%) — costo de oportunidad</label><input id="rate" inputmode="decimal" value="10">
<button onclick="calc()">Calcular</button>
<div class="out" id="out">Ingresa tus datos y toca Calcular.</div>''';

  static const String _paybackJs = r'''
function ym(m){if(!isFinite(m))return 'nunca';var t=Math.ceil(m);return t+' meses ('+Math.floor(t/12)+' años y '+(t%12)+' meses)';}
function calc(){
  var I=v('inv'),C=v('cf'),rA=v('rate'),o=g('out');
  if(!(I>0)||!(C>0)||!(rA>=0)){o.innerHTML='Ingresa valores válidos (inversión e ingreso mayores a 0).';return;}
  var r=rA/100/12,simple=I/C,disc;
  if(r===0){disc=simple;}else{var x=1-I*r/C;disc=(x<=0)?Infinity:-Math.log(x)/Math.log(1+r);}
  var h='<p>Recuperación simple (sin interés): <b>'+ym(simple)+'</b></p>';
  h+='<p>Recuperación considerando el interés: <b>'+ym(disc)+'</b></p>';
  if(!isFinite(disc)){h+='<p>El ingreso mensual ('+fmt(C)+') no supera el costo de oportunidad mensual ('+fmt(I*r)+'): con esa tasa nunca se recupera.</p>';}
  var maxM=isFinite(disc)?Math.ceil(disc)+12:120,bal=I,rows='';
  for(var y=1;y*12<=maxM+11&&y<=30;y++){for(var k=0;k<12;k++){bal=bal*(1+r)-C;}rows+='<tr><td>'+y+'</td><td>'+fmt(Math.max(bal,0))+'</td></tr>';if(bal<=0)break;}
  h+='<table><tr><th>Año</th><th>Saldo por recuperar</th></tr>'+rows+'</table>';
  o.innerHTML=h;
}''';

  // ---------- Préstamo ----------
  static const String _loanBody = r'''
<label>Monto del préstamo</label><input id="p" inputmode="decimal" value="200000">
<label>Tasa de interés anual (%)</label><input id="r" inputmode="decimal" value="12">
<label>Plazo (meses)</label><input id="n" inputmode="numeric" value="36">
<button onclick="calc()">Calcular cuota</button>
<div class="out" id="out">Ingresa tus datos y toca Calcular.</div>''';

  static const String _loanJs = r'''
function calc(){
  var P=v('p'),rA=v('r'),n=Math.round(v('n')),o=g('out');
  if(!(P>0)||!(rA>=0)||!(n>0)){o.innerHTML='Datos inválidos.';return;}
  var i=rA/1200,pay=(i===0)?P/n:P*i/(1-Math.pow(1+i,-n)),tot=pay*n;
  var h='<p>Cuota mensual: <b>'+fmt(pay)+'</b></p><p>Total pagado: <b>'+fmt(tot)+'</b></p><p>Intereses totales: <b>'+fmt(tot-P)+'</b></p>';
  var bal=P,rows='';
  for(var m=1;m<=n;m++){bal=bal*(1+i)-pay;if(m%12===0||m===n){rows+='<tr><td>'+m+'</td><td>'+fmt(Math.max(bal,0))+'</td></tr>';}}
  h+='<table><tr><th>Mes</th><th>Saldo pendiente</th></tr>'+rows+'</table>';
  o.innerHTML=h;
}''';

  // ---------- Ahorro / interés compuesto ----------
  static const String _compoundBody = r'''
<label>Capital inicial</label><input id="p0" inputmode="decimal" value="10000">
<label>Aportación mensual</label><input id="pm" inputmode="decimal" value="1000">
<label>Tasa anual (%)</label><input id="r" inputmode="decimal" value="8">
<div class="row"><div><label>Años</label><input id="y" inputmode="numeric" value="10"></div>
<div><label>Meta (opcional)</label><input id="goal" inputmode="decimal" value="300000"></div></div>
<button onclick="calc()">Calcular</button>
<div class="out" id="out">Ingresa tus datos y toca Calcular.</div>''';

  static const String _compoundJs = r'''
function calc(){
  var p0=v('p0')||0,pm=v('pm')||0,rA=v('r'),y=Math.round(v('y')),goal=v('goal'),o=g('out');
  if(!(rA>=0)||!(y>0)){o.innerHTML='Datos inválidos.';return;}
  var i=rA/1200,bal=p0,put=p0,rows='';
  for(var m=1;m<=y*12;m++){bal=bal*(1+i)+pm;put+=pm;if(m%12===0){rows+='<tr><td>'+(m/12)+'</td><td>'+fmt(put)+'</td><td>'+fmt(bal)+'</td></tr>';}}
  var h='<p>Valor final: <b>'+fmt(bal)+'</b></p><p>Aportado: <b>'+fmt(put)+'</b> · Ganancia: <b>'+fmt(bal-put)+'</b></p>';
  if(goal>0){var b2=p0,m2=0;while(b2<goal&&m2<1200){b2=b2*(1+i)+pm;m2++;}
    h+=(b2>=goal)?'<p>Para llegar a la meta ('+fmt(goal)+'): <b>'+m2+' meses ('+Math.floor(m2/12)+' años y '+(m2%12)+' meses)</b></p>':'<p>Con esos datos la meta no se alcanza en 100 años.</p>';}
  h+='<table><tr><th>Año</th><th>Aportado</th><th>Saldo</th></tr>'+rows+'</table>';
  o.innerHTML=h;
}''';

  // ---------- Convertidor ----------
  static const String _convBody = r'''
<label>Categoría</label><select id="cat" onchange="fill()"></select>
<label>Valor</label><input id="val" inputmode="decimal" value="1" oninput="calc()">
<div class="row"><div><label>De</label><select id="from" onchange="calc()"></select></div>
<div><label>A</label><select id="to" onchange="calc()"></select></div></div>
<div class="out" id="out"></div>''';

  static const String _convJs = r'''
var U={'Longitud':{'m':1,'km':1000,'cm':0.01,'mm':0.001,'mi':1609.344,'yd':0.9144,'ft':0.3048,'in':0.0254},
'Masa':{'kg':1,'g':0.001,'mg':0.000001,'lb':0.45359237,'oz':0.028349523125,'t':1000},
'Volumen':{'L':1,'mL':0.001,'m3':1000,'gal':3.785411784,'fl oz':0.0295735295625,'taza':0.2365882365},
'Velocidad':{'m/s':1,'km/h':0.2777777778,'mph':0.44704,'nudos':0.5144444444},
'Datos':{'B':1,'KB':1024,'MB':1048576,'GB':1073741824,'TB':1099511627776},
'Área':{'m2':1,'km2':1000000,'ha':10000,'ft2':0.09290304,'acre':4046.8564224},
'Tiempo':{'s':1,'min':60,'h':3600,'día':86400,'semana':604800},
'Temperatura':{'°C':0,'°F':0,'K':0}};
function opts(sel,list,pick){sel.innerHTML='';list.forEach(function(k,i){var o=document.createElement('option');o.value=k;o.textContent=k;if(i===pick)o.selected=true;sel.appendChild(o);});}
function fill(){var c=g('cat').value,k=Object.keys(U[c]);opts(g('from'),k,0);opts(g('to'),k,Math.min(1,k.length-1));calc();}
function toC(x,u){return u==='°C'?x:(u==='°F'?(x-32)*5/9:x-273.15);}
function fromC(x,u){return u==='°C'?x:(u==='°F'?x*9/5+32:x+273.15);}
function calc(){
  var c=g('cat').value,f=g('from').value,t=g('to').value,x=v('val'),r;
  if(isNaN(x)){g('out').textContent='Ingresa un número.';return;}
  if(c==='Temperatura'){r=fromC(toC(x,f),t);}else{r=x*U[c][f]/U[c][t];}
  g('out').innerHTML='<b>'+fmt(x)+' '+f+'</b> = <b>'+(Math.abs(r)<0.0001&&r!==0?r.toExponential(4):fmt(r))+' '+t+'</b>';
}
opts(g('cat'),Object.keys(U),0);fill();''';

  // ---------- Porcentajes ----------
  static const String _pctBody = r'''
<label>Precio o cantidad</label><input id="a" inputmode="decimal" value="1000">
<label>Porcentaje (%)</label><input id="b" inputmode="decimal" value="16">
<button onclick="calc()">Calcular</button>
<div class="out" id="out">Ingresa los datos y toca Calcular.</div>
<div class="sec"><label>Cambio porcentual: valor anterior → nuevo</label>
<div class="row"><input id="o1" inputmode="decimal" value="80"><input id="o2" inputmode="decimal" value="100"></div>
<button onclick="chg()">Calcular cambio</button><div class="out" id="out2"></div></div>''';

  static const String _pctJs = r'''
function calc(){
  var a=v('a'),b=v('b'),o=g('out');
  if(isNaN(a)||isNaN(b)){o.textContent='Datos inválidos.';return;}
  var p=a*b/100;
  o.innerHTML='<p>'+fmt(b)+'% de '+fmt(a)+' = <b>'+fmt(p)+'</b></p><p>Con descuento / sin ese porcentaje: <b>'+fmt(a-p)+'</b></p><p>Con recargo / IVA / propina: <b>'+fmt(a+p)+'</b></p>';
}
function chg(){
  var x=v('o1'),y=v('o2'),o=g('out2');
  if(isNaN(x)||isNaN(y)||x===0){o.textContent='Datos inválidos.';return;}
  var c=(y-x)/Math.abs(x)*100;
  o.innerHTML='Cambio: <b>'+(c>=0?'+':'')+fmt(c)+'%</b>';
}''';

  // ---------- IMC ----------
  static const String _bmiBody = r'''
<div class="row"><div><label>Peso (kg)</label><input id="w" inputmode="decimal" value="70"></div>
<div><label>Estatura (cm)</label><input id="h" inputmode="decimal" value="170"></div></div>
<button onclick="calc()">Calcular IMC</button>
<div class="out" id="out">Ingresa tus datos y toca Calcular.</div>''';

  static const String _bmiJs = r'''
function calc(){
  var w=v('w'),h=v('h')/100,o=g('out');
  if(!(w>0)||!(h>0)){o.textContent='Datos inválidos.';return;}
  var b=w/(h*h),c=b<18.5?'Bajo peso':(b<25?'Peso normal':(b<30?'Sobrepeso':'Obesidad'));
  o.innerHTML='IMC: <b>'+fmt(b)+'</b><br>Categoría (OMS): <b>'+c+'</b><br><small>Referencia general; no sustituye consejo médico.</small>';
}''';

  // ---------- Tabla de multiplicar ----------
  static const String _tableBody = r'''
<div class="row"><div><label>Número</label><input id="n" inputmode="numeric" value="7"></div>
<div><label>Hasta</label><input id="m" inputmode="numeric" value="12"></div></div>
<button onclick="calc()">Generar tabla</button>
<div class="out" id="out"></div>''';

  static const String _tableJs = r'''
function calc(){
  var n=v('n'),m=Math.min(Math.round(v('m')),200),o=g('out');
  if(isNaN(n)||!(m>0)){o.textContent='Datos inválidos.';return;}
  var r='<table><tr><th>Operación</th><th>Resultado</th></tr>';
  for(var i=1;i<=m;i++){r+='<tr><td>'+fmt(n)+' × '+i+'</td><td>'+fmt(n*i)+'</td></tr>';}
  o.innerHTML=r+'</table>';
}
calc();''';

  // ---------- Calculadora general ----------
  static const String _calcBody = r'''
<label>Expresión (+ − * / ^ % ( ) sqrt sin cos tan log ln abs pi e)</label>
<input id="ex" value="(1250*1.16)/12" autocapitalize="off" autocomplete="off">
<button onclick="calc()">Calcular</button>
<div class="out" id="out">Resultado aparecerá aquí.</div>''';

  static const String _calcJs = r'''
function calc(){
  var s=String(g('ex').value).toLowerCase().replace(/,/g,'.').replace(/\^/g,'**').replace(/×/g,'*').replace(/÷/g,'/');
  var map={'sqrt':'Math.sqrt','sin':'Math.sin','cos':'Math.cos','tan':'Math.tan','log':'Math.log10','ln':'Math.log','abs':'Math.abs','pi':'Math.PI'};
  s=s.replace(/\b(sqrt|sin|cos|tan|log|ln|abs|pi)\b/g,function(m){return map[m];});
  s=s.replace(/\be\b/g,'Math.E');
  var chk=s.replace(/Math\.(sqrt|sin|cos|tan|log10|log|abs|PI|E)/g,'');
  if(!/^[0-9+\-*\/().\s%]*$/.test(chk)){g('out').textContent='Expresión no permitida.';return;}
  try{var r=Function('"use strict";return ('+s+')')();g('out').innerHTML='= <b>'+fmt(r)+'</b>';}catch(e){g('out').textContent='Expresión inválida.';}
}
calc();''';
}

// ============================================================================
// APP
// ============================================================================

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  ));
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const WebScoutApp());
}

class WebScoutApp extends StatelessWidget {
  const WebScoutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebScout Universal',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBlack,
        canvasColor: kBlack,
        colorScheme: const ColorScheme.dark(
          primary: kWhite,
          onPrimary: kBlack,
          secondary: kWhite,
          onSecondary: kBlack,
          surface: kBlack,
          onSurface: kWhite,
          surfaceContainerLow: Color(0xFF0A0A0A),
          surfaceContainer: Color(0xFF0D0D0D),
          surfaceContainerHigh: Color(0xFF111111),
          surfaceContainerHighest: Color(0xFF161616),
          error: kBad,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kBlack,
          foregroundColor: kWhite,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        textTheme: ThemeData.dark().textTheme.apply(bodyColor: kWhite, displayColor: kWhite),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final ParentalController _par = ParentalController();
  GateResult? _gate;
  ChildExplain? _childExplain;
  LockKind _prevLock = LockKind.none;
  String? _pendingGateQuery;

  final TextEditingController _q = TextEditingController();
  final FocusNode _focus = FocusNode();
  SharedPreferences? _prefs;

  bool _dataSaver = false;
  String _chip = 'all';
  bool _loading = false;
  String? _error;
  String? _srcNote;
  int _token = 0;

  List<SearchItem> _results = [];
  List<ImageItem> _images = [];
  List<LinkItem> _links = [];
  String? _summary;
  String? _pageTitle;

  DynTool? _tool;
  WebViewController? _web;

  List<String> _history = [];
  List<String> _shortcuts = [];
  List<PendingDl> _pending = [];
  String _vtKey = '';

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _listening = false;
  final FlutterTts _tts = FlutterTts();
  bool _speaking = false;

  Timer? _ticker;
  int _rssMb = 0;

  @override
  void initState() {
    super.initState();
    final ic = PaintingBinding.instance.imageCache;
    ic.maximumSize = 24;
    ic.maximumSizeBytes = 16 * 1024 * 1024;
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _speaking = false);
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() => _speaking = false);
    });
    _tts.setErrorHandler((_) {
      if (mounted) setState(() => _speaking = false);
    });
    _loadPrefs();
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) => _updateRss());
    _updateRss();
    WidgetsBinding.instance.addObserver(this);
    _par.addListener(_onPar);
    _initParental();
  }

  // ---------------------------------------------------------------- modo parental

  Future<void> _initParental() async {
    await _par.load();
    _par.startTicking();
    if (!mounted) return;
    if (_par.profile == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _firstRun();
      });
    }
  }

  Future<void> _firstRun() async {
    await Navigator.of(context).push(MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => ParentalSettingsPage(controller: _par, firstRun: true),
    ));
    if (mounted) setState(() {});
  }

  void _onPar() {
    if (!mounted) return;
    final lk = _par.lock;
    setState(() {
      // Al bloquearse: se descarta todo el contenido web de la pantalla.
      if (lk != LockKind.none && _prevLock == LockKind.none) _clearSession();
    });
    _prevLock = lk;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _par.setForeground(state == AppLifecycleState.resumed);
  }

  Future<void> _openPanel() async {
    await openParentalPanel(context, _par);
    if (mounted) setState(() {});
  }

  void _openGuides() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GuidesPage(controller: _par)));
  }

  Future<void> _approveByParent() async {
    final q = _pendingGateQuery;
    if (q == null) return;
    final ok = await askPin(context, _par,
        title: 'Permiso de un adulto', subtitle: 'Ingresa el PIN parental para permitir esta consulta una sola vez.');
    if (ok && mounted) _search(q, true);
  }

  Future<void> _saveChildGuide(ChildExplain ce) async {
    await GuideStore.save(ce.toGuide());
    _snack('Guardada en Mis guías.');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _par.removeListener(_onPar);
    _par.dispose();
    _ticker?.cancel();
    _q.dispose();
    _focus.dispose();
    _tts.stop();
    _speech.cancel();
    super.dispose();
  }

  void _updateRss() {
    try {
      final mb = ProcessInfo.currentRss ~/ (1024 * 1024);
      if (mounted && mb != _rssMb) setState(() => _rssMb = mb);
    } catch (_) {}
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final pend = await PendingStore.load();
    if (!mounted) return;
    setState(() {
      _prefs = p;
      _dataSaver = p.getBool('dataSaver') ?? false;
      _history = p.getStringList('history') ?? [];
      _shortcuts = p.getStringList('shortcuts') ?? [];
      _vtKey = p.getString('vtKey') ?? '';
      _pending = pend;
    });
  }

  Future<void> _reloadPending() async {
    final pend = await PendingStore.load();
    if (mounted) setState(() => _pending = pend);
  }

  // ---------------------------------------------------------------- limpieza

  void _destroyDynamic() {
    final c = _web;
    _web = null;
    _tool = null;
    if (c != null) {
      unawaited(() async {
        try {
          await c.loadRequest(Uri.parse('about:blank'));
          await c.clearCache();
          await c.clearLocalStorage();
        } catch (_) {}
      }());
    }
  }

  /// Auto-limpieza estricta: descarta resultados, textos, vistas y cachés de la consulta anterior.
  void _clearSession() {
    _token++;
    _tts.stop();
    _speaking = false;
    _destroyDynamic();
    _results = [];
    _images = [];
    _links = [];
    _summary = null;
    _pageTitle = null;
    _error = null;
    _srcNote = null;
    _gate = null;
    _childExplain = null;
    _loading = false;
    final ic = PaintingBinding.instance.imageCache;
    ic.clear();
    ic.clearLiveImages();
    try {
      final d = Directory('${Directory.systemTemp.path}/webscout_tmp');
      if (d.existsSync()) d.deleteSync(recursive: true);
    } catch (_) {}
  }

  void _manualClean() {
    setState(() {
      _clearSession();
      _q.clear();
    });
    _updateRss();
    _snack('Memoria y caché de la sesión limpiadas.');
  }

  int get _itemsInRam => _results.length + _images.length + _links.length;

  // ---------------------------------------------------------------- búsqueda

  bool _isUrl(String s) {
    if (RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(s)) return true;
    if (extOfPath(s) != null) return false;
    return RegExp(r'^[\w-]+(\.[\w-]+)*\.[a-zA-Z]{2,24}(/\S*)?$').hasMatch(s);
  }

  Future<void> _search([String? text, bool parentApproved = false]) async {
    final raw = (text ?? _q.text).trim();
    if (raw.isEmpty) return;
    if (text != null) _q.text = text;
    _focus.unfocus();
    setState(_clearSession);
    final token = _token;

    Uri? urlTarget;
    if (_isUrl(raw)) {
      final u = Uri.tryParse(raw.contains('://') ? raw : 'https://$raw');
      if (u != null && u.host.isNotEmpty) urlTarget = u;
    }
    final gate = urlTarget != null
        ? await _par.gateUrl(urlTarget)
        : await _par.gateQuery(raw, parentApproved: parentApproved);
    if (!mounted || token != _token) return;
    if (!gate.allowed) {
      setState(() {
        _gate = gate;
        _pendingGateQuery = raw;
      });
      return;
    }
    unawaited(_addHistory(raw));

    if (urlTarget != null) {
      await _rayosX(urlTarget, token);
      return;
    }

    final tool = DynamicTools.match(raw);
    if (tool != null) {
      _showTool(tool);
      return;
    }

    setState(() => _loading = true);
    var chip = kChips.firstWhere((c) => c.key == _chip);
    if (chip.key == 'all') {
      final d = detectChip(raw);
      if (d != null) {
        chip = d;
        _chip = d.key;
        _srcNote = 'Detecté "${d.label}" en tu consulta y apliqué ese filtro.';
      }
    }

    // Menores: solo formatos permitidos para su perfil.
    if (chip.exts.isNotEmpty && _par.isMinor) {
      final allowed = _par.allowedDownloadExts ?? const <String>{};
      if (!chip.exts.every(allowed.contains)) {
        final g = _par.gateDownloadExt(chip.exts.first);
        setState(() {
          _loading = false;
          _gate = g;
        });
        return;
      }
    }

    try {
      var results = <SearchItem>[];
      var images = <ImageItem>[];
      if (chip.key == 'img') {
        if (_dataSaver) {
          if (token != _token) return;
          setState(() {
            _loading = false;
            _error = 'El modo Solo texto está activo. Desactívalo para buscar imágenes.';
          });
          return;
        }
        images = (await SearchService.images(raw, kMaxItems)).where((i) => _par.allowText(i.title)).toList();
      } else if (chip.exts.isNotEmpty) {
        results = await _extSearch(raw, chip);
      } else {
        results = await _profileWeb(raw, _dataSaver ? kMaxItems : 8);
        if (!_dataSaver) {
          try {
            images = (await SearchService.images(raw, kMaxItems - results.length)).where((i) => _par.allowText(i.title)).toList();
          } catch (_) {}
        }
      }
      results = results.where((r) => _par.allowResult(r.url, r.title, r.snippet)).toList();
      ChildExplain? ce;
      if (_par.effective == AgeProfile.child && chip.key == 'all') {
        ce = await StudyBuilder.explainForChild(raw);
      }
      if (token != _token) return;
      final snips = results.map((r) => r.snippet).where((s) => s.isNotEmpty).join(' ');
      setState(() {
        _results = results.take(kMaxItems).toList();
        _images = images.take(math.max(0, kMaxItems - _results.length)).toList();
        _childExplain = ce;
        _summary = (snips.isEmpty || _par.effective == AgeProfile.child)
            ? null
            : Summarizer.summarize(snips, maxSentences: 3, maxChars: 600);
        _loading = false;
        if (_results.isEmpty && _images.isEmpty && ce == null) _error = 'Sin resultados para "$raw".';
      });
    } catch (e) {
      if (token != _token) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo completar la búsqueda: ${_short(e)}';
      });
    }
  }

  /// Búsqueda web según el perfil: SafeSearch, lista blanca (Infantil) y filtros (menores).
  Future<List<SearchItem>> _profileWeb(String q, int limit) async {
    switch (_par.effective) {
      case AgeProfile.adult:
        return SearchService.web(q, limit: limit, kp: _par.safeSearchKp);
      case AgeProfile.teen:
        final rt = await SearchService.web(q, limit: limit + 6, kp: _par.safeSearchKp);
        return rt.where((x) => _par.allowResult(x.url, x.title, x.snippet)).take(limit).toList();
      case AgeProfile.child:
        final sites = SafeFilter.childSiteOperator(_par.extraAllowed);
        var rc = await SearchService.web('$q $sites', limit: limit + 6, kp: _par.safeSearchKp);
        rc = rc.where((x) => _par.allowResult(x.url, x.title, x.snippet)).toList();
        if (rc.length < 3) {
          final w = await SearchService.wikipedia(q, limit);
          final have = rc.map((y) => y.url).toSet();
          rc = [...rc, ...w.where((x) => !have.contains(x.url))];
        }
        return rc.take(limit).toList();
    }
  }

  Future<List<SearchItem>> _extSearch(String q, ChipDef c) async {
    final queries = ['$q filetype:${c.exts.first}', '$q ${c.terms}'];
    final merged = <SearchItem>[];
    final seen = <String>{};
    for (final qq in queries) {
      try {
        final r = await SearchService.web(qq, limit: 10, kp: _par.safeSearchKp);
        for (final it in r) {
          if (seen.add(it.url)) merged.add(it);
        }
      } catch (_) {}
    }
    merged.sort((a, b) {
      final pa = (a.ext != null && c.exts.contains(a.ext)) ? 0 : 1;
      final pb = (b.ext != null && c.exts.contains(b.ext)) ? 0 : 1;
      return pa.compareTo(pb);
    });
    return merged.take(kMaxItems).toList();
  }

  Future<void> _rayosX(Uri input, int token) async {
    var uri = input;
    setState(() => _loading = true);
    try {
      if (uri.scheme != 'https') {
        uri = uri.replace(scheme: 'https');
        _srcNote = 'Se usará HTTPS para analizar el enlace.';
      }
      if (extOfPath(uri.path) != null) {
        setState(() => _loading = false);
        _openDownload(uri);
        return;
      }
      final r = await Net.getBytes(uri, maxBytes: 2 * 1024 * 1024);
      if (token != _token) return;
      if (r.status >= 400) throw HttpException('HTTP ${r.status}');
      if (!r.contentType.contains('html') && !r.contentType.startsWith('text/')) {
        setState(() => _loading = false);
        _openDownload(r.finalUri);
        return;
      }
      final page = PageExtractor.extract(r.text, r.finalUri);
      if (token != _token) return;
      if (_par.isMinor &&
          SafeFilter.textRisk('${page.title} ${page.text.substring(0, math.min(3000, page.text.length))}') != null) {
        setState(() {
          _loading = false;
          _gate = const GateResult.block(
              GateKind.domain, 'Contenido no apto', 'Esta página contiene temas que no están permitidos en tu perfil.');
        });
        return;
      }
      final allowedExts = _par.allowedDownloadExts;
      setState(() {
        _pageTitle = page.title.isEmpty ? r.finalUri.host : page.title;
        _summary = page.text.isEmpty
            ? null
            : Summarizer.summarize(page.text, maxSentences: _par.effective == AgeProfile.child ? 3 : 6, maxChars: 1100);
        _links = page.links.where((l) => allowedExts == null || allowedExts.contains(l.ext)).take(kMaxItems).toList();
        _loading = false;
        if (_summary == null && _links.isEmpty) {
          _error = 'No se encontró texto ni archivos descargables en esa página.';
        } else if (_links.isEmpty) {
          _srcNote = 'Rayos X: sin enlaces descargables detectados.';
        }
      });
    } catch (e) {
      if (token != _token) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo analizar el enlace: ${_short(e)}';
      });
    }
  }

  void _showTool(DynTool tool) {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(kBlack)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) =>
            (r.url.startsWith('about:') || r.url.startsWith('data:')) ? NavigationDecision.navigate : NavigationDecision.prevent,
      ))
      ..loadHtmlString(tool.html);
    setState(() {
      _tool = tool;
      _web = c;
    });
  }

  Future<void> _openDownload(Uri uri) async {
    final g = await _par.gateUrl(uri, ext: extOfPath(uri.path), forDownload: true);
    if (!mounted) return;
    if (!g.allowed) {
      setState(() => _gate = g);
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DownloadPage(uri: uri, vtKey: _vtKey, allowedExts: _par.allowedDownloadExts),
    ));
    _reloadPending();
  }

  void _resumeDownload(PendingDl p) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (_) => DownloadPage(uri: Uri.parse(p.url), vtKey: _vtKey, resume: p),
        ))
        .then((_) => _reloadPending());
  }

  // ---------------------------------------------------------------- historial

  Future<void> _addHistory(String q) async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    final l = List<String>.from(_history)..remove(q);
    l.insert(0, q);
    if (l.length > 30) l.removeRange(30, l.length);
    _history = l;
    await p.setStringList('history', l);
  }

  Future<void> _saveShortcut() async {
    final q = _q.text.trim();
    if (q.isEmpty) {
      _snack('Escribe una consulta para guardarla como atajo.');
      return;
    }
    final p = _prefs ?? await SharedPreferences.getInstance();
    final l = List<String>.from(_shortcuts)..remove(q);
    l.insert(0, q);
    if (l.length > 20) l.removeRange(20, l.length);
    setState(() => _shortcuts = l);
    await p.setStringList('shortcuts', l);
    _snack('Atajo guardado (solo texto).');
  }

  void _openHistory() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kBlack,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget list(List<String> items, bool isShortcut) {
            if (items.isEmpty) {
              return const Center(child: Text('Vacío', style: TextStyle(color: kDim)));
            }
            return ListView.builder(
              itemCount: items.length,
              itemBuilder: (_, i) => ListTile(
                title: Text(items[i], maxLines: 2, overflow: TextOverflow.ellipsis),
                leading: Icon(isShortcut ? Icons.star : Icons.history, color: kWhite),
                trailing: isShortcut
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () async {
                          final l = List<String>.from(_shortcuts)..removeAt(i);
                          setState(() => _shortcuts = l);
                          await _prefs?.setStringList('shortcuts', l);
                          setSheet(() {});
                        },
                      )
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  _search(items[i]);
                },
              ),
            );
          }

          return SafeArea(
            child: DefaultTabController(
              length: 2,
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.6,
                child: Column(
                  children: [
                    const TabBar(
                      indicatorColor: kWhite,
                      labelColor: kWhite,
                      unselectedLabelColor: kDim,
                      tabs: [Tab(text: 'Historial'), Tab(text: 'Atajos')],
                    ),
                    Expanded(child: TabBarView(children: [list(_history, false), list(_shortcuts, true)])),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openSettings() async {
    final c = TextEditingController(text: _vtKey);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ajustes'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'VirusTotal API key (opcional). Si la pones, el SHA-256 de cada archivo también se consulta en VirusTotal. '
                'Sin clave se usa CIRCL hashlookup y la reputación DNS de Cloudflare, sin registro.',
                style: TextStyle(fontSize: 13, color: kDim),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: c,
                obscureText: true,
                decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'API key'),
              ),
              const SizedBox(height: 14),
              const Text(
                'Privacidad: las peticiones usan un perfil neutro (sin cookies persistentes ni Accept-Language). '
                'El historial guarda solo texto. La clave se guarda únicamente en este equipo.',
                style: TextStyle(fontSize: 12, color: kDim),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final p = _prefs ?? await SharedPreferences.getInstance();
              await p.remove('history');
              await p.remove('shortcuts');
              if (mounted) {
                setState(() {
                  _history = [];
                  _shortcuts = [];
                });
              }
              if (ctx.mounted) Navigator.pop(ctx);
              _snack('Historial y atajos borrados.');
            },
            child: const Text('Borrar historial y atajos'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kWhite, foregroundColor: kBlack),
            onPressed: () async {
              final p = _prefs ?? await SharedPreferences.getInstance();
              await p.setString('vtKey', c.text.trim());
              if (mounted) setState(() => _vtKey = c.text.trim());
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    c.dispose();
  }

  // ---------------------------------------------------------------- voz / TTS

  Future<void> _toggleVoice() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    // El micrófono se solicita solo cuando el usuario toca el botón.
    final st = await Permission.microphone.request();
    if (!st.isGranted) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Micrófono denegado. Puedes seguir escribiendo con normalidad.'),
        action: st.isPermanentlyDenied ? SnackBarAction(label: 'Ajustes', onPressed: openAppSettings) : null,
      ));
      return;
    }
    final ok = await _speech.initialize(
      onStatus: (s) {
        if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = false);
      },
      onError: (e) {
        if (mounted) setState(() => _listening = false);
        _snack('Voz: ${e.errorMsg}');
      },
    );
    if (!ok) {
      _snack('El reconocimiento de voz no está disponible en este equipo.');
      return;
    }
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (r) {
        _q.text = r.recognizedWords;
        _q.selection = TextSelection.collapsed(offset: _q.text.length);
        if (r.finalResult) {
          if (mounted) setState(() => _listening = false);
          if (_q.text.trim().isNotEmpty) _search();
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 4),
    );
  }

  Future<void> _speak(String text) async {
    if (_speaking) {
      await _tts.stop();
      if (mounted) setState(() => _speaking = false);
      return;
    }
    setState(() => _speaking = true);
    await _tts.speak(text);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBlack,
      appBar: AppBar(
        title: const Text('WebScout', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: .5)),
        bottom: ParentalStrip(controller: _par, onPanel: _openPanel, onGuides: _openGuides),
        actions: [
          IconButton(tooltip: 'Guardar atajo', icon: const Icon(Icons.star_border), onPressed: _saveShortcut),
          IconButton(tooltip: 'Historial y atajos', icon: const Icon(Icons.history), onPressed: _openHistory),
          IconButton(tooltip: 'Limpiar ahora', icon: const Icon(Icons.cleaning_services_outlined), onPressed: _manualClean),
          IconButton(tooltip: 'Ajustes', icon: const Icon(Icons.tune), onPressed: _openSettings),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(child: _content()),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kPanel,
          border: Border.all(color: kLine),
          borderRadius: BorderRadius.circular(14),
        ),
        child: child,
      );

  Widget _note(String text, Color color) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: TextStyle(color: color, fontSize: 13.5)),
      );

  Widget _content() {
    if (_tool != null && _web != null) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.bolt, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text('Vista dinámica · ${_tool!.title}', style: const TextStyle(fontWeight: FontWeight.w700))),
                IconButton(
                  tooltip: 'Cerrar y destruir vista',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(_destroyDynamic),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: kLine),
          Expanded(child: WebViewWidget(controller: _web!)),
        ],
      );
    }

    if (_par.lock != LockKind.none) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        children: [LockCard(controller: _par, onGuides: _openGuides)],
      );
    }
    final children = <Widget>[];
    if (_pending.isNotEmpty) children.add(_pendingBanner());
    if (_gate != null) {
      children.add(GateCard(
        result: _gate!,
        onAlternative: (q) {
          setState(() => _gate = null);
          _search(q);
        },
        onParentApprove: _gate!.parentCanOverride ? _approveByParent : null,
        onGuides: _gate!.kind == GateKind.timeLock ? _openGuides : null,
      ));
    }
    if (_childExplain != null) {
      children.add(ChildExplainCard(explain: _childExplain!, onSave: () => _saveChildGuide(_childExplain!)));
    }
    if (_loading) {
      children.add(const Padding(
        padding: EdgeInsets.only(bottom: 10),
        child: LinearProgressIndicator(color: kWhite, backgroundColor: Color(0xFF222222)),
      ));
    }
    if (_error != null) children.add(_note(_error!, kBad));
    if (_srcNote != null) children.add(_note(_srcNote!, kDim));
    if (_summary != null) children.add(_summaryCard());
    if (_links.isNotEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.only(bottom: 6, top: 2),
        child: Text('Archivos descargables encontrados', style: TextStyle(fontWeight: FontWeight.w700)),
      ));
      for (final l in _links) {
        children.add(_linkCard(l));
      }
    }
    for (final r in _results) {
      children.add(_resultCard(r));
    }
    if (_images.isNotEmpty) children.add(_imageGrid());
    if (children.isEmpty || (_pending.isNotEmpty && children.length == 1)) children.add(_emptyState());
    return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 16), children: children);
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Busca texto, imágenes o archivos', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text(
            '• Pega una URL para el análisis "Rayos X" (resumen + archivos descargables).\n'
            '• Escribe "mbtiles", "geojson red vial" u "osm.pbf" para filtrar automáticamente.\n'
            '• Pide una herramienta: "calculadora de inversión según la tasa de interés".\n'
            '• Cada descarga pasa por un filtro anti-malware antes de guardarse.',
            style: TextStyle(color: kDim, height: 1.5),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: kWhite, side: const BorderSide(color: kWhite)),
            onPressed: _openGuides,
            icon: const Icon(Icons.menu_book_outlined),
            label: const Text('Guías de estudio'),
          ),
          if (_shortcuts.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text('Atajos', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _shortcuts.take(8).map((s) => _pill(s, false, () => _search(s))).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pendingBanner() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Descargas pendientes', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            for (final p in _pending)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    TextButton(onPressed: () => _resumeDownload(p), child: const Text('Abrir')),
                  ],
                ),
              ),
          ],
        ),
      );

  Widget _summaryCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.notes, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _pageTitle == null ? 'Resumen' : 'Rayos X · $_pageTitle',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(_summary!, style: const TextStyle(height: 1.45)),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: kWhite, side: const BorderSide(color: kWhite)),
                  onPressed: () => _speak(_summary!),
                  icon: Icon(_speaking ? Icons.stop : Icons.volume_up),
                  label: Text(_speaking ? 'Detener' : 'Leer en voz alta'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Copiar resumen',
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _summary!));
                    _snack('Resumen copiado.');
                  },
                ),
              ],
            ),
          ],
        ),
      );

  Widget _linkCard(LinkItem l) => _card(
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: kWhite, borderRadius: BorderRadius.circular(6)),
              child: Text('.${l.ext}', style: const TextStyle(color: kBlack, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(Uri.parse(l.url).host, style: const TextStyle(color: kDim, fontSize: 12)),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Escanear y descargar',
              icon: const Icon(Icons.shield_outlined),
              onPressed: () => _openDownload(Uri.parse(l.url)),
            ),
          ],
        ),
      );

  Widget _resultCard(SearchItem r) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (r.ext != null)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(color: kWhite, borderRadius: BorderRadius.circular(6)),
                  child: Text('.${r.ext}', style: const TextStyle(color: kBlack, fontWeight: FontWeight.w800, fontSize: 11)),
                ),
              Expanded(child: Text(r.host, style: const TextStyle(color: kDim, fontSize: 12), overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 4),
          Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
          if (r.snippet.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(r.snippet, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kDim, fontSize: 13.5, height: 1.35)),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              if (r.ext != null)
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: kWhite, foregroundColor: kBlack),
                  onPressed: () => _openDownload(Uri.parse(r.url)),
                  icon: const Icon(Icons.shield_outlined, size: 18),
                  label: const Text('Escanear'),
                )
              else
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: kWhite, side: const BorderSide(color: kWhite)),
                  onPressed: () {
                    _q.text = r.url;
                    _search();
                  },
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('Rayos X'),
                ),
              const Spacer(),
              IconButton(
                tooltip: 'Copiar enlace',
                icon: const Icon(Icons.link),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: r.url));
                  _snack('Enlace copiado.');
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _imageGrid() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        children: _images
            .map((im) => GestureDetector(
                  onTap: () => _showImage(im),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      im.thumb,
                      cacheWidth: 240,
                      fit: BoxFit.cover,
                      headers: const {'User-Agent': kUA},
                      filterQuality: FilterQuality.low,
                      errorBuilder: (_, __, ___) => Container(
                        color: const Color(0xFF111111),
                        child: const Icon(Icons.broken_image_outlined, color: kDim),
                      ),
                    ),
                  ),
                ))
            .toList(),
      ),
    );
  }

  void _showImage(ImageItem im) {
    final big = im.thumb.replaceFirst('/250px-', '/500px-');
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: kBlack,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: kLine)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
                child: Image.network(
                  big,
                  cacheWidth: 700,
                  fit: BoxFit.contain,
                  headers: const {'User-Agent': kUA},
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, size: 48),
                ),
              ),
              const SizedBox(height: 8),
              Text(im.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: kDim)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: kWhite, foregroundColor: kBlack),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _openDownload(Uri.parse(im.full));
                      },
                      child: const Text('Original (escanear)'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cerrar')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(String label, bool selected, VoidCallback onTap, {IconData? icon}) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? kWhite : kBlack,
          border: Border.all(color: kWhite),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 15, color: selected ? kBlack : kWhite), const SizedBox(width: 5)],
            Text(label, style: TextStyle(color: selected ? kBlack : kWhite, fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return Container(
      decoration: const BoxDecoration(color: kBlack, border: Border(top: BorderSide(color: kLine))),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'RAM ${_rssMb > 0 ? '$_rssMb MB' : '—'} · $_itemsInRam/$kMaxItems elementos · ${_dataSaver ? 'solo texto' : 'con medios'}',
                  style: const TextStyle(fontSize: 11, color: kDim),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _pill('Solo texto', _dataSaver, () async {
                  setState(() => _dataSaver = !_dataSaver);
                  await _prefs?.setBool('dataSaver', _dataSaver);
                }, icon: Icons.data_saver_on),
                for (final c in kChips) ...[
                  const SizedBox(width: 6),
                  _pill(c.label, _chip == c.key, () => setState(() => _chip = c.key)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _q,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  style: const TextStyle(fontSize: 16),
                  decoration: InputDecoration(
                    hintText: 'Buscar, pegar URL o pedir una herramienta',
                    hintStyle: const TextStyle(color: kDim, fontSize: 14),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: kWhite)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: const BorderSide(color: kWhite, width: 2)),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => _q.clear(),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.outlined(
                style: IconButton.styleFrom(
                  side: const BorderSide(color: kWhite),
                  backgroundColor: _listening ? kWhite : kBlack,
                  foregroundColor: _listening ? kBlack : kWhite,
                ),
                tooltip: 'Voz',
                icon: Icon(_listening ? Icons.mic : Icons.mic_none),
                onPressed: _toggleVoice,
              ),
              const SizedBox(width: 4),
              IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: kWhite, foregroundColor: kBlack),
                tooltip: 'Buscar',
                icon: const Icon(Icons.search),
                onPressed: () => _search(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// PANTALLA DE VERIFICACIÓN Y DESCARGA
// ============================================================================

enum Phase { scanning, ready, blocked, downloading, verifying, verified, saving, done, failed }

class DownloadPage extends StatefulWidget {
  final Uri uri;
  final String vtKey;
  final PendingDl? resume;

  /// null = cualquier formato (Adulto); conjunto = solo esos formatos (perfiles menores).
  final Set<String>? allowedExts;
  const DownloadPage({super.key, required this.uri, required this.vtKey, this.resume, this.allowedExts});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  Phase _phase = Phase.scanning;
  List<Finding> _pre = [];
  List<Finding> _post = [];
  PreScan? _scan;
  String _name = 'archivo';
  String _ext = '';
  Uri? _dlUri;
  int? _expectedLen;
  String? _folderUri;
  String? _folderName;
  int? _dlId;
  int _got = 0;
  int _total = -1;
  String _dlState = 'En cola';
  String _step = '';
  String? _local;
  String? _sha;
  String? _savedInfo;
  String? _err;
  Timer? _timer;
  bool _ticking = false;

  @override
  void initState() {
    super.initState();
    final r = widget.resume;
    if (r != null) {
      _name = r.name;
      _ext = r.ext;
      _dlUri = Uri.parse(r.url);
      _dlId = r.id;
      _folderUri = r.folderUri;
      _folderName = r.folderName;
      _expectedLen = r.length;
      _phase = Phase.downloading;
      _startPolling();
    } else {
      _runPre();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Level get _level => worst([..._pre, ..._post]);

  Future<void> _runPre() async {
    try {
      final s = await Scanner.preScan(widget.uri);
      if (!mounted) return;
      setState(() {
        final extra = <Finding>[];
        final allowed = widget.allowedExts;
        if (allowed != null && !allowed.contains(s.ext)) {
          extra.add(Finding(Level.danger, 'Formato no permitido por el perfil de edad',
              allowed.isEmpty ? 'Las descargas están bloqueadas en este perfil.' : 'Solo se permiten: ${allowed.map((e) => '.$e').join(', ')}.'));
        }
        _scan = s;
        _pre = [...s.findings, ...extra];
        _name = s.name;
        _ext = s.ext;
        _dlUri = s.finalUri;
        _expectedLen = s.length;
        _phase = worst(_pre) == Level.danger ? Phase.blocked : Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = Phase.failed;
        _err = 'No se pudo analizar el enlace: ${_short(e)}';
      });
    }
  }

  Future<bool> _confirm(String title, String body, String yes, {String no = 'Cancelar'}) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(no)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kWhite, foregroundColor: kBlack),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(yes),
          ),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _pickFolder() async {
    try {
      final u = await Native.pickFolder();
      if (u == null || !mounted) return;
      final d = Uri.decodeComponent(u.split('/').last);
      setState(() {
        _folderUri = u;
        _folderName = d.startsWith('primary:')
            ? 'Almacenamiento interno · ${d.substring(8)}'
            : 'microSD / volumen · $d';
      });
    } catch (e) {
      _snack('No se pudo abrir el selector: ${_short(e)}');
    }
  }

  Future<void> _askNotifications() async {
    try {
      final st = await Permission.notification.status;
      if (st.isGranted || !mounted) return;
      final go = await _confirm(
        'Notificaciones de progreso',
        'Android mostrará el avance de la descarga en una notificación para que no se pierda si sales de la app. '
            'Es opcional: si la rechazas, la descarga continúa igual.',
        'Permitir',
        no: 'Ahora no',
      );
      if (go) await Permission.notification.request();
    } catch (_) {}
  }

  Future<void> _start() async {
    final lvl = _level;
    if (lvl == Level.warn) {
      final warns = _pre.where((f) => f.level == Level.warn).map((f) => '• ${f.title}').join('\n');
      final ok = await _confirm('Continuar con advertencias', '$warns\n\n¿Quieres descargar de todos modos?', 'Descargar');
      if (!ok) return;
    }
    if (kRisky.contains(_ext)) {
      final ok = await _confirm(
        'Archivo ejecutable o instalable',
        'Este tipo de archivo puede instalar o ejecutar código. Solo se descargará a una zona temporal y se analizará antes de guardarlo.',
        'Continuar',
      );
      if (!ok) return;
    }
    await _askNotifications();
    if (!mounted) return;
    try {
      final id = await Native.enqueue(_dlUri.toString(), _name);
      await PendingStore.add(PendingDl(
        id: id,
        url: _dlUri.toString(),
        name: _name,
        ext: _ext,
        folderUri: _folderUri,
        folderName: _folderName,
        length: _expectedLen,
      ));
      if (!mounted) return;
      setState(() {
        _dlId = id;
        _phase = Phase.downloading;
      });
      _startPolling();
    } catch (e) {
      setState(() {
        _phase = Phase.failed;
        _err = 'No se pudo iniciar la descarga: ${_short(e)}';
      });
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  static const Map<int, String> _pauseReasons = {
    1: 'Esperando para reintentar…',
    2: 'En pausa: esperando red (se reanudará sola)',
    3: 'En pausa: esperando Wi-Fi',
    4: 'En pausa',
  };

  Future<void> _tick() async {
    if (_ticking || _dlId == null) return;
    _ticking = true;
    try {
      final m = await Native.query(_dlId!);
      if (!mounted) return;
      final status = (m['status'] as num?)?.toInt() ?? -1;
      final got = (m['downloaded'] as num?)?.toInt() ?? 0;
      final total = (m['total'] as num?)?.toInt() ?? -1;
      if (status == 8) {
        _timer?.cancel();
        setState(() {
          _got = got;
          _total = total;
        });
        await _onDownloaded(m['local'] as String?);
      } else if (status == 16) {
        _timer?.cancel();
        await PendingStore.remove(_dlId!);
        if (!mounted) return;
        setState(() {
          _phase = Phase.failed;
          _err = 'La descarga falló (código ${m['reason']}). Revisa el enlace o tu conexión.';
        });
      } else if (status == -1) {
        _timer?.cancel();
        await PendingStore.remove(_dlId!);
        if (!mounted) return;
        setState(() {
          _phase = Phase.failed;
          _err = 'La descarga fue cancelada o ya no existe.';
        });
      } else {
        setState(() {
          _got = got;
          _total = total;
          _dlState = status == 4
              ? (_pauseReasons[(m['reason'] as num?)?.toInt() ?? 4] ?? 'En pausa')
              : (status == 1 ? 'En cola' : 'Descargando');
        });
      }
    } catch (_) {
    } finally {
      _ticking = false;
    }
  }

  Future<void> _onDownloaded(String? local) async {
    if (local == null || !File(local).existsSync()) {
      await PendingStore.remove(_dlId!);
      if (!mounted) return;
      setState(() {
        _phase = Phase.failed;
        _err = 'No se encontró el archivo descargado.';
      });
      return;
    }
    setState(() {
      _local = local;
      _phase = Phase.verifying;
      _step = 'Iniciando análisis…';
    });
    try {
      final res = await Scanner.postScan(
        File(local),
        _ext,
        _total > 0 ? _total : _expectedLen,
        widget.vtKey,
        onStep: (s) {
          if (mounted) setState(() => _step = s);
        },
      );
      if (!mounted) return;
      if (res.level == Level.danger) {
        await Native.deleteTemp(local);
        await PendingStore.remove(_dlId!);
        if (!mounted) return;
        setState(() {
          _post = res.findings;
          _sha = res.sha;
          _phase = Phase.failed;
          _err = 'El archivo fue ELIMINADO por seguridad: el análisis detectó una alerta.';
        });
        return;
      }
      setState(() {
        _post = res.findings;
        _sha = res.sha;
        _phase = Phase.verified;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = Phase.failed;
        _err = 'Falló la verificación: ${_short(e)}';
      });
    }
  }

  Future<void> _save() async {
    final path = _local;
    if (path == null) return;
    if (_level == Level.warn) {
      final ok = await _confirm('Hay advertencias', 'El análisis dejó advertencias. ¿Guardar el archivo de todos modos?', 'Guardar');
      if (!ok) return;
    }
    if (kRisky.contains(_ext)) {
      final a = await _confirm(
        'Confirmación 1 de 2',
        'Vas a guardar un archivo ejecutable/instalable. Instalarlo puede comprometer tu equipo y tus datos. Revisa el estado del hash antes de continuar.',
        'Entiendo el riesgo',
      );
      if (!a) return;
      final b = await _confirm(
        'Confirmación 2 de 2',
        '¿Confirmas que confías en el origen de "$_name" y deseas guardarlo?',
        'Sí, guardar',
      );
      if (!b) return;
    }
    setState(() => _phase = Phase.saving);
    try {
      final mime = mimeFor(_ext);
      final info = _folderUri == null
          ? await Native.saveToDownloads(path, _name, mime)
          : await Native.saveToTree(path, _folderUri!, _name, mime);
      await Native.deleteTemp(path);
      await PendingStore.remove(_dlId!);
      if (!mounted) return;
      setState(() {
        _savedInfo = _folderUri == null ? info : (_folderName ?? 'Carpeta elegida');
        _phase = Phase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = Phase.verified;
      });
      _snack('No se pudo guardar: ${_short(e)}');
    }
  }

  Future<void> _discard() async {
    final path = _local;
    if (path != null) await Native.deleteTemp(path);
    if (_dlId != null) await PendingStore.remove(_dlId!);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _cancelDownload() async {
    _timer?.cancel();
    if (_dlId != null) {
      try {
        await Native.cancel(_dlId!);
      } catch (_) {}
      await PendingStore.remove(_dlId!);
    }
    if (mounted) Navigator.pop(context);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Widget _tile(Finding f) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(levelIcon(f.level), color: levelColor(f.level), size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(f.title, style: TextStyle(fontWeight: FontWeight.w700, color: f.level == Level.info ? kDim : kWhite)),
                  if (f.detail.isNotEmpty) Text(f.detail, style: const TextStyle(color: kDim, fontSize: 12.5, height: 1.35)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _box(Widget child) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: kPanel, border: Border.all(color: kLine), borderRadius: BorderRadius.circular(14)),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final all = [..._pre, ..._post];
    final lvl = worst(all);
    final showVerdict = all.isNotEmpty && _phase != Phase.scanning;
    return Scaffold(
      backgroundColor: kBlack,
      appBar: AppBar(title: const Text('Verificar y descargar')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
          children: [
            _box(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                SelectableText((_dlUri ?? widget.uri).toString(), style: const TextStyle(color: kDim, fontSize: 12)),
                if (_expectedLen != null && _expectedLen! >= 0) ...[
                  const SizedBox(height: 4),
                  Text('Peso: ${fmtBytes(_expectedLen!)}', style: const TextStyle(color: kDim, fontSize: 12.5)),
                ],
              ],
            )),
            if (showVerdict)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: levelColor(lvl), width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(levelIcon(lvl), color: levelColor(lvl)),
                    const SizedBox(width: 10),
                    Text(verdictLabel(lvl), style: TextStyle(color: levelColor(lvl), fontWeight: FontWeight.w900, fontSize: 16, letterSpacing: .6)),
                  ],
                ),
              ),
            if (_phase == Phase.scanning)
              _box(const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(color: kWhite, backgroundColor: Color(0xFF222222)),
                  SizedBox(height: 10),
                  Text('Analizando URL, reputación, cabeceras HEAD y Magic Bytes…'),
                ],
              )),
            if (_pre.isNotEmpty)
              _box(Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Antes de descargar', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  ..._pre.map(_tile),
                ],
              )),
            if (_post.isNotEmpty)
              _box(Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Después de descargar', style: TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  ..._post.map(_tile),
                  if (_sha != null) ...[
                    const SizedBox(height: 6),
                    const Text('SHA-256', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                    SelectableText(_sha!, style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: kDim)),
                  ],
                ],
              )),
            ..._controls(),
          ],
        ),
      ),
    );
  }

  List<Widget> _controls() {
    switch (_phase) {
      case Phase.scanning:
        return [];
      case Phase.blocked:
        return [
          _box(const Text(
            'Descarga bloqueada por seguridad. Busca otra fuente del archivo.',
            style: TextStyle(color: kBad, fontWeight: FontWeight.w600),
          )),
          _bigButton('Cerrar', Icons.close, () => Navigator.pop(context), outlined: true),
        ];
      case Phase.ready:
        return [
          _box(Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Destino', style: TextStyle(fontWeight: FontWeight.w800)),
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                activeColor: kWhite,
                value: false,
                groupValue: _folderUri != null,
                onChanged: (_) => setState(() {
                  _folderUri = null;
                  _folderName = null;
                }),
                title: const Text('Descargas (predeterminado)'),
              ),
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                activeColor: kWhite,
                value: true,
                groupValue: _folderUri != null,
                onChanged: (_) => _pickFolder(),
                title: Text(_folderName ?? 'Elegir carpeta (interna o microSD)'),
                subtitle: _folderName == null ? null : const Text('Toca para cambiar'),
              ),
            ],
          )),
          _bigButton('Descargar', Icons.download, _start),
        ];
      case Phase.downloading:
        final pct = _total > 0 ? (_got / _total).clamp(0.0, 1.0) : null;
        return [
          _box(Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_dlState, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: pct, color: kWhite, backgroundColor: const Color(0xFF222222), minHeight: 6),
              const SizedBox(height: 8),
              Text(
                _total > 0 ? '${fmtBytes(_got)} / ${fmtBytes(_total)}  (${(pct! * 100).toStringAsFixed(1)}%)' : fmtBytes(_got),
                style: const TextStyle(color: kDim),
              ),
              const SizedBox(height: 8),
              const Text(
                'La descarga la gestiona Android (reanudable y con notificación). Puedes salir de esta pantalla: '
                'volverá a aparecer en "Descargas pendientes".',
                style: TextStyle(color: kDim, fontSize: 12.5),
              ),
            ],
          )),
          _bigButton('Cancelar descarga', Icons.cancel_outlined, _cancelDownload, outlined: true),
        ];
      case Phase.verifying:
        return [
          _box(Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const LinearProgressIndicator(color: kWhite, backgroundColor: Color(0xFF222222)),
              const SizedBox(height: 10),
              Text(_step),
            ],
          )),
        ];
      case Phase.verified:
        return [
          _box(Text(
            _folderUri == null ? 'Se guardará en: Descargas' : 'Se guardará en: ${_folderName ?? 'carpeta elegida'}',
            style: const TextStyle(color: kDim),
          )),
          _bigButton('Guardar archivo', Icons.save_alt, _save),
          const SizedBox(height: 8),
          _bigButton('Descartar', Icons.delete_outline, _discard, outlined: true),
        ];
      case Phase.saving:
        return [
          _box(const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(color: kWhite, backgroundColor: Color(0xFF222222)),
              SizedBox(height: 10),
              Text('Copiando al destino en streaming…'),
            ],
          )),
        ];
      case Phase.done:
        return [
          _box(Row(
            children: [
              const Icon(Icons.check_circle, color: kOk),
              const SizedBox(width: 10),
              Expanded(child: Text('Guardado en: ${_savedInfo ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700))),
            ],
          )),
          if (kRisky.contains(_ext))
            _box(const Text(
              'Para instalar un APK ábrelo desde la app Archivos de Android; el sistema pedirá su propia autorización.',
              style: TextStyle(color: kDim, fontSize: 12.5),
            )),
          if (_sha != null)
            _bigButton('Copiar SHA-256', Icons.copy, () {
              Clipboard.setData(ClipboardData(text: _sha!));
              _snack('SHA-256 copiado.');
            }, outlined: true),
          const SizedBox(height: 8),
          _bigButton('Listo', Icons.check, () => Navigator.pop(context)),
        ];
      case Phase.failed:
        return [
          _box(Text(_err ?? 'Error', style: const TextStyle(color: kBad, fontWeight: FontWeight.w600))),
          _bigButton('Cerrar', Icons.close, () => Navigator.pop(context), outlined: true),
        ];
    }
  }

  Widget _bigButton(String label, IconData icon, VoidCallback onTap, {bool outlined = false}) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [Icon(icon), const SizedBox(width: 8), Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))],
    );
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: outlined
          ? OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: kWhite, side: const BorderSide(color: kWhite)),
              onPressed: onTap,
              child: child,
            )
          : FilledButton(
              style: FilledButton.styleFrom(backgroundColor: kWhite, foregroundColor: kBlack),
              onPressed: onTap,
              child: child,
            ),
    );
  }
}
