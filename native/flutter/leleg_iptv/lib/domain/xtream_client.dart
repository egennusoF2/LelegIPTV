import 'dart:convert';
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class XtreamProfile {
  const XtreamProfile({
    required this.serverUrl,
    required this.username,
    required this.password,
    this.id = '',
    this.title = '',
    this.liveContainer = 'm3u8',
  });

  final String id;
  final String title;
  final String serverUrl;
  final String username;
  final String password;
  final String liveContainer;

  String get baseUrl => _normalizeBaseUrl(serverUrl);

  String get displayName {
    final cleanTitle = title.trim();
    if (cleanTitle.isNotEmpty) return cleanTitle;
    final host = baseUrl.replaceFirst(RegExp(r'^https?://'), '');
    return host.isEmpty ? 'Playlist Xtream' : host;
  }

  bool get isComplete =>
      baseUrl.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  Map<String, String> toJson() => {
    'id': id,
    'title': title,
    'serverUrl': serverUrl,
    'username': username,
    'password': password,
    'liveContainer': liveContainer,
  };

  static XtreamProfile fromJson(Map<String, dynamic> json) => XtreamProfile(
    id: json['id']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    serverUrl: json['serverUrl']?.toString() ?? '',
    username: json['username']?.toString() ?? '',
    password: json['password']?.toString() ?? '',
    liveContainer: json['liveContainer']?.toString() == 'ts' ? 'ts' : 'm3u8',
  );

  XtreamProfile copyWith({
    String? id,
    String? title,
    String? serverUrl,
    String? username,
    String? password,
    String? liveContainer,
  }) {
    return XtreamProfile(
      id: id ?? this.id,
      title: title ?? this.title,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      liveContainer: liveContainer ?? this.liveContainer,
    );
  }

  static String _normalizeBaseUrl(String input) {
    var value = input.trim();
    if (value.isEmpty) return '';
    if (!value.startsWith(RegExp(r'https?://', caseSensitive: false))) {
      value = 'http://$value';
    }
    return value.replaceAll(RegExp(r'/+$'), '');
  }
}

class XtreamClient {
  XtreamClient(this.profile, {http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final XtreamProfile profile;
  final http.Client _http;

  Map<String, String> get _headers => {
    'Accept': 'application/json,text/plain,*/*',
    'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
    'Referer': '${profile.baseUrl}/',
  };

  Uri apiUri(String action, [Map<String, String> params = const {}]) {
    return Uri.parse('${profile.baseUrl}/player_api.php').replace(
      queryParameters: {
        'username': profile.username,
        'password': profile.password,
        if (action.isNotEmpty) 'action': action,
        ...params,
      },
    );
  }

  Future<XtreamAccountInfo> accountInfo() async {
    final json = await _getJson(
      'get_account_info',
      apiUri('get_account_info'),
      timeout: const Duration(seconds: 30),
    );
    return XtreamAccountInfo.fromJson(json);
  }

  Future<List<LiveChannel>> liveStreams() async {
    final json = await _getJson(
      'get_live_streams',
      apiUri('get_live_streams'),
      timeout: const Duration(seconds: 75),
    );
    final list = _asList(json, 'streams');
    return list.map(LiveChannel.fromJson).where((item) => item.id > 0).toList();
  }

  Future<List<XtreamCategory>> liveCategories() {
    return _categories('get_live_categories');
  }

  Future<List<XtreamCategory>> vodCategories() {
    return _categories('get_vod_categories');
  }

  Future<List<XtreamCategory>> seriesCategories() {
    return _categories('get_series_categories');
  }

  Future<List<VodMovie>> vodStreams() async {
    final json = await _getJson(
      'get_vod_streams',
      apiUri('get_vod_streams'),
      timeout: const Duration(seconds: 150),
    );
    final list = _asList(json, 'movies');
    return list.map(VodMovie.fromJson).where((item) => item.id > 0).toList();
  }

  Future<List<SeriesShow>> seriesStreams() async {
    final json = await _getJson(
      'get_series',
      apiUri('get_series'),
      timeout: const Duration(seconds: 150),
    );
    final list = _asList(json, 'series');
    return list.map(SeriesShow.fromJson).where((item) => item.id > 0).toList();
  }

  Future<List<EpgProgramme>> shortEpg(
    LiveChannel channel, {
    int limit = 12,
  }) async {
    final json = await _getJson(
      'get_short_epg',
      apiUri('get_short_epg', {
        'stream_id': channel.id.toString(),
        'limit': limit.toString(),
      }),
      timeout: const Duration(seconds: 45),
    );
    final map = json is Map ? json : const {};
    final raw =
        map['epg_listings'] ??
        map['epg_list'] ??
        map['epg'] ??
        map['programmes'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) {
          return EpgProgramme.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
          );
        })
        .where((item) => item.title.isNotEmpty)
        .toList();
  }

  Future<Map<int, List<EpgProgramme>>> xmlTvEpgForChannels(
    List<LiveChannel> channels, {
    int limit = 16,
  }) async {
    if (channels.isEmpty) return const {};
    final body = await _getText(
      'xmltv',
      Uri.parse('${profile.baseUrl}/xmltv.php').replace(
        queryParameters: {
          'username': profile.username,
          'password': profile.password,
        },
      ),
      timeout: const Duration(seconds: 120),
    );
    // ignore: avoid_print
    print('[leleg:epg] xmltv bytes=${body.length} channels=${channels.length}');
    final document = XmlDocument.parse(body);
    final channelNames = <String, String>{};
    for (final node in document.findAllElements('channel')) {
      final id = node.getAttribute('id')?.trim().toLowerCase() ?? '';
      if (id.isEmpty) continue;
      final displayName = node
          .findElements('display-name')
          .map((item) => item.innerText.trim())
          .firstWhere((item) => item.isNotEmpty, orElse: () => id);
      channelNames[id] = displayName;
    }

    final nameIndex = _buildUniqueNameIndex(channelNames);
    final keysByChannelId = <int, String>{};
    final wantedKeys = <String>{};
    for (final channel in channels) {
      final key = _resolveXmlTvKey(channel, channelNames, nameIndex);
      if (key.isEmpty) continue;
      keysByChannelId[channel.id] = key;
      wantedKeys.add(key);
    }
    // ignore: avoid_print
    print(
      '[leleg:epg] xmltv channelNames=${channelNames.length} mapped=${keysByChannelId.length}',
    );
    if (wantedKeys.isEmpty) return const {};

    final now = DateTime.now();
    final channelById = {for (final channel in channels) channel.id: channel};
    final channelIdByKey = <String, int>{};
    for (final entry in keysByChannelId.entries) {
      channelIdByKey.putIfAbsent(entry.value, () => entry.key);
    }
    final byKey = <String, List<EpgProgramme>>{};
    for (final node in document.findAllElements('programme')) {
      final key = node.getAttribute('channel')?.trim().toLowerCase() ?? '';
      if (!wantedKeys.contains(key)) continue;
      final programme = EpgProgramme.fromXml(node);
      if (programme.title.isEmpty) continue;
      final end = programme.end;
      final channelId = channelIdByKey[key];
      final channel = channelId == null ? null : channelById[channelId];
      if (end != null &&
          end.isBefore(now.subtract(const Duration(minutes: 30))) &&
          !_canReplayProgramme(channel, programme, now)) {
        continue;
      }
      byKey.putIfAbsent(key, () => []).add(programme);
    }

    final result = <int, List<EpgProgramme>>{};
    for (final entry in keysByChannelId.entries) {
      final channel = channelById[entry.key];
      final replayDays = channel == null || channel.catchupDays <= 0
          ? 1
          : channel.catchupDays;
      final lowerBound = now.subtract(Duration(hours: replayDays > 1 ? 24 : 8));
      final upperBound = now.add(const Duration(hours: 24));
      final programmes =
          (byKey[entry.value] ?? const <EpgProgramme>[]).where((programme) {
            final start = programme.start;
            final end = programme.end;
            if (start == null || end == null) return false;
            return end.isAfter(lowerBound) && start.isBefore(upperBound);
          }).toList()..sort((a, b) {
            final aStart = a.start;
            final bStart = b.start;
            if (aStart == null && bStart == null) return 0;
            if (aStart == null) return 1;
            if (bStart == null) return -1;
            return aStart.compareTo(bStart);
          });
      result[entry.key] = programmes.take(limit).toList();
    }
    final totalProgrammes = result.values.fold<int>(
      0,
      (count, programmes) => count + programmes.length,
    );
    // ignore: avoid_print
    print('[leleg:epg] xmltv programmes=$totalProgrammes');
    return result;
  }

  Future<List<SeriesEpisode>> seriesEpisodes(SeriesShow show) async {
    final json = await _getJson(
      'get_series_info',
      apiUri('get_series_info', {'series_id': show.id.toString()}),
      timeout: const Duration(seconds: 75),
    );
    final map = json is Map ? json : const {};
    final rawEpisodes = map['episodes'];
    final episodes = <SeriesEpisode>[];
    if (rawEpisodes is Map) {
      for (final entry in rawEpisodes.entries) {
        final seasonNumber = int.tryParse(entry.key.toString()) ?? 0;
        final rawSeason = entry.value;
        if (rawSeason is! List) continue;
        for (final item in rawSeason.whereType<Map>()) {
          episodes.add(
            SeriesEpisode.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
              seasonNumber,
            ),
          );
        }
      }
    } else if (rawEpisodes is List) {
      for (final item in rawEpisodes.whereType<Map>()) {
        episodes.add(
          SeriesEpisode.fromJson(
            item.map((key, value) => MapEntry(key.toString(), value)),
            0,
          ),
        );
      }
    }
    episodes.sort((a, b) {
      final season = a.season.compareTo(b.season);
      if (season != 0) return season;
      return a.episode.compareTo(b.episode);
    });
    return episodes.where((item) => item.id > 0).toList();
  }

  String liveUrl(LiveChannel channel) {
    final ext = profile.liveContainer == 'ts' ? 'ts' : 'm3u8';
    return '${profile.baseUrl}/live/${Uri.encodeComponent(profile.username)}/'
        '${Uri.encodeComponent(profile.password)}/${channel.id}.$ext';
  }

  String? catchupUrl(LiveChannel channel, EpgProgramme programme) {
    if (!_canReplayProgramme(channel, programme, DateTime.now())) return null;
    final start = programme.start;
    final end = programme.end;
    if (start == null || end == null) return null;
    final durationMinutes = (end.difference(start).inSeconds / 60).ceil();
    final safeDuration = durationMinutes < 1 ? 1 : durationMinutes;
    final ext = profile.liveContainer == 'ts' ? 'ts' : 'm3u8';
    return '${profile.baseUrl}/timeshift/'
        '${Uri.encodeComponent(profile.username)}/'
        '${Uri.encodeComponent(profile.password)}/'
        '$safeDuration/'
        '${Uri.encodeComponent(_formatXtreamCatchupStart(start))}/'
        '${channel.id}.$ext';
  }

  String vodUrl(VodMovie movie) {
    final ext = movie.containerExtension.isEmpty
        ? 'mp4'
        : movie.containerExtension;
    return '${profile.baseUrl}/movie/${Uri.encodeComponent(profile.username)}/'
        '${Uri.encodeComponent(profile.password)}/${movie.id}.$ext';
  }

  String episodeUrl(SeriesEpisode episode) {
    final ext = episode.containerExtension.isEmpty
        ? 'mp4'
        : episode.containerExtension;
    return '${profile.baseUrl}/series/${Uri.encodeComponent(profile.username)}/'
        '${Uri.encodeComponent(profile.password)}/${episode.id}.$ext';
  }

  Future<List<XtreamCategory>> _categories(String action) async {
    final json = await _getJson(
      action,
      apiUri(action),
      timeout: const Duration(seconds: 45),
    );
    final list = _asList(json, 'categories');
    return list
        .map(XtreamCategory.fromJson)
        .where((item) => item.id.isNotEmpty)
        .toList();
  }

  Future<dynamic> _getJson(
    String action,
    Uri uri, {
    required Duration timeout,
  }) async {
    http.Response response;
    try {
      response = await _http.get(uri, headers: _headers).timeout(timeout);
    } on TimeoutException {
      throw XtreamException(
        '$action timed out after ${timeout.inSeconds}s: ${uri.host}',
      );
    } catch (error) {
      throw XtreamException('$action network error: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw XtreamException(
        '$action HTTP ${response.statusCode}: ${uri.host}${uri.path}',
      );
    }
    try {
      return jsonDecode(response.body);
    } catch (error) {
      final preview = response.body.length > 120
          ? response.body.substring(0, 120)
          : response.body;
      throw XtreamException('$action invalid JSON: $preview');
    }
  }

  Future<String> _getText(
    String action,
    Uri uri, {
    required Duration timeout,
  }) async {
    http.Response response;
    try {
      response = await _http.get(uri, headers: _headers).timeout(timeout);
    } on TimeoutException {
      throw XtreamException(
        '$action timed out after ${timeout.inSeconds}s: ${uri.host}',
      );
    } catch (error) {
      throw XtreamException('$action network error: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw XtreamException(
        '$action HTTP ${response.statusCode}: ${uri.host}${uri.path}',
      );
    }
    return response.body;
  }

  List<Map<String, dynamic>> _asList(dynamic json, String fallbackKey) {
    final raw = json is List ? json : (json is Map ? json[fallbackKey] : null);
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList();
  }

  Map<String, String> _buildUniqueNameIndex(Map<String, String> channelNames) {
    final index = <String, String>{};
    final duplicateNames = <String>{};
    for (final entry in channelNames.entries) {
      final normalized = _normalizeGuideName(entry.value);
      if (normalized.isEmpty) continue;
      final existing = index[normalized];
      if (existing == null) {
        index[normalized] = entry.key;
      } else if (existing != entry.key) {
        duplicateNames.add(normalized);
      }
    }
    for (final duplicate in duplicateNames) {
      index.remove(duplicate);
    }
    return index;
  }

  String _resolveXmlTvKey(
    LiveChannel channel,
    Map<String, String> channelNames,
    Map<String, String> nameIndex,
  ) {
    final rawTvgId = channel.tvgId.trim().toLowerCase();
    if (rawTvgId.isNotEmpty && channelNames.containsKey(rawTvgId)) {
      return rawTvgId;
    }
    final streamId = channel.id.toString();
    if (channelNames.containsKey(streamId)) return streamId;
    final byName = nameIndex[_normalizeGuideName(channel.name)];
    return byName ?? '';
  }

  String _normalizeGuideName(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'\[[^\]]+\]'), ' ')
        .replaceAll(RegExp(r'\|[^|]*\|'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  bool _canReplayProgramme(
    LiveChannel? channel,
    EpgProgramme programme,
    DateTime now,
  ) {
    if (channel == null || !channel.hasCatchup) return false;
    final start = programme.start;
    final end = programme.end;
    if (start == null || end == null) return false;
    if (end.isAfter(now) || !end.isAfter(start)) return false;
    final windowDays = channel.catchupDays > 0 ? channel.catchupDays : 7;
    return start.isAfter(now.subtract(Duration(days: windowDays)));
  }

  String _formatXtreamCatchupStart(DateTime value) {
    String pad(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${pad(value.month)}-${pad(value.day)}:'
        '${pad(value.hour)}-${pad(value.minute)}';
  }
}

class XtreamException implements Exception {
  const XtreamException(this.message);
  final String message;

  @override
  String toString() => message;
}

class XtreamAccountInfo {
  const XtreamAccountInfo({
    required this.username,
    required this.status,
    required this.expiresAt,
    required this.activeConnections,
    required this.maxConnections,
  });

  final String username;
  final String status;
  final DateTime? expiresAt;
  final int activeConnections;
  final int maxConnections;

  factory XtreamAccountInfo.fromJson(dynamic json) {
    final map = json is Map ? json : const {};
    final userInfo = map['user_info'] is Map ? map['user_info'] as Map : map;
    final exp = int.tryParse(userInfo['exp_date']?.toString() ?? '');
    return XtreamAccountInfo(
      username: userInfo['username']?.toString() ?? '',
      status: userInfo['status']?.toString() ?? '',
      expiresAt: exp == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(exp * 1000),
      activeConnections:
          int.tryParse(userInfo['active_cons']?.toString() ?? '') ?? 0,
      maxConnections:
          int.tryParse(userInfo['max_connections']?.toString() ?? '') ?? 0,
    );
  }
}

class XtreamCategory {
  const XtreamCategory({required this.id, required this.name});

  final String id;
  final String name;

  factory XtreamCategory.fromJson(Map<String, dynamic> json) => XtreamCategory(
    id: json['category_id']?.toString() ?? '',
    name: json['category_name']?.toString() ?? 'Categoria',
  );

  Map<String, dynamic> toJson() => {'category_id': id, 'category_name': name};
}

class LiveChannel {
  const LiveChannel({
    required this.id,
    required this.name,
    required this.logo,
    required this.categoryId,
    required this.tvgId,
    required this.catchup,
    required this.catchupDays,
  });

  final int id;
  final String name;
  final String logo;
  final String categoryId;
  final String tvgId;
  final String catchup;
  final int catchupDays;

  bool get hasCatchup => catchup.isNotEmpty || catchupDays > 0;

  factory LiveChannel.fromJson(Map<String, dynamic> json) => LiveChannel(
    id: int.tryParse(json['stream_id']?.toString() ?? '') ?? 0,
    name: json['name']?.toString() ?? 'Channel',
    logo: json['stream_icon']?.toString() ?? '',
    categoryId: json['category_id']?.toString() ?? '',
    tvgId:
        (json['epg_channel_id'] ?? json['tvg_id'] ?? json['tvgId'])
            ?.toString() ??
        '',
    catchup: _parseCatchupMode(json),
    catchupDays:
        int.tryParse(
          (json['tv_archive_duration'] ?? json['catchupDays'])?.toString() ??
              '',
        ) ??
        0,
  );

  Map<String, dynamic> toJson() => {
    'stream_id': id,
    'name': name,
    'stream_icon': logo,
    'category_id': categoryId,
    'epg_channel_id': tvgId,
    'catchup': catchup,
    'tv_archive': catchup == 'xtream' ? 1 : 0,
    'tv_archive_duration': catchupDays,
  };

  static String _parseCatchupMode(Map<String, dynamic> json) {
    final explicit = (json['catchup'] ?? '').toString().trim();
    if (explicit.isNotEmpty) return explicit;
    final archive = int.tryParse(json['tv_archive']?.toString() ?? '') ?? 0;
    return archive > 0 ? 'xtream' : '';
  }
}

class EpgProgramme {
  const EpgProgramme({
    required this.title,
    required this.description,
    required this.start,
    required this.end,
  });

  final String title;
  final String description;
  final DateTime? start;
  final DateTime? end;

  factory EpgProgramme.fromJson(Map<String, dynamic> json) => EpgProgramme(
    title: _decodeMaybeBase64(
      (json['title'] ?? json['title_raw'])?.toString() ?? '',
    ),
    description: _decodeMaybeBase64(
      (json['description'] ?? json['description_raw'])?.toString() ?? '',
    ),
    start: _parseXtreamDate(json['start'] ?? json['start_timestamp']),
    end: _parseXtreamDate(
      json['end'] ??
          json['stop'] ??
          json['stop_timestamp'] ??
          json['end_timestamp'],
    ),
  );

  factory EpgProgramme.fromXml(XmlElement node) => EpgProgramme(
    title: node
        .findElements('title')
        .map((item) => item.innerText.trim())
        .firstWhere((item) => item.isNotEmpty, orElse: () => ''),
    description: node
        .findElements('desc')
        .map((item) => item.innerText.trim())
        .firstWhere((item) => item.isNotEmpty, orElse: () => ''),
    start: _parseXmlTvDate(node.getAttribute('start')),
    end: _parseXmlTvDate(node.getAttribute('stop')),
  );

  static String _decodeMaybeBase64(String value) {
    if (value.trim().isEmpty) return '';
    try {
      return utf8.decode(base64.decode(value));
    } catch (_) {
      return value;
    }
  }

  static DateTime? _parseXtreamDate(dynamic value) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) return null;
    final unix = int.tryParse(text);
    if (unix != null) {
      final normalized = unix > 20000000000 ? unix : unix * 1000;
      return DateTime.fromMillisecondsSinceEpoch(normalized);
    }
    return DateTime.tryParse(text);
  }

  static DateTime? _parseXmlTvDate(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final match = RegExp(
      r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-]\d{4}))?',
    ).firstMatch(text);
    if (match == null) return DateTime.tryParse(text);
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    final hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final second = int.parse(match.group(6)!);
    final offset = match.group(7);
    var utc = DateTime.utc(year, month, day, hour, minute, second);
    if (offset != null) {
      final sign = offset.startsWith('-') ? -1 : 1;
      final offsetHours = int.parse(offset.substring(1, 3));
      final offsetMinutes = int.parse(offset.substring(3, 5));
      utc = utc.subtract(
        Duration(minutes: sign * ((offsetHours * 60) + offsetMinutes)),
      );
    }
    return utc.toLocal();
  }
}

class VodMovie {
  const VodMovie({
    required this.id,
    required this.name,
    required this.logo,
    required this.containerExtension,
    required this.rating,
    required this.categoryId,
  });

  final int id;
  final String name;
  final String logo;
  final String containerExtension;
  final String rating;
  final String categoryId;

  factory VodMovie.fromJson(Map<String, dynamic> json) => VodMovie(
    id: int.tryParse((json['stream_id'] ?? json['id'])?.toString() ?? '') ?? 0,
    name: (json['name'] ?? json['title'])?.toString() ?? 'Movie',
    logo: (json['stream_icon'] ?? json['cover'])?.toString() ?? '',
    containerExtension: json['container_extension']?.toString() ?? 'mp4',
    rating: json['rating']?.toString() ?? '',
    categoryId: json['category_id']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => {
    'stream_id': id,
    'name': name,
    'stream_icon': logo,
    'container_extension': containerExtension,
    'rating': rating,
    'category_id': categoryId,
  };
}

class SeriesShow {
  const SeriesShow({
    required this.id,
    required this.name,
    required this.logo,
    required this.rating,
    required this.categoryId,
    required this.year,
  });

  final int id;
  final String name;
  final String logo;
  final String rating;
  final String categoryId;
  final String year;

  factory SeriesShow.fromJson(Map<String, dynamic> json) => SeriesShow(
    id: int.tryParse((json['series_id'] ?? json['id'])?.toString() ?? '') ?? 0,
    name: (json['name'] ?? json['title'])?.toString() ?? 'Serie',
    logo: (json['cover'] ?? json['stream_icon'])?.toString() ?? '',
    rating: json['rating']?.toString() ?? '',
    categoryId: json['category_id']?.toString() ?? '',
    year: (json['year'] ?? json['releaseDate'])?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => {
    'series_id': id,
    'name': name,
    'cover': logo,
    'rating': rating,
    'category_id': categoryId,
    'year': year,
  };
}

class SeriesEpisode {
  const SeriesEpisode({
    required this.id,
    required this.title,
    required this.season,
    required this.episode,
    required this.containerExtension,
    required this.duration,
  });

  final int id;
  final String title;
  final int season;
  final int episode;
  final String containerExtension;
  final String duration;

  factory SeriesEpisode.fromJson(Map<String, dynamic> json, int seasonHint) {
    final info = json['info'] is Map ? json['info'] as Map : const {};
    final episodeNum =
        int.tryParse(
          (json['episode_num'] ?? json['episode'] ?? json['episode_num'])
                  ?.toString() ??
              '',
        ) ??
        0;
    return SeriesEpisode(
      id:
          int.tryParse((json['id'] ?? json['stream_id'])?.toString() ?? '') ??
          0,
      title: (json['title'] ?? json['name'])?.toString() ?? 'Episodio',
      season:
          int.tryParse(
            (json['season'] ?? json['season_num'])?.toString() ?? '',
          ) ??
          seasonHint,
      episode: episodeNum,
      containerExtension:
          (json['container_extension'] ?? json['containerExtension'])
              ?.toString() ??
          'mp4',
      duration:
          (info['duration'] ?? json['duration'] ?? json['duration_secs'])
              ?.toString() ??
          '',
    );
  }
}
