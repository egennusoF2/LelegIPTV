import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart' as vp;
import 'package:video_player_avplay/video_player.dart' as avplay;
import 'package:video_player_avplay/video_player_platform_interface.dart'
    as avplay_platform;
import 'package:window_manager/window_manager.dart';

import 'domain/catchup.dart';
import 'domain/media_candidates.dart';
import 'domain/xtream_client.dart';

const String _buildId = String.fromEnvironment(
  'LELEG_BUILD_ID',
  defaultValue: 'local',
);

const MethodChannel _storageChannel = MethodChannel(
  'com.lelegiptv.native/storage',
);

const bool kAndroidTvBuild = bool.fromEnvironment('LELEG_ANDROID_TV');

/// Preserves [Video] state when [PlayerCard] moves between inline and fullscreen.
final GlobalKey _lelegMediaKitVideoSurfaceKey = GlobalKey(
  debugLabel: 'Leleg media_kit video surface',
);

/// True on Tizen, Android TV flavor, or Android TV hardware at runtime.
bool lelegTvShellActive = kAndroidTvBuild;

/// Set at startup from Android `smallestScreenWidthDp` (null until known).
bool? lelegHandheldTabletDevice;

Future<bool> _resolveAndroidTvShell() async {
  if (kAndroidTvBuild || isTizenRuntime) {
    debugPrint(
      '[leleg-tv] shell=compile-time (kAndroidTvBuild=$kAndroidTvBuild)',
    );
    return true;
  }
  if (!Platform.isAndroid) return false;
  for (var attempt = 0; attempt < 12; attempt++) {
    try {
      final tvFlavor = await _storageChannel.invokeMethod<bool>('isTvFlavor');
      if (tvFlavor == true) {
        debugPrint('[leleg-tv] shell=isTvFlavor attempt=$attempt');
        return true;
      }
      final isTv = await _storageChannel.invokeMethod<bool>('isTelevision');
      if (isTv == true) {
        debugPrint('[leleg-tv] shell=isTelevision attempt=$attempt');
        return true;
      }
      debugPrint(
        '[leleg-tv] shell=miss attempt=$attempt tvFlavor=$tvFlavor isTv=$isTv',
      );
    } catch (error) {
      debugPrint('[leleg-tv] shell=channel-error attempt=$attempt $error');
    }
    await Future<void>.delayed(Duration(milliseconds: 40 * (attempt + 1)));
  }
  debugPrint('[leleg-tv] shell=failed after retries');
  return false;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS || Platform.isWindows) {
    await windowManager.ensureInitialized();
  }
  if (!isTizenRuntime) {
    MediaKit.ensureInitialized();
  }
  runApp(const _LelegBootstrapApp());
}

class _LelegBootstrapApp extends StatefulWidget {
  const _LelegBootstrapApp();

  @override
  State<_LelegBootstrapApp> createState() => _LelegBootstrapAppState();
}

class _LelegBootstrapAppState extends State<_LelegBootstrapApp> {
  late final Future<bool> _androidTvFuture = _resolveAndroidTvShell();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _androidTvFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              backgroundColor: LelegColors.bg,
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        final initialAndroidTv = snapshot.data!;
        if (initialAndroidTv) {
          lelegTvShellActive = true;
        }
        return LelegIptvNativeApp(initialAndroidTv: initialAndroidTv);
      },
    );
  }
}

bool get isTizenRuntime {
  if (!Platform.isLinux) return false;
  try {
    return File('/etc/tizen-release').existsSync() ||
        File('/etc/tizen-platform.conf').existsSync() ||
        Directory('/opt/usr').existsSync();
  } catch (_) {
    return false;
  }
}

const _iptvUaHls =
    'Mozilla/5.0 (Linux; Android 9; SM-G960F) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36 '
    'IPTVSmartersPlayer/3.1.5';
const _iptvUaVod = 'VLC/3.0.20 LibVLC/3.0.20';

String _mediaUserAgentForUrl(String url) {
  final target = url.toLowerCase();
  if (RegExp(r'/(movie|series)/').hasMatch(target)) return _iptvUaVod;
  if (RegExp(r'\.m3u8(?:[?#]|$)').hasMatch(target) ||
      RegExp(r'/live/').hasMatch(target) ||
      RegExp(r'/timeshift/').hasMatch(target) ||
      RegExp(r'[?&]utc=').hasMatch(target)) {
    return _iptvUaHls;
  }
  if (target.endsWith('.ts')) return _iptvUaHls;
  return _iptvUaVod;
}

Map<String, String> _mediaHttpHeaders(String url, XtreamProfile? profile) {
  return {
    'User-Agent': _mediaUserAgentForUrl(url),
    if (profile != null) 'Referer': '${profile.baseUrl}/',
  };
}

bool _isLivePlaybackUrl(String url) {
  final target = url.toLowerCase();
  return RegExp(r'/live/').hasMatch(target) ||
      RegExp(r'/timeshift/').hasMatch(target) ||
      target.endsWith('.ts') ||
      RegExp(r'\.m3u8(?:[?#]|$)').hasMatch(target);
}

List<String> _vodPlayUrls(XtreamProfile profile, VodMovie movie) {
  return vodMediaCandidates(XtreamClient(profile).vodUrl(movie));
}

List<String> _episodePlayUrls(XtreamProfile profile, SeriesEpisode episode) {
  return vodMediaCandidates(XtreamClient(profile).episodeUrl(episode));
}

/// Phones: portrait + bottom nav. Tablets: landscape + drawer.
const double _handheldTabletMinSmallestWidthDp = 480;

bool _isMobileHandheldPlatform() => Platform.isAndroid || Platform.isIOS;

bool _isHandheldTabletByScreenSize(Size size) {
  if (Platform.isIOS) {
    return size.shortestSide >= 700 || size.longestSide >= 1024;
  }
  final shortest = size.shortestSide;
  final longest = size.longestSide;
  if (shortest >= 600) return true;
  return shortest >= 480 && longest >= 960;
}

bool _isHandheldTabletDevice(Size size) {
  if (Platform.isAndroid && lelegHandheldTabletDevice != null) {
    return lelegHandheldTabletDevice!;
  }
  return _isHandheldTabletByScreenSize(size);
}

bool _isHandheldPhoneSize(Size size) => !_isHandheldTabletDevice(size);

bool _isHandheldTabletSize(Size size) => _isHandheldTabletDevice(size);

bool _useHandheldPhoneShell(Size size) =>
    _isMobileHandheldPlatform() &&
    !lelegTvShellActive &&
    !isTizenRuntime &&
    _isHandheldPhoneSize(size);

bool _useHandheldTabletShell(Size size) =>
    _isMobileHandheldPlatform() &&
    !lelegTvShellActive &&
    !isTizenRuntime &&
    _isHandheldTabletSize(size);

bool _useCompactAdaptiveLayout(Size size) {
  if (lelegTvShellActive || isTizenRuntime) return false;
  if (_isMobileHandheldPlatform()) return true;
  return size.shortestSide < 900;
}

List<DeviceOrientation> _defaultOrientationsForSize(Size size) {
  if (_isMobileHandheldPlatform()) {
    if (_isHandheldTabletDevice(size)) {
      return const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    return const [DeviceOrientation.portraitUp];
  }
  return const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];
}

bool _useCompactAdaptiveConstraints(BoxConstraints constraints) {
  final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 1280.0;
  final height = constraints.maxHeight.isFinite ? constraints.maxHeight : 720.0;
  return _useCompactAdaptiveLayout(Size(width, height));
}

/// Horizontal category chips: Android TV only (remote-friendly). Everywhere
/// else uses the category dropdown in [_CatalogToolbar].
bool _useQuickCategoryChips(BuildContext context) => TvUi.isActive(context);

class LelegIptvNativeApp extends StatelessWidget {
  const LelegIptvNativeApp({super.key, this.initialAndroidTv = false});

  final bool initialAndroidTv;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Leleg IPTV',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: LelegColors.bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: LelegColors.accent,
          brightness: Brightness.dark,
          surface: LelegColors.surface,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: LelegColors.surface2,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: LelegColors.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: LelegColors.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: LelegColors.accent),
          ),
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: LelegColors.bg.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: LelegColors.line),
          ),
          textStyle: const TextStyle(color: LelegColors.fg),
          padding: const EdgeInsets.all(12),
          waitDuration: const Duration(milliseconds: 250),
        ),
        useMaterial3: true,
      ),
      home: LelegNativeShell(initialAndroidTv: initialAndroidTv),
    );
  }
}

class LelegColors {
  static const bg = Color(0xFF081016);
  static const sidebar = Color(0xFF081016);
  static const surface = Color(0xFF121A20);
  static const surface2 = Color(0xFF172028);
  static const surface3 = Color(0xFF1F2B34);
  static const line = Color(0xFF2D3A44);
  static const fg = Color(0xFFF4F8FB);
  static const muted = Color(0xFF9AA7B1);
  static const accent = Color(0xFF45C7F1);
}

/// Unified sizing and typography for 1080p Android TV.
class TvUi {
  static const contentPadding = 32.0;
  static const rowGap = 12.0;
  static const cardWidth = 158.0;
  static const thumbnailWidth = 158.0;
  static const navHeight = 46.0;
  static const liveCategoryWidth = 158.0;
  static const liveChannelWidth = 228.0;
  static const browseHeroFraction = 0.48;
  static const seriesHeroFraction = 0.28;

  static const eyebrow = 11.0;
  static const heroTitle = 22.0;
  static const sectionTitle = 14.5;
  static const body = 13.0;
  static const caption = 11.0;
  static const navLabel = 13.0;
  static const brandLabel = 14.0;
  static const brandIcon = 24.0;

  static double font(double size) => size;

  static double heroHeight(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return (height * 0.34).clamp(230.0, 310.0);
  }

  static bool isActive(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_TvUiScope>() != null;
}

bool _epgIsLiveNow(EpgProgramme programme) {
  final now = DateTime.now();
  final start = programme.start;
  final end = programme.end;
  return start != null &&
      end != null &&
      !start.isAfter(now) &&
      end.isAfter(now);
}

double? _liveProgrammeFraction(EpgProgramme programme) {
  final start = programme.start;
  final end = programme.end;
  if (!_epgIsLiveNow(programme) || start == null || end == null) return null;
  final totalMs = end.difference(start).inMilliseconds;
  if (totalMs <= 0) return null;
  final now = DateTime.now();
  return (now.difference(start).inMilliseconds / totalMs).clamp(0.0, 1.0);
}

Future<void> _scrollListItemToCenter(
  ScrollController? controller,
  GlobalKey key, {
  int attempts = 24,
  int? fallbackIndex,
  double fallbackTileHeight = 118,
  double fallbackMarkerHeight = 33,
  double fallbackSeparator = 10,
  bool fallbackHasMarker = false,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (attempt > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 44));
    }
    final context = key.currentContext;
    if (context == null) {
      await WidgetsBinding.instance.endOfFrame;
      continue;
    }
    final target = context.findRenderObject();
    if (target is! RenderBox || !target.hasSize) {
      await WidgetsBinding.instance.endOfFrame;
      continue;
    }
    if (controller != null && controller.hasClients) {
      final viewport = RenderAbstractViewport.maybeOf(target);
      if (viewport != null) {
        final reveal = viewport.getOffsetToReveal(target, 0.5);
        final position = controller.position;
        await controller.animateTo(
          reveal.offset.clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
        return;
      }
    }
    await Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    return;
  }
  if (controller == null ||
      !controller.hasClients ||
      fallbackIndex == null ||
      fallbackIndex < 0) {
    return;
  }
  var offset = 0.0;
  for (var i = 0; i < fallbackIndex; i++) {
    offset += fallbackTileHeight + fallbackSeparator;
  }
  if (fallbackHasMarker) offset += fallbackMarkerHeight;
  final viewport = controller.position.viewportDimension;
  final target = offset + (fallbackTileHeight * 0.5) - (viewport * 0.5);
  await controller.animateTo(
    target.clamp(0.0, controller.position.maxScrollExtent),
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOutCubic,
  );
}

bool _epgProgrammeLooksUsable(EpgProgramme programme) {
  final title = programme.title.trim();
  final start = programme.start;
  final end = programme.end;
  if (title.isEmpty || title.toLowerCase() == 'null') return false;
  if (start == null || end == null || !end.isAfter(start)) return false;
  final duration = end.difference(start);
  if (duration.inMinutes < 1 || duration.inHours > 18) return false;
  if (title.runes.any((code) => code < 32 && code != 9 && code != 10)) {
    return false;
  }
  return true;
}

List<EpgProgramme> _cleanEpgProgrammes(Iterable<EpgProgramme> programmes) {
  return programmes.where(_epgProgrammeLooksUsable).toList();
}

int _epgLiveOrNextIndex(List<EpgProgramme> programmes) {
  if (programmes.isEmpty) return 0;
  final liveIndex = programmes.indexWhere(_epgIsLiveNow);
  if (liveIndex >= 0) return liveIndex;
  final now = DateTime.now();
  final nextIndex = programmes.indexWhere(
    (programme) => programme.start?.isAfter(now) ?? false,
  );
  return nextIndex >= 0 ? nextIndex : programmes.length - 1;
}

List<EpgProgramme> _contextualEpgWindowForChannel(
  LiveChannel channel,
  Iterable<EpgProgramme> source, {
  int before = 3,
  int after = 3,
}) {
  final items = _cleanEpgProgrammes(source);
  items.sort((a, b) {
    final aStart = a.start;
    final bStart = b.start;
    if (aStart == null && bStart == null) return 0;
    if (aStart == null) return 1;
    if (bStart == null) return -1;
    return aStart.compareTo(bStart);
  });
  if (items.isEmpty) return const [];
  final pivot = _epgLiveOrNextIndex(items);
  final start = (pivot - before).clamp(0, items.length).toInt();
  final end = (pivot + after + 1).clamp(start, items.length).toInt();
  return items.sublist(start, end);
}

String? _liveNowProgrammeTitle(List<EpgProgramme> programmes) {
  if (programmes.isEmpty) return null;
  final title = programmes[_epgLiveOrNextIndex(programmes)].title.trim();
  return title.isEmpty ? null : title;
}

const _guideDefaultLookbackDays = 7;
const _guideChannelColumnWidth = 248.0;

DateTime _guideDayStart(int dayOffset) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day).add(Duration(days: dayOffset));
}

DateTime _guideDayEnd(DateTime dayStart) =>
    dayStart.add(const Duration(days: 1));

List<EpgProgramme> _programmesForGuideDay(
  List<EpgProgramme> programmes,
  DateTime dayStart,
  DateTime dayEnd,
) {
  final filtered = _cleanEpgProgrammes(programmes).where((programme) {
    final start = programme.start;
    final end = programme.end;
    if (start == null || end == null) return false;
    if (start.isBefore(dayStart) && end.isAfter(dayStart)) return true;
    return !start.isBefore(dayStart) && start.isBefore(dayEnd);
  }).toList();
  filtered.sort((a, b) {
    final aStart = a.start;
    final bStart = b.start;
    if (aStart == null && bStart == null) return 0;
    if (aStart == null) return 1;
    if (bStart == null) return -1;
    return aStart.compareTo(bStart);
  });
  return _dedupeGuideProgrammes(filtered);
}

List<EpgProgramme> _dedupeGuideProgrammes(List<EpgProgramme> programmes) {
  final result = <EpgProgramme>[];
  for (final programme in programmes) {
    if (!_epgProgrammeLooksUsable(programme)) continue;
    final start = programme.start;
    if (start == null) continue;
    final duplicateIndex = result.indexWhere((existing) {
      final existingStart = existing.start;
      if (existingStart == null) return false;
      if (existing.title.trim().toLowerCase() !=
          programme.title.trim().toLowerCase()) {
        return false;
      }
      return (existingStart.difference(start).inMinutes).abs() <= 3;
    });
    if (duplicateIndex >= 0) {
      final existing = result[duplicateIndex];
      final keepNew =
          (programme.end != null && existing.end == null) ||
          (programme.description.length > existing.description.length);
      if (keepNew) {
        result[duplicateIndex] = programme;
      }
      continue;
    }
    result.add(programme);
  }
  return result;
}

int _guideLookbackDays(LiveChannel? channel) {
  if (channel == null) return _guideDefaultLookbackDays;
  if (channel.catchupDays > _guideDefaultLookbackDays) {
    return channel.catchupDays.clamp(1, 14);
  }
  return _guideDefaultLookbackDays;
}

String _formatGuideDayTab(int dayOffset) {
  if (dayOffset == -1) return 'IERI';
  if (dayOffset == 0) return 'OGGI';
  if (dayOffset == 1) return 'DOMANI';
  final date = DateTime.now().add(Duration(days: dayOffset));
  const days = ['LUN', 'MAR', 'MER', 'GIO', 'VEN', 'SAB', 'DOM'];
  final dow = days[date.weekday - 1];
  return '$dow ${date.day}';
}

String _formatGuideDayLabel(DateTime dayStart) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (dayStart == today) return 'Oggi';
  if (dayStart == today.subtract(const Duration(days: 1))) return 'Ieri';
  if (dayStart == today.add(const Duration(days: 1))) return 'Domani';
  return '${dayStart.day.toString().padLeft(2, '0')}/'
      '${dayStart.month.toString().padLeft(2, '0')}/'
      '${dayStart.year}';
}

String _formatGuideClock(DateTime? value) {
  if (value == null) return '--:--';
  return '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

int _guideLiveProgrammeIndex(List<EpgProgramme> programmes, int dayOffset) {
  if (dayOffset != 0) return -1;
  return programmes.indexWhere(_epgIsLiveNow);
}

class _TvUiScope extends InheritedWidget {
  const _TvUiScope({required super.child});

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;
}

enum AppSection {
  home,
  live,
  movies,
  series,
  favorites,
  watchLater,
  recentlyAdded,
  epg,
  downloads,
  settings,
}

class PlaybackProgress {
  const PlaybackProgress({
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
  });

  final int positionMs;
  final int durationMs;
  final int updatedAt;

  double get fraction =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  bool get isCompleted => durationMs > 0 && fraction >= 0.92;

  bool get canResume => positionMs >= 15000 && !isCompleted;

  Map<String, dynamic> toJson() => {
    'p': positionMs,
    'd': durationMs,
    't': updatedAt,
  };

  factory PlaybackProgress.fromJson(Map<String, dynamic> json) =>
      PlaybackProgress(
        positionMs: int.tryParse(json['p']?.toString() ?? '') ?? 0,
        durationMs: int.tryParse(json['d']?.toString() ?? '') ?? 0,
        updatedAt: int.tryParse(json['t']?.toString() ?? '') ?? 0,
      );
}

class _LastVodPlay {
  const _LastVodPlay({
    required this.type,
    required this.updatedAt,
    this.movieId,
    this.seriesId,
    this.episodeId,
  });

  final String type;
  final int? movieId;
  final int? seriesId;
  final int? episodeId;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
    'type': type,
    'movieId': movieId,
    'seriesId': seriesId,
    'episodeId': episodeId,
    't': updatedAt,
  };

  factory _LastVodPlay.fromJson(Map<String, dynamic> json) => _LastVodPlay(
    type: json['type']?.toString() ?? '',
    movieId: int.tryParse(json['movieId']?.toString() ?? ''),
    seriesId: int.tryParse(json['seriesId']?.toString() ?? ''),
    episodeId: int.tryParse(json['episodeId']?.toString() ?? ''),
    updatedAt: int.tryParse(json['t']?.toString() ?? '') ?? 0,
  );
}

class TvHomeHeroTarget {
  const TvHomeHeroTarget({
    required this.eyebrow,
    required this.title,
    required this.imageUrl,
    required this.actionLabel,
    required this.onAction,
    this.progress,
  });

  final String eyebrow;
  final String title;
  final String imageUrl;
  final String actionLabel;
  final VoidCallback onAction;
  final PlaybackProgress? progress;
}

class LelegNativeShell extends StatefulWidget {
  const LelegNativeShell({super.key, this.initialAndroidTv = false});

  final bool initialAndroidTv;

  @override
  State<LelegNativeShell> createState() => _LelegNativeShellState();
}

class _LelegNativeShellState extends State<LelegNativeShell>
    with WidgetsBindingObserver {
  static const _profileKey = 'leleg.native.profile';
  static const _lastMovieIdKey = 'leleg.tv.last_movie_id';
  static const _lastSeriesIdKey = 'leleg.tv.last_series_id';
  static const _recentLiveChannelsPrefix = 'leleg.tv.recent_live.';
  static const _recentMoviesHistoryPrefix = 'leleg.tv.recent_movies.';
  static const _recentSeriesHistoryPrefix = 'leleg.tv.recent_series.';
  static const _movieProgressPrefix = 'leleg.tv.movie_progress.';
  static const _episodeProgressPrefix = 'leleg.tv.episode_progress.';
  static const _lastVodPlayPrefix = 'leleg.tv.last_vod.';
  static const _recentHistoryMax = 16;
  static const _profilesKey = 'leleg.native.profiles';
  static const _activeProfileIdKey = 'leleg.native.active_profile_id';
  static const _favoriteMoviesPrefix = 'leleg.native.favorite_movies.';
  static const _favoriteSeriesPrefix = 'leleg.native.favorite_series.';
  static const _watchLaterMoviesPrefix = 'leleg.native.watch_later_movies.';
  static const _catalogCacheTtl = Duration(days: 1);
  static const _catalogCacheVersion = 5;
  static const _defaultRemoteSections = [
    AppSection.home,
    AppSection.live,
    AppSection.movies,
    AppSection.series,
    AppSection.favorites,
    AppSection.watchLater,
    AppSection.recentlyAdded,
    AppSection.epg,
    AppSection.downloads,
    AppSection.settings,
  ];

  Player? _player;
  VideoController? _videoController;
  vp.VideoPlayerController? _appleVideoController;
  late final TextEditingController _titleController;
  late final TextEditingController _serverController;
  late final TextEditingController _userController;
  late final TextEditingController _passController;
  late final TextEditingController _searchController;
  late final FocusNode _shellFocusNode;
  late final FocusNode _searchFocusNode;
  late final FocusScopeNode _contentFocusScopeNode;
  late final FocusNode _settingsTitleFocusNode;
  late final FocusNode _settingsServerFocusNode;
  late final FocusNode _settingsUserFocusNode;
  late final FocusNode _settingsPassFocusNode;
  late final List<StreamSubscription> _subscriptions;
  avplay.VideoPlayerController? _tizenVideoController;

  AppSection _section = AppSection.home;
  AppSection _remoteSection = AppSection.home;
  bool _remoteMenuMode = false;
  int _tvContentIndex = 0;
  XtreamProfile? _profile;
  List<XtreamProfile> _profiles = const [];
  XtreamAccountInfo? _accountInfo;
  List<XtreamCategory> _liveCategories = const [];
  List<XtreamCategory> _movieCategories = const [];
  List<XtreamCategory> _seriesCategories = const [];
  List<LiveChannel> _liveChannels = const [];
  LiveChannel? _selectedLiveChannel;
  List<EpgProgramme> _selectedLiveEpg = const [];
  final Map<int, List<EpgProgramme>> _epgByChannel = {};
  int? _epgLoadingChannelId;
  List<VodMovie> _movies = const [];
  VodMovie? _selectedMovie;
  String _selectedMovieDescription = '';
  String _selectedMovieGenre = '';
  String _browseHeroDescription = '';
  bool _browseHeroLoading = false;
  bool _browseHeroActionSelected = false;
  int? _browseHeroItemId;
  final Map<int, String> _movieDescriptionCache = {};
  final Map<int, String> _movieGenreCache = {};
  final Map<int, String> _seriesDescriptionCache = {};
  final Map<int, String> _seriesGenreCache = {};
  List<SeriesShow> _series = const [];
  SeriesShow? _selectedSeries;
  String _selectedSeriesDescription = '';
  String _selectedSeriesGenre = '';
  List<SeriesEpisode> _seriesEpisodes = const [];
  final Set<int> _favoriteMovieIds = {};
  final Set<int> _favoriteSeriesIds = {};
  final Set<int> _watchLaterMovieIds = {};
  List<int> _recentLiveChannelIds = const [];
  List<int> _recentMovieHistoryIds = const [];
  List<int> _recentSeriesHistoryIds = const [];
  Map<int, PlaybackProgress> _movieProgress = const {};
  Map<int, PlaybackProgress> _episodeProgress = const {};
  _LastVodPlay? _lastVodPlay;
  int? _activeMovieId;
  int? _activeEpisodeId;
  Timer? _playbackProgressTimer;
  final Map<int, DownloadTask> _downloads = {};
  String _liveCategoryId = '';
  String _movieCategoryId = '';
  String _seriesCategoryId = '';
  String _movieSort = 'default';
  String _seriesSort = 'default';
  String _status = 'Pronto';
  String _query = '';
  String _playerTitle = 'Scegli qualcosa da guardare.';
  double _rate = 1.0;
  bool _loading = false;
  bool _seriesDetailLoading = false;
  bool _epgLoading = false;
  bool _liveListEpgPrefetching = false;
  bool _playerFocusMode = false;
  bool _isAndroidTv = false;
  bool _livePlayerActive = false;
  bool _fullscreenOverlayVisible = true;
  bool get _usesDesktopFullscreenOverlay =>
      !_isAndroidTv && (Platform.isMacOS || Platform.isWindows);
  bool _remoteSearchSelected = false; // campo di testo aperto
  bool _remoteSearchIconFocused = false; // solo l'icona cerca è evidenziata
  bool _tvSearchEditing = false;
  bool _remotePassthroughActive = false;
  int _epgProgrammeIndex = 0;
  int _epgGuideDayOffset = 0;
  int _epgLoadGeneration = 0;
  int _livePlaybackGeneration = 0;
  int _vodToolbarIndex = -1;
  Timer? _fullscreenOverlayTimer;

  static const _vodToolbarLabels = [
    'Play/Pausa',
    '-10 secondi',
    '+10 secondi',
    'Audio',
    'Sottotitoli',
    'Esci',
  ];

  List<AppSection> get _remoteSections => _isAndroidTv
      ? const [
          AppSection.home,
          AppSection.live,
          AppSection.movies,
          AppSection.series,
          AppSection.favorites,
        ]
      : _defaultRemoteSections;

  List<AppSection> get _homeTargets => _isAndroidTv
      ? const <AppSection>[]
      : [
          AppSection.live,
          AppSection.movies,
          AppSection.series,
          AppSection.favorites,
          AppSection.watchLater,
          AppSection.epg,
          AppSection.downloads,
          AppSection.settings,
        ];

  String _sectionLabel(AppSection section) {
    return switch (section) {
      AppSection.home => 'Home',
      AppSection.live => 'Live TV',
      AppSection.movies => 'Film',
      AppSection.series => 'Serie',
      AppSection.favorites => 'Preferiti',
      AppSection.watchLater => 'Da vedere',
      AppSection.recentlyAdded => 'Aggiunti di recente',
      AppSection.epg => 'Guida TV',
      AppSection.downloads => 'Download',
      AppSection.settings => 'Impostazioni',
    };
  }

  bool get _useAppleVideoBackend => false;

  bool get _preferTsLivePlayback {
    if (isTizenRuntime) return false;
    if (Platform.isIOS) return false;
    return Platform.isAndroid ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux;
  }

  void _traceTv(String message) {
    debugPrint('[leleg-tv] $message');
  }

  ui.FlutterView get _activeFlutterView {
    final fromContext = View.maybeOf(context);
    if (fromContext != null) return fromContext;
    return WidgetsBinding.instance.platformDispatcher.views.first;
  }

  Size get _logicalViewSize {
    final view = _activeFlutterView;
    return view.physicalSize / view.devicePixelRatio;
  }

  List<DeviceOrientation> get _defaultMobileOrientations =>
      _defaultOrientationsForSize(_logicalViewSize);

  Future<void> _applyMobileOrientationPolicy({bool? fullscreen}) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final useFullscreen = fullscreen ?? _playerFocusMode;
    if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(
        useFullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
    await SystemChrome.setPreferredOrientations(
      useFullscreen
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : _defaultMobileOrientations,
    );
  }

  @override
  void initState() {
    super.initState();
    final mediaPlayer = isTizenRuntime || _useAppleVideoBackend
        ? null
        : Player(
            configuration: PlayerConfiguration(
              title: 'Leleg IPTV',
              bufferSize: (Platform.isMacOS || Platform.isWindows)
                  ? 64 * 1024 * 1024
                  : 32 * 1024 * 1024,
            ),
          );
    _player = mediaPlayer;
    _videoController = mediaPlayer == null
        ? null
        : VideoController(
            mediaPlayer,
            configuration: VideoControllerConfiguration(
              enableHardwareAcceleration: !Platform.isWindows,
              androidAttachSurfaceAfterVideoParameters: true,
            ),
          );
    _titleController = TextEditingController();
    _serverController = TextEditingController();
    _userController = TextEditingController();
    _passController = TextEditingController();
    _titleController.addListener(_applyPlaylistPresetFromTitle);
    _searchController = TextEditingController();
    _shellFocusNode = FocusNode(debugLabel: 'Leleg shell keyboard focus');
    _searchFocusNode = FocusNode(debugLabel: 'Leleg sidebar search focus');
    _contentFocusScopeNode = FocusScopeNode(
      debugLabel: 'Leleg content keyboard focus',
    );
    _settingsTitleFocusNode = FocusNode(debugLabel: 'Settings title field');
    _settingsServerFocusNode = FocusNode(debugLabel: 'Settings server field');
    _settingsUserFocusNode = FocusNode(debugLabel: 'Settings user field');
    _settingsPassFocusNode = FocusNode(debugLabel: 'Settings pass field');
    _subscriptions = mediaPlayer == null
        ? const []
        : [
            mediaPlayer.stream.error.listen((error) {
              if (mounted) setState(() => _status = 'Player error: $error');
            }),
            mediaPlayer.stream.playing.listen((playing) {
              if (mounted) {
                setState(
                  () => _status = playing ? 'In riproduzione' : 'In pausa',
                );
              }
            }),
          ];
    _storageChannel.setMethodCallHandler(_handleNativeStorageCall);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (Platform.isAndroid || Platform.isIOS) {
        unawaited(_applyMobileOrientationPolicy());
      }
    });
    _isAndroidTv = widget.initialAndroidTv || kAndroidTvBuild;
    if (_isAndroidTv) {
      _remoteMenuMode = true;
      lelegTvShellActive = true;
      unawaited(_applyAndroidTvChrome());
    } else if (Platform.isAndroid) {
      unawaited(_bootstrapAndroidShell());
    }
    FocusManager.instance.addListener(_onGlobalFocusChanged);
    WidgetsBinding.instance.addObserver(this);
    _restoreState();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (Platform.isAndroid || Platform.isIOS) {
      unawaited(_applyMobileOrientationPolicy());
    }
  }

  Future<void> _bootstrapAndroidShell() async {
    try {
      final tvFlavor = await _storageChannel.invokeMethod<bool>('isTvFlavor');
      if (tvFlavor == true) {
        await _applyAndroidTvChrome();
        return;
      }
      final isTablet = await _storageChannel.invokeMethod<bool>('isTablet');
      if (isTablet != null) {
        lelegHandheldTabletDevice = isTablet;
        if (mounted) {
          setState(() {});
          unawaited(_applyMobileOrientationPolicy());
        }
      }
      await _restoreAndroidFormFactor();
    } catch (_) {
      await _restoreAndroidFormFactor();
    }
  }

  void _onGlobalFocusChanged() {
    if (!_isAndroidTv || !mounted) return;
    unawaited(_syncRemotePassthrough());
  }

  Future<void> _applyAndroidTvChrome() async {
    if (!mounted) return;
    setState(() => _isAndroidTv = true);
    lelegTvShellActive = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await _syncRemotePassthrough();
  }

  Future<void> _restoreAndroidFormFactor() async {
    try {
      final isTv = await _storageChannel.invokeMethod<bool>('isTelevision');
      if (!mounted || isTv != true) return;
      await _applyAndroidTvChrome();
    } catch (_) {
      // Keep the normal adaptive fallback if the native channel is unavailable.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FocusManager.instance.removeListener(_onGlobalFocusChanged);
    _storageChannel.setMethodCallHandler(null);
    _fullscreenOverlayTimer?.cancel();
    _playbackProgressTimer?.cancel();
    unawaited(_flushPlaybackProgress());
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _tizenVideoController?.dispose();
    _appleVideoController?.dispose();
    _serverController.dispose();
    _titleController.removeListener(_applyPlaylistPresetFromTitle);
    _titleController.dispose();
    _userController.dispose();
    _passController.dispose();
    _searchController.dispose();
    _shellFocusNode.dispose();
    _searchFocusNode.dispose();
    _contentFocusScopeNode.dispose();
    _settingsTitleFocusNode.dispose();
    _settingsServerFocusNode.dispose();
    _settingsUserFocusNode.dispose();
    _settingsPassFocusNode.dispose();
    _player?.dispose();
    super.dispose();
  }

  XtreamProfile? _playlistPresetForCode(String rawCode) {
    final code = rawCode.trim().toUpperCase();
    const presets = <String, XtreamProfile>{
      'LELEG': XtreamProfile(
        title: 'LELEG',
        serverUrl: 'http://muti14.fonsecatemp.com',
        username: 'notv_w7cehc',
        password: 'ffhuax4a',
      ),
      'JOLLY': XtreamProfile(
        title: 'JOLLY',
        serverUrl: 'http://muti14.fonsecatemp.com',
        username: 'notv_71d762',
        password: 'qgjjhnty',
      ),
      'AMICO': XtreamProfile(
        title: 'AMICO',
        serverUrl: 'http://muti14.fonsecatemp.com',
        username: 'notv_93me22',
        password: 'x7g35zhh',
      ),
      'ALESSANDRO': XtreamProfile(
        title: 'ALESSANDRO',
        serverUrl: 'http://watchtivo-4k.com',
        username: 'S8eLtOiTtE',
        password: 'ut6YxwMG6X',
      ),
      'GIORDANO': XtreamProfile(
        title: 'GIORDANO',
        serverUrl: 'http://watchtivo-4k.com',
        username: 'bSFZGHX1Gr',
        password: 'zHwiKBmB1O',
      ),
    };
    return presets[code];
  }

  void _applyPlaylistPresetFromTitle() {
    final preset = _playlistPresetForCode(_titleController.text);
    if (preset == null) return;
    var changed = false;
    if (_serverController.text != preset.serverUrl) {
      _serverController.text = preset.serverUrl;
      changed = true;
    }
    if (_userController.text != preset.username) {
      _userController.text = preset.username;
      changed = true;
    }
    if (_passController.text != preset.password) {
      _passController.text = preset.password;
      changed = true;
    }
    if (changed && mounted) {
      setState(
        () => _status = 'Lista ${preset.title} compilata automaticamente.',
      );
    }
  }

  Future<void> _handleNativeStorageCall(MethodCall call) async {
    if (call.method == 'remoteKey') {
      final args = call.arguments is Map
          ? Map<Object?, Object?>.from(call.arguments as Map)
          : const <Object?, Object?>{};
      final key = args['key']?.toString() ?? '';
      _handleNativeRemoteKey(key);
      return;
    }
    if (call.method != 'downloadProgress') return;
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    final movieId = (args['movieId'] as num?)?.toInt();
    final progress = (args['progress'] as num?)?.toDouble();
    if (movieId == null || progress == null || !mounted) return;
    setState(() {
      final current = _downloads[movieId];
      if (current == null || current.status != DownloadStatus.downloading) {
        return;
      }
      _downloads[movieId] = current.copyWith(progress: progress.clamp(0, 1));
      _status = progress <= 0
          ? 'Download in preparazione: ${current.movie.name}'
          : 'Download ${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%: ${current.movie.name}';
    });
  }

  void _handleNativeRemoteKey(String key) {
    if (!mounted) return;
    if (_remotePassthroughActive || _tvSearchEditing || _isEditingText) return;
    final logicalKey = switch (key) {
      'up' => LogicalKeyboardKey.arrowUp,
      'down' => LogicalKeyboardKey.arrowDown,
      'left' => LogicalKeyboardKey.arrowLeft,
      'right' => LogicalKeyboardKey.arrowRight,
      'select' => LogicalKeyboardKey.select,
      'back' => LogicalKeyboardKey.goBack,
      _ => null,
    };
    if (logicalKey == null) return;
    _traceTv(
      'native remote key=$key section=$_section index=$_tvContentIndex '
      'menuMode=$_remoteMenuMode count=$_tvContentItemCount',
    );
    if (_playerFocusMode) {
      _handleFullscreenPlayerKey(logicalKey);
      return;
    }
    if (_remoteMenuMode) {
      _handleRemoteMenuLogicalKey(logicalKey);
    } else {
      _handleContentKey(logicalKey);
    }
  }

  KeyEventResult _handleRemoteMenuLogicalKey(LogicalKeyboardKey key) {
    // Campo di testo aperto: intercetta tutto tranne escape/back che chiude
    if (_remoteSearchSelected) {
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.browserBack) {
        FocusManager.instance.primaryFocus?.unfocus();
        _shellFocusNode.requestFocus();
        unawaited(_exitTvSearchEditing());
        setState(() {
          _remoteSearchSelected = false;
          _remoteSearchIconFocused = false;
          _status = 'Menu: ${_sectionLabel(_remoteSection)}';
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    // Icona cerca evidenziata (ma campo non ancora aperto)
    if (_remoteSearchIconFocused) {
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        unawaited(_enterTvSearchEditing());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        // → dai cerca → impostazioni
        unawaited(_changeSection(AppSection.settings));
        setState(() {
          _remoteSearchIconFocused = false;
          _status = 'Impostazioni';
        });
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        // ← da cerca → torna all'ultimo item menu
        setState(() {
          _remoteSearchIconFocused = false;
          _remoteSection = _remoteSections.last;
          _status = 'Menu: ${_sectionLabel(_remoteSection)}';
        });
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.browserBack) {
        setState(() {
          _remoteSearchIconFocused = false;
          _status = 'Menu: ${_sectionLabel(_remoteSection)}';
        });
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    if (_isAndroidTv) {
      if (key == LogicalKeyboardKey.arrowUp) {
        if (_remoteSection == _remoteSections.first) {
          setState(() {
            _remoteSearchSelected = true;
            _status = 'Cerca selezionata: premi OK per digitare.';
          });
          return KeyEventResult.handled;
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        unawaited(_changeSection(_remoteSection));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        _moveRemoteSelection(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        final atLast = _remoteSection == _remoteSections.last;
        if (atLast) {
          // Ultimo item menu → evidenzia l'icona cerca (NON apre il campo)
          setState(() {
            _remoteSearchIconFocused = true;
            _status = 'Cerca — premi OK per digitare';
          });
        } else {
          _moveRemoteSelection(1);
        }
        return KeyEventResult.handled;
      }
    } else {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveRemoteSelection(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveRemoteSelection(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        _moveRemoteSelection(-1);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowRight && !_isAndroidTv) {
      unawaited(_changeSection(_remoteSection));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.browserBack) {
      if (_playerFocusMode) {
        _togglePlayerFocusMode();
      } else if (_section != AppSection.home) {
        unawaited(_changeSection(AppSection.home));
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      unawaited(_changeSection(_remoteSection));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _restoreState() async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = _readProfiles(prefs);
    final activeProfileId = prefs.getString(_activeProfileIdKey) ?? '';
    final rawProfile = prefs.getString(_profileKey);
    try {
      var savedProfiles = profiles;
      if (savedProfiles.isEmpty &&
          rawProfile != null &&
          rawProfile.isNotEmpty) {
        final migrated = _profileWithStableId(
          XtreamProfile.fromJson(jsonDecode(rawProfile)),
        );
        savedProfiles = [migrated];
        await _persistProfiles(prefs, savedProfiles, migrated.id);
      }
      if (savedProfiles.isEmpty) {
        if (mounted) {
          setState(() {
            _section = AppSection.settings;
            _remoteSection = AppSection.settings;
            _remoteMenuMode = false;
            _tvContentIndex = 0;
            _status = 'Aggiungi la tua lista IPTV per iniziare.';
          });
        }
        return;
      }
      final profile = savedProfiles.firstWhere(
        (item) => item.id == activeProfileId,
        orElse: () => savedProfiles.first,
      );
      _resetSettingsForm();
      setState(() {
        _profiles = savedProfiles;
        _profile = profile;
        _section = AppSection.home;
        _remoteSection = AppSection.home;
        _remoteMenuMode = false;
        _tvContentIndex = 0;
        _status = 'Home';
      });
      await _loadUserLists(profile);
      await _loadCatalog(profile: profile);
      unawaited(_syncRemotePassthrough());
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Profilo salvato non valido: $error');
      }
    }
  }

  XtreamProfile _readProfileFromForm() => XtreamProfile(
    title: _titleController.text.trim(),
    serverUrl:
        _playlistPresetForCode(_titleController.text)?.serverUrl ??
        _serverController.text.trim(),
    username:
        _playlistPresetForCode(_titleController.text)?.username ??
        _userController.text.trim(),
    password:
        _playlistPresetForCode(_titleController.text)?.password ??
        _passController.text,
  );

  List<XtreamProfile> _readProfiles(SharedPreferences prefs) {
    final raw = prefs.getString(_profilesKey);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (item) => XtreamProfile.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .where((item) => item.isComplete)
          .map(_profileWithStableId)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  XtreamProfile _profileWithStableId(XtreamProfile profile) {
    if (profile.id.trim().isNotEmpty) return profile;
    final base = '${profile.baseUrl}|${profile.username}';
    return profile.copyWith(id: base64Url.encode(utf8.encode(base)));
  }

  Future<void> _persistProfiles(
    SharedPreferences prefs,
    List<XtreamProfile> profiles,
    String activeId,
  ) async {
    await prefs.setString(
      _profilesKey,
      jsonEncode(profiles.map((item) => item.toJson()).toList()),
    );
    await prefs.setString(_activeProfileIdKey, activeId);
  }

  void _resetSettingsForm() {
    _titleController.clear();
    _serverController.clear();
    _userController.clear();
    _passController.clear();
  }

  Future<void> _saveAndLoadProfile({bool forceRefresh = false}) async {
    var profile = _profileWithStableId(_readProfileFromForm());
    if (!profile.isComplete) {
      setState(() => _status = 'Server, username e password sono obbligatori.');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final profiles = [..._profiles];
    final existingIndex = profiles.indexWhere((item) => item.id == profile.id);
    if (existingIndex >= 0) {
      if (profile.title.trim().isEmpty) {
        profile = profile.copyWith(title: profiles[existingIndex].title);
      }
      profiles[existingIndex] = profile;
    } else {
      profiles.add(profile);
    }
    await _persistProfiles(prefs, profiles, profile.id);
    await prefs.setString(_profileKey, jsonEncode(profile.toJson()));
    setState(() {
      _profiles = profiles;
      _profile = profile;
      _titleController.clear();
      _serverController.clear();
      _userController.clear();
      _passController.clear();
    });
    await _loadUserLists(profile);
    await _loadCatalog(profile: profile, forceRefresh: forceRefresh);
  }

  Future<void> _selectProfile(XtreamProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeProfileIdKey, profile.id);
    await prefs.setString(_profileKey, jsonEncode(profile.toJson()));
    _resetSettingsForm();
    setState(() {
      _profile = profile;
      _resetProfileScopedState();
      _status = 'Cambio lista: ${profile.displayName}';
    });
    await _loadUserLists(profile);
    await _loadCatalog(profile: profile);
  }

  Future<void> _deleteProfile(XtreamProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = _profiles.where((item) => item.id != profile.id).toList();
    final next = profiles.isEmpty ? null : profiles.first;
    await _persistProfiles(prefs, profiles, next?.id ?? '');
    if (next == null) {
      await prefs.remove(_profileKey);
      _titleController.clear();
      _serverController.clear();
      _userController.clear();
      _passController.clear();
      setState(() {
        _profiles = profiles;
        _profile = null;
        _titleController.clear();
        _resetProfileScopedState();
      });
      return;
    }
    await prefs.setString(_profileKey, jsonEncode(next.toJson()));
    setState(() => _profiles = profiles);
    await _selectProfile(next);
  }

  Future<void> _changeSection(AppSection section) async {
    if (section == AppSection.settings) {
      _resetSettingsForm();
    }
    if (section == _section) {
      _enterContentMode();
      if (section == AppSection.epg) {
        unawaited(_loadEpgPage(force: true));
      }
      return;
    }
    if (!_isAndroidTv && _remoteMenuMode) {
      setState(() => _remoteMenuMode = false);
    }
    await _endPlaybackTracking();
    final mediaPlayer = _player;
    if (mediaPlayer != null && mediaPlayer.state.playlist.medias.isNotEmpty) {
      await mediaPlayer.stop();
    }
    final appleController = _appleVideoController;
    if (appleController != null) {
      try {
        await appleController.pause();
      } catch (_) {}
    }
    if (_playerFocusMode) {
      _setPlayerFocusMode(false);
    }
    setState(() {
      _section = section;
      _remoteSection = section;
      _remoteMenuMode = false;
      _tvContentIndex = 0;
      _selectedMovie = null;
      _selectedMovieDescription = '';
      _selectedMovieGenre = '';
      _browseHeroDescription = '';
      _browseHeroLoading = false;
      _browseHeroItemId = null;
      _browseHeroActionSelected = false;
      if (section != AppSection.series) {
        _selectedSeries = null;
        _selectedSeriesDescription = '';
        _selectedSeriesGenre = '';
        _seriesEpisodes = const [];
      }
      _playerTitle = 'Scegli qualcosa da guardare.';
    });
    if (section == AppSection.epg) {
      unawaited(_loadEpgPage());
    }
    if (section == AppSection.live) {
      final size = MediaQuery.sizeOf(context);
      if (_useHandheldPhoneShell(size)) {
        unawaited(_prefetchLiveListEpgs());
      } else {
        _previewLiveChannelAt(0);
      }
    } else if (section == AppSection.epg) {
      _previewEpgChannelAt(0);
    } else if (_isAndroidTv && section == AppSection.movies) {
      unawaited(_enterMovieBrowse());
    } else if (_isAndroidTv && section == AppSection.series) {
      unawaited(_enterSeriesBrowse());
    } else if (_isAndroidTv && section == AppSection.favorites) {
      unawaited(_enterMovieBrowse());
    }
    _focusFirstContentControl();
    unawaited(_syncRemotePassthrough());
  }

  Future<void> _saveLastMovieId(int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastMovieIdKey, id);
  }

  Future<void> _saveLastSeriesId(int id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastSeriesIdKey, id);
  }

  String _recentLiveChannelsKey(XtreamProfile profile) =>
      '$_recentLiveChannelsPrefix${profile.id}';

  String _recentMoviesHistoryKey(XtreamProfile profile) =>
      '$_recentMoviesHistoryPrefix${profile.id}';

  String _recentSeriesHistoryKey(XtreamProfile profile) =>
      '$_recentSeriesHistoryPrefix${profile.id}';

  List<int> _readRecentIds(SharedPreferences prefs, String key) {
    return prefs
            .getStringList(key)
            ?.map(int.tryParse)
            .whereType<int>()
            .take(_recentHistoryMax)
            .toList() ??
        const [];
  }

  Future<void> _persistRecentIds(String key, List<int> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, ids.map((id) => id.toString()).toList());
  }

  List<int> _dedupeRecentId(List<int> current, int id) {
    return [
      id,
      ...current.where((item) => item != id),
    ].take(_recentHistoryMax).toList();
  }

  Future<void> _recordRecentLiveChannel(int id) async {
    final profile = _profile;
    if (profile == null) return;
    final next = _dedupeRecentId(_recentLiveChannelIds, id);
    if (!mounted) return;
    setState(() => _recentLiveChannelIds = next);
    await _persistRecentIds(_recentLiveChannelsKey(profile), next);
  }

  Future<void> _recordRecentMovie(int id) async {
    final profile = _profile;
    if (profile == null) return;
    final next = _dedupeRecentId(_recentMovieHistoryIds, id);
    if (!mounted) return;
    setState(() => _recentMovieHistoryIds = next);
    await _persistRecentIds(_recentMoviesHistoryKey(profile), next);
  }

  Future<void> _recordRecentSeries(int id) async {
    final profile = _profile;
    if (profile == null) return;
    final next = _dedupeRecentId(_recentSeriesHistoryIds, id);
    if (!mounted) return;
    setState(() => _recentSeriesHistoryIds = next);
    await _persistRecentIds(_recentSeriesHistoryKey(profile), next);
  }

  String _movieProgressKey(XtreamProfile profile) =>
      '$_movieProgressPrefix${profile.id}';

  String _episodeProgressKey(XtreamProfile profile) =>
      '$_episodeProgressPrefix${profile.id}';

  String _lastVodPlayKey(XtreamProfile profile) =>
      '$_lastVodPlayPrefix${profile.id}';

  Map<int, PlaybackProgress> _readProgressMap(
    SharedPreferences prefs,
    String key,
  ) {
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final result = <int, PlaybackProgress>{};
      for (final entry in decoded.entries) {
        final id = int.tryParse(entry.key.toString());
        if (id == null || entry.value is! Map) continue;
        result[id] = PlaybackProgress.fromJson(
          (entry.value as Map).map(
            (key, value) => MapEntry(key.toString(), value),
          ),
        );
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  Future<void> _persistProgressMap(
    String key,
    Map<int, PlaybackProgress> values,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = values.map(
      (id, progress) => MapEntry(id.toString(), progress.toJson()),
    );
    await prefs.setString(key, jsonEncode(encoded));
  }

  _LastVodPlay? _readLastVodPlay(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return _LastVodPlay.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _persistLastVodPlay(_LastVodPlay value) async {
    final profile = _profile;
    if (profile == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastVodPlayKey(profile), jsonEncode(value.toJson()));
  }

  bool _movieCanResume(int id) => _movieProgress[id]?.canResume ?? false;

  PlaybackProgress? _seriesWatchProgress(SeriesShow show) {
    final last = _lastVodPlay;
    if (last?.type == 'episode' &&
        last?.seriesId == show.id &&
        last?.episodeId != null) {
      return _episodeProgress[last!.episodeId!];
    }
    return null;
  }

  bool _seriesCanResume(SeriesShow show) =>
      _seriesWatchProgress(show)?.canResume ?? false;

  int? _seriesResumeEpisodeId(SeriesShow show) {
    final last = _lastVodPlay;
    if (last?.type == 'episode' &&
        last?.seriesId == show.id &&
        last?.episodeId != null) {
      return last!.episodeId;
    }
    return null;
  }

  int get _movieDetailTvActionCount =>
      _selectedMovie != null &&
          _isAndroidTv &&
          _movieCanResume(_selectedMovie!.id)
      ? 4
      : 3;

  List<String> get _movieDetailTvActionLabels {
    if (_selectedMovie != null && _movieCanResume(_selectedMovie!.id)) {
      return const ['Riprendi', 'Ricomincia', 'Preferiti', 'Indietro'];
    }
    return const ['Riproduci', 'Preferiti', 'Indietro'];
  }

  Future<void> _setLastVodMovie(int movieId) async {
    final value = _LastVodPlay(
      type: 'movie',
      movieId: movieId,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (!mounted) return;
    setState(() => _lastVodPlay = value);
    await _persistLastVodPlay(value);
  }

  Future<void> _setLastVodEpisode({
    required int seriesId,
    required int episodeId,
  }) async {
    final value = _LastVodPlay(
      type: 'episode',
      seriesId: seriesId,
      episodeId: episodeId,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (!mounted) return;
    setState(() => _lastVodPlay = value);
    await _persistLastVodPlay(value);
  }

  Future<void> _saveMovieProgress(
    XtreamProfile profile,
    int movieId,
    PlaybackProgress progress,
  ) async {
    final next = Map<int, PlaybackProgress>.from(_movieProgress)
      ..[movieId] = progress;
    if (!mounted) return;
    setState(() => _movieProgress = next);
    await _persistProgressMap(_movieProgressKey(profile), next);
  }

  Future<void> _saveEpisodeProgress(
    XtreamProfile profile,
    int episodeId,
    PlaybackProgress progress,
  ) async {
    final next = Map<int, PlaybackProgress>.from(_episodeProgress)
      ..[episodeId] = progress;
    if (!mounted) return;
    setState(() => _episodeProgress = next);
    await _persistProgressMap(_episodeProgressKey(profile), next);
  }

  int _currentPlaybackPositionMs() {
    final mediaPlayer = _player;
    if (mediaPlayer != null) {
      return mediaPlayer.state.position.inMilliseconds;
    }
    final apple = _appleVideoController?.value;
    if (apple != null && apple.isInitialized) {
      return apple.position.inMilliseconds;
    }
    final tizen = _tizenVideoController?.value;
    if (tizen != null && tizen.isInitialized) {
      return tizen.position.inMilliseconds;
    }
    return 0;
  }

  int _currentPlaybackDurationMs() {
    final mediaPlayer = _player;
    if (mediaPlayer != null) {
      return mediaPlayer.state.duration.inMilliseconds;
    }
    final apple = _appleVideoController?.value;
    if (apple != null && apple.isInitialized) {
      return apple.duration.inMilliseconds;
    }
    final tizen = _tizenVideoController?.value;
    if (tizen != null && tizen.isInitialized) {
      return tizen.duration.end.inMilliseconds;
    }
    return 0;
  }

  Future<void> _flushPlaybackProgress() async {
    final profile = _profile;
    if (profile == null) return;
    final durationMs = _currentPlaybackDurationMs();
    if (durationMs <= 0) return;
    final positionMs = _currentPlaybackPositionMs().clamp(0, durationMs);
    final progress = PlaybackProgress(
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (_activeMovieId != null) {
      await _saveMovieProgress(profile, _activeMovieId!, progress);
    }
    if (_activeEpisodeId != null) {
      await _saveEpisodeProgress(profile, _activeEpisodeId!, progress);
    }
  }

  void _beginPlaybackTracking({int? movieId, int? episodeId}) {
    _playbackProgressTimer?.cancel();
    _activeMovieId = movieId;
    _activeEpisodeId = episodeId;
    _playbackProgressTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(_flushPlaybackProgress()),
    );
  }

  Future<void> _endPlaybackTracking({bool save = true}) async {
    _playbackProgressTimer?.cancel();
    _playbackProgressTimer = null;
    if (save) await _flushPlaybackProgress();
    _activeMovieId = null;
    _activeEpisodeId = null;
  }

  TvHomeHeroTarget? _buildTvHomeHeroTarget() {
    final last = _lastVodPlay;
    if (last != null) {
      if (last.type == 'movie' && last.movieId != null) {
        final byId = {for (final movie in _movies) movie.id: movie};
        final movie = byId[last.movieId];
        if (movie != null) {
          final progress = _movieProgress[movie.id];
          return TvHomeHeroTarget(
            eyebrow: 'CONTINUA A GUARDARE',
            title: movie.name,
            imageUrl: movie.logo,
            actionLabel: progress?.canResume == true ? 'Riprendi' : 'Riproduci',
            progress: progress,
            onAction: () => unawaited(_playMovie(movie)),
          );
        }
      }
      if (last.type == 'episode' && last.seriesId != null) {
        final byId = {for (final show in _series) show.id: show};
        final show = byId[last.seriesId];
        if (show != null) {
          final episodeId = last.episodeId;
          final progress = episodeId == null
              ? null
              : _episodeProgress[episodeId];
          return TvHomeHeroTarget(
            eyebrow: 'CONTINUA A GUARDARE',
            title: show.name,
            imageUrl: show.logo,
            actionLabel: progress?.canResume == true && episodeId != null
                ? 'Continua'
                : 'Apri serie',
            progress: progress,
            onAction: () {
              if (progress?.canResume == true && episodeId != null) {
                unawaited(_continueSeries(show, episodeId: episodeId));
              } else {
                unawaited(_changeSection(AppSection.series));
                unawaited(_openSeries(show));
              }
            },
          );
        }
      }
    }
    if (_recentMovieHistory.isNotEmpty) {
      final movie = _recentMovieHistory.first;
      final progress = _movieProgress[movie.id];
      return TvHomeHeroTarget(
        eyebrow: 'CONTINUA A GUARDARE',
        title: movie.name,
        imageUrl: movie.logo,
        actionLabel: progress?.canResume == true ? 'Riprendi' : 'Riproduci',
        progress: progress,
        onAction: () => unawaited(_playMovie(movie)),
      );
    }
    if (_recentSeriesHistory.isNotEmpty) {
      final show = _recentSeriesHistory.first;
      return TvHomeHeroTarget(
        eyebrow: 'CONTINUA A GUARDARE',
        title: show.name,
        imageUrl: show.logo,
        actionLabel: 'Apri serie',
        onAction: () {
          unawaited(_changeSection(AppSection.series));
          unawaited(_openSeries(show));
        },
      );
    }
    return null;
  }

  Future<void> _continueSeries(
    SeriesShow show, {
    required int episodeId,
  }) async {
    await _changeSection(AppSection.series);
    await _openSeries(show);
    SeriesEpisode? episode;
    for (final item in _seriesEpisodes) {
      if (item.id == episodeId) {
        episode = item;
        break;
      }
    }
    if (episode != null) {
      await _playEpisode(episode);
    }
  }

  List<LiveChannel> get _recentLiveChannels {
    final byId = {for (final channel in _liveChannels) channel.id: channel};
    return _recentLiveChannelIds
        .map((id) => byId[id])
        .whereType<LiveChannel>()
        .toList();
  }

  List<VodMovie> get _recentMovieHistory {
    final byId = {for (final movie in _movies) movie.id: movie};
    return _recentMovieHistoryIds
        .map((id) => byId[id])
        .whereType<VodMovie>()
        .toList();
  }

  List<SeriesShow> get _recentSeriesHistory {
    final byId = {for (final show in _series) show.id: show};
    return _recentSeriesHistoryIds
        .map((id) => byId[id])
        .whereType<SeriesShow>()
        .toList();
  }

  List<VodMovie> get _currentMovieBrowseList {
    return switch (_section) {
      AppSection.favorites => _favoriteMovies,
      AppSection.movies => _filteredMovies,
      _ => _filteredMovies,
    };
  }

  Future<void> _enterMovieBrowse() async {
    final movies = _currentMovieBrowseList;
    if (movies.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final lastId = prefs.getInt(_lastMovieIdKey);
    var index = 0;
    if (lastId != null && _section == AppSection.movies) {
      final found = movies.indexWhere((movie) => movie.id == lastId);
      if (found >= 0) index = found;
    }
    if (!mounted) return;
    setState(() => _tvContentIndex = index.clamp(0, movies.length - 1));
    await _previewMovieAt(_tvContentIndex);
  }

  Future<void> _enterSeriesBrowse() async {
    final prefs = await SharedPreferences.getInstance();
    final lastId = prefs.getInt(_lastSeriesIdKey);
    var index = 0;
    if (lastId != null) {
      final found = _filteredSeries.indexWhere((show) => show.id == lastId);
      if (found >= 0) index = found;
    }
    if (!mounted) return;
    setState(() => _tvContentIndex = index);
    await _previewSeriesAt(index);
  }

  Future<void> _previewMovieAt(int index) async {
    final movies = _currentMovieBrowseList;
    if (movies.isEmpty) return;
    final movie = movies[index.clamp(0, movies.length - 1)];
    final cached = _movieDescriptionCache[movie.id];
    if (cached != null) {
      setState(() {
        _browseHeroItemId = movie.id;
        _browseHeroDescription = cached;
        _browseHeroLoading = false;
      });
      return;
    }
    setState(() {
      _browseHeroItemId = movie.id;
      _browseHeroDescription = '';
      _browseHeroLoading = true;
    });
    final profile = _profile;
    if (profile == null) {
      if (mounted) setState(() => _browseHeroLoading = false);
      return;
    }
    try {
      final detail = await XtreamClient(profile).vodDetail(movie);
      _movieDescriptionCache[movie.id] = detail.description;
      _movieGenreCache[movie.id] = detail.genre;
      if (!mounted || _browseHeroItemId != movie.id) return;
      setState(() {
        _browseHeroDescription = detail.description;
        _browseHeroLoading = false;
      });
    } catch (_) {
      if (mounted && _browseHeroItemId == movie.id) {
        setState(() => _browseHeroLoading = false);
      }
    }
  }

  Future<void> _previewSeriesAt(int index) async {
    if (_filteredSeries.isEmpty) return;
    final show = _filteredSeries[index.clamp(0, _filteredSeries.length - 1)];
    final cached = _seriesDescriptionCache[show.id];
    if (cached != null) {
      setState(() {
        _browseHeroItemId = show.id;
        _browseHeroDescription = cached;
        _browseHeroLoading = false;
      });
      return;
    }
    setState(() {
      _browseHeroItemId = show.id;
      _browseHeroDescription = '';
      _browseHeroLoading = true;
    });
    final profile = _profile;
    if (profile == null) {
      if (mounted) setState(() => _browseHeroLoading = false);
      return;
    }
    try {
      final detail = await XtreamClient(profile).seriesDetail(show);
      _seriesDescriptionCache[show.id] = detail.description;
      _seriesGenreCache[show.id] = detail.genre;
      if (!mounted || _browseHeroItemId != show.id) return;
      setState(() {
        _browseHeroDescription = detail.description;
        _browseHeroLoading = false;
      });
    } catch (_) {
      if (mounted && _browseHeroItemId == show.id) {
        setState(() => _browseHeroLoading = false);
      }
    }
  }

  Future<void> _setRemoteKeyPassthrough(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _storageChannel.invokeMethod('setRemoteKeyPassthrough', {
        'enabled': enabled,
      });
    } catch (_) {}
  }

  Future<void> _syncRemotePassthrough() async {
    if (!_isAndroidTv) return;
    final enabled = _tvSearchEditing || _isEditingText || !_remoteMenuMode;
    if (enabled == _remotePassthroughActive) return;
    _remotePassthroughActive = enabled;
    await _setRemoteKeyPassthrough(enabled);
  }

  Future<void> _enterTvSearchEditing() async {
    if (!_isAndroidTv) {
      _searchFocusNode.requestFocus();
      setState(() => _status = 'Cerca: inserisci testo e premi invio.');
      return;
    }
    setState(() {
      _tvSearchEditing = true;
      _remoteSearchSelected = true; // apre il campo TextField
      _remoteSearchIconFocused = false; // icona non più solo evidenziata
      _status = 'Cerca: usa la tastiera del telecomando e premi invio.';
    });
    await _syncRemotePassthrough();
    if (!mounted) return;
    _searchFocusNode.requestFocus();
  }

  Future<void> _exitTvSearchEditing() async {
    if (!_tvSearchEditing) return;
    setState(() => _tvSearchEditing = false);
    await _syncRemotePassthrough();
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    _shellFocusNode.requestFocus();
  }

  void _requestShellFocus() {
    unawaited(_exitTvSearchEditing());
    setState(() => _remoteMenuMode = true);
    FocusManager.instance.primaryFocus?.unfocus();
    _contentFocusScopeNode.unfocus();
    _shellFocusNode.requestFocus();
    unawaited(_syncRemotePassthrough());
  }

  void _enterContentMode() {
    if (_remoteMenuMode) {
      setState(() => _remoteMenuMode = false);
    }
    unawaited(_syncRemotePassthrough());
    _focusFirstContentControl();
  }

  void _handleAndroidBack() {
    if (_query.trim().isNotEmpty) {
      _clearSearchAndReturnHome();
      return;
    }
    if (_playerFocusMode) {
      _togglePlayerFocusMode();
      return;
    }
    if (!_remoteMenuMode) {
      _requestShellFocus();
      return;
    }
    if (_section != AppSection.home) {
      unawaited(_changeSection(AppSection.home));
    }
  }

  void _focusFirstContentControl() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _remoteMenuMode || _playerFocusMode) return;
      _contentFocusScopeNode.requestFocus();
      _contentFocusScopeNode.nextFocus();
    });
  }

  bool get _isEditingText {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _handleShellKey(KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_isEditingText) {
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.browserBack) {
        FocusManager.instance.primaryFocus?.unfocus();
        _shellFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (_playerFocusMode) {
      return _handleFullscreenPlayerKey(key);
    }
    if (!_remoteMenuMode) {
      return _handleContentKey(key);
    }
    return _handleRemoteMenuLogicalKey(key);
  }

  KeyEventResult _handleFullscreenPlayerKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      _togglePlayerFocusMode();
      return KeyEventResult.handled;
    }
    if (_isAndroidTv) {
      _revealFullscreenOverlay(resetTimer: true);
    }
    if (_livePlayerActive) {
      if (key == LogicalKeyboardKey.arrowUp) {
        unawaited(_playAdjacentLiveChannel(-1));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        unawaited(_playAdjacentLiveChannel(1));
        return KeyEventResult.handled;
      }
      if (!_isAndroidTv) {
        return KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        _moveEpgProgrammeSelection(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _moveEpgProgrammeSelection(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.space) {
        final channel = _selectedLiveChannel;
        final programme = _selectedGuideProgrammeFor(channel);
        if (channel != null && programme != null) {
          unawaited(_playProgramme(channel, programme));
        }
        return KeyEventResult.handled;
      }
    } else {
      if (_isAndroidTv && _vodToolbarIndex >= 0) {
        return _handleVodToolbarKey(key);
      }
      if (key == LogicalKeyboardKey.arrowDown && _isAndroidTv) {
        setState(() {
          _vodToolbarIndex = 0;
          _fullscreenOverlayVisible = true;
          _status =
              'Toolbar: ${_vodToolbarLabels[0]} — Sin/Des seleziona, OK attiva, Su esci';
        });
        _fullscreenOverlayTimer?.cancel();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        unawaited(_seekFullscreenRelative(const Duration(seconds: -10)));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        unawaited(_seekFullscreenRelative(const Duration(seconds: 10)));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        unawaited(_cycleFullscreenAudioTrack(1));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        unawaited(_cycleFullscreenSubtitleTrack(1));
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      if (!_livePlayerActive && _isAndroidTv && _vodToolbarIndex < 0) {
        unawaited(_toggleFullscreenPlayPause());
        return KeyEventResult.handled;
      }
      _revealFullscreenOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _handleVodToolbarKey(LogicalKeyboardKey key) {
    final maxIndex = _vodToolbarLabels.length - 1;
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _vodToolbarIndex = -1;
        _status = 'Video: Su/Giu audio/sottotitoli, Giù toolbar, OK play/pausa';
      });
      _scheduleFullscreenOverlayHide();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      final next = (_vodToolbarIndex - 1).clamp(0, maxIndex);
      setState(() {
        _vodToolbarIndex = next;
        _status =
            'Toolbar: ${_vodToolbarLabels[next]} — Sin/Des seleziona, OK attiva, Su esci';
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      final next = (_vodToolbarIndex + 1).clamp(0, maxIndex);
      setState(() {
        _vodToolbarIndex = next;
        _status =
            'Toolbar: ${_vodToolbarLabels[next]} — Sin/Des seleziona, OK attiva, Su esci';
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      unawaited(_activateVodToolbarControl(_vodToolbarIndex));
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  Future<void> _activateVodToolbarControl(int index) async {
    switch (index) {
      case 0:
        await _toggleFullscreenPlayPause();
      case 1:
        await _seekFullscreenRelative(const Duration(seconds: -10));
      case 2:
        await _seekFullscreenRelative(const Duration(seconds: 10));
      case 3:
        await _cycleFullscreenAudioTrack(1);
      case 4:
        await _cycleFullscreenSubtitleTrack(1);
      case 5:
        _togglePlayerFocusMode();
    }
    _revealFullscreenOverlay();
  }

  Future<void> _toggleFullscreenPlayPause() async {
    final mediaPlayer = _player;
    if (mediaPlayer == null) return;
    if (mediaPlayer.state.playing) {
      await mediaPlayer.pause();
      if (mounted) setState(() => _status = 'Pausa');
    } else {
      await mediaPlayer.play();
      if (mounted) setState(() => _status = 'Riproduzione');
    }
  }

  KeyEventResult _handleContentKey(LogicalKeyboardKey key) {
    _traceTv(
      'content key=${key.keyLabel} section=$_section index=$_tvContentIndex '
      'count=$_tvContentItemCount menuMode=$_remoteMenuMode playerFocus=$_playerFocusMode',
    );
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      if (_query.trim().isNotEmpty) {
        _clearSearchAndReturnHome();
        return KeyEventResult.handled;
      }
      if (_playerFocusMode) {
        _togglePlayerFocusMode();
      } else {
        _requestShellFocus();
      }
      return KeyEventResult.handled;
    }
    if (_section == AppSection.home) {
      final handled = _handleHomeContentKey(key);
      if (handled) {
        return KeyEventResult.handled;
      }
    }
    if (_isAndroidTv &&
        _selectedMovie == null &&
        (_section == AppSection.movies || _section == AppSection.favorites)) {
      final handled = _handleMovieBrowseContentKey(key);
      if (handled) return KeyEventResult.handled;
    }
    if (_tvContentItemCount <= 0) {
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.goBack ||
          key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.browserBack) {
        _requestShellFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowRight) {
        _requestShellFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    if (_section == AppSection.settings) {
      final settingsStart = _profiles.length;
      final saveIndex = settingsStart + 4;
      final reloadIndex = settingsStart + 5;
      if (key == LogicalKeyboardKey.arrowRight &&
          _tvContentIndex == saveIndex) {
        _moveTvContentSelection(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft &&
          _tvContentIndex == reloadIndex) {
        _moveTvContentSelection(-1);
        return KeyEventResult.handled;
      }
    }
    if (_section == AppSection.epg) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _moveEpgProgrammeSelection(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _moveEpgProgrammeSelection(1);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_tvContentIndex <= 0) {
        _requestShellFocus();
      } else {
        _moveTvContentSelection(_horizontalTvStep(-1));
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _moveTvContentSelection(_horizontalTvStep(1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveTvContentSelection(-_verticalTvStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveTvContentSelection(_verticalTvStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      unawaited(_activateTvContentSelection());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _handleMovieBrowseContentKey(LogicalKeyboardKey key) {
    if (_browseHeroActionSelected) {
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.space) {
        final movies = _currentMovieBrowseList;
        if (movies.isNotEmpty) {
          final movie = movies[_tvContentIndex.clamp(0, movies.length - 1)];
          _toggleFavoriteMovie(movie);
        }
        return true;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        setState(() {
          _browseHeroActionSelected = false;
          _status = 'Selezionato: ${_tvContentSelectionLabel(_tvContentIndex)}';
        });
        return true;
      }
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _browseHeroActionSelected = true;
        _status = 'Preferiti: premi OK per aggiungere o rimuovere.';
      });
      return true;
    }
    return false;
  }

  bool _handleHomeContentKey(LogicalKeyboardKey key) {
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight &&
        key != LogicalKeyboardKey.arrowUp &&
        key != LogicalKeyboardKey.arrowDown) {
      return false;
    }
    if (_isAndroidTv) {
      if (_homeTargets.isEmpty) {
        return false;
      }
      final maxIndex = (_homeTargets.length - 1).clamp(0, 3);
      final current = _tvContentIndex.clamp(0, maxIndex);
      int? next;
      if (key == LogicalKeyboardKey.arrowLeft) {
        next = current > 0 ? current - 1 : null;
      } else if (key == LogicalKeyboardKey.arrowRight) {
        next = current < maxIndex ? current + 1 : current;
      } else if (key == LogicalKeyboardKey.arrowUp) {
        next = null;
      } else if (key == LogicalKeyboardKey.arrowDown) {
        next = current;
      }
      if (next == null) {
        _requestShellFocus();
        return true;
      }
      _moveTvContentSelection(next - current);
      return true;
    }
    final compact = _isCompactHomeLayout;
    final maxIndex = (_homeTargets.length - 1).clamp(0, 7);
    final current = _tvContentIndex.clamp(0, maxIndex);
    int? next;
    if (compact) {
      next = switch (key) {
        LogicalKeyboardKey.arrowLeft =>
          current >= 3 ? (current > 3 ? current - 1 : null) : null,
        LogicalKeyboardKey.arrowRight =>
          current >= 3 ? (current < 7 ? current + 1 : current) : current,
        LogicalKeyboardKey.arrowUp => switch (current) {
          0 => null,
          1 => 0,
          2 => 1,
          3 || 4 => 2,
          5 || 6 || 7 => 4,
          _ => current,
        },
        LogicalKeyboardKey.arrowDown => switch (current) {
          0 => 1,
          1 => 2,
          2 => 3,
          3 || 4 => 5,
          5 || 6 => maxIndex,
          _ => current,
        },
        _ => current,
      };
    } else {
      next = switch (key) {
        LogicalKeyboardKey.arrowLeft => switch (current) {
          0 || 3 => null,
          1 || 2 => 0,
          _ => current - 1,
        },
        LogicalKeyboardKey.arrowRight => switch (current) {
          0 => 1,
          3 || 4 || 5 || 6 => (current + 1).clamp(0, maxIndex),
          _ => current,
        },
        LogicalKeyboardKey.arrowUp => switch (current) {
          0 => current,
          1 => current,
          2 => 1,
          3 || 4 || 5 => 0,
          6 || 7 => 2,
          _ => current,
        },
        LogicalKeyboardKey.arrowDown => switch (current) {
          0 => 3,
          1 => 2,
          2 => 6,
          _ => current,
        },
        _ => current,
      };
    }
    if (next == null) {
      _requestShellFocus();
      return true;
    }
    next = next.clamp(0, maxIndex).toInt();
    _moveTvContentSelection(next - current);
    return true;
  }

  int _horizontalTvStep(int direction) => direction < 0 ? -1 : 1;

  int get _verticalTvStep {
    return switch (_section) {
      AppSection.home => _isCompactHomeLayout ? 1 : 2,
      AppSection.live => 1,
      AppSection.movies =>
        _selectedMovie == null ? (_isAndroidTv ? 1 : _catalogGridColumns) : 1,
      AppSection.series =>
        _selectedSeries == null ? (_isAndroidTv ? 1 : _catalogGridColumns) : 1,
      AppSection.favorites ||
      AppSection.watchLater ||
      AppSection.recentlyAdded ||
      AppSection.downloads => _catalogGridColumns,
      AppSection.epg => 1,
      AppSection.settings => 1,
    };
  }

  bool get _isCompactHomeLayout {
    final mediaQuery = MediaQuery.maybeOf(context);
    if (_isAndroidTv) return false;
    return _useCompactAdaptiveLayout(mediaQuery?.size ?? const Size(1280, 720));
  }

  bool get _contentDescendantsAreFocusable => !_isAndroidTv || !_remoteMenuMode;

  double get _contentViewportWidth {
    if (!mounted) return 1280;
    final mediaQuery = MediaQuery.maybeOf(context);
    final width = mediaQuery?.size.width ?? 1280;
    return (width - 300).clamp(320.0, 4000.0);
  }

  int get _catalogGridColumns {
    final available = (_contentViewportWidth - 56).clamp(320.0, 4000.0);
    const tileWidth = 210.0;
    const spacing = 18.0;
    return ((available + spacing) / (tileWidth + spacing)).floor().clamp(1, 8);
  }

  int get _tvContentItemCount {
    return switch (_section) {
      AppSection.home => _homeTargets.length,
      AppSection.live => _filteredLive.length,
      AppSection.movies =>
        _selectedMovie == null
            ? _filteredMovies.length
            : (_isAndroidTv ? _movieDetailTvActionCount : 3),
      AppSection.series =>
        _selectedSeries == null
            ? _filteredSeries.length
            : _seriesEpisodes.length + 1,
      AppSection.favorites => _favoriteMovies.length,
      AppSection.watchLater => _watchLaterMovies.length,
      AppSection.recentlyAdded => _movies.take(350).length,
      AppSection.epg => _epgChannels.length,
      AppSection.downloads => _watchLaterMovies.length,
      AppSection.settings => _profiles.length + 6,
    };
  }

  String _tvContentSelectionLabel(int index) {
    if (index < 0) return 'Contenuto';
    return switch (_section) {
      AppSection.home =>
        _homeTargets.isEmpty
            ? 'Contenuto'
            : _sectionLabel(
                _homeTargets[index.clamp(0, _homeTargets.length - 1)],
              ),
      AppSection.live =>
        _filteredLive.isEmpty
            ? 'Nessun canale'
            : _filteredLive[index.clamp(0, _filteredLive.length - 1)].name,
      AppSection.movies =>
        _selectedMovie == null
            ? (_filteredMovies.isEmpty
                  ? 'Nessun film'
                  : _filteredMovies[index.clamp(0, _filteredMovies.length - 1)]
                        .name)
            : (_isAndroidTv
                  ? _movieDetailTvActionLabels[index.clamp(
                      0,
                      _movieDetailTvActionLabels.length - 1,
                    )]
                  : ['Play', 'Download', 'Indietro'][index.clamp(0, 2)]),
      AppSection.series =>
        _selectedSeries == null
            ? (_filteredSeries.isEmpty
                  ? 'Nessuna serie'
                  : _filteredSeries[index.clamp(0, _filteredSeries.length - 1)]
                        .name)
            : index == 0
            ? 'Indietro'
            : (_seriesEpisodes.isEmpty
                  ? 'Nessun episodio'
                  : _seriesEpisodes[(index - 1).clamp(
                          0,
                          _seriesEpisodes.length - 1,
                        )]
                        .title),
      AppSection.favorites =>
        _favoriteMovies.isEmpty
            ? 'Nessun preferito'
            : _favoriteMovies[index.clamp(0, _favoriteMovies.length - 1)].name,
      AppSection.watchLater =>
        _watchLaterMovies.isEmpty
            ? 'Nessun titolo'
            : _watchLaterMovies[index.clamp(0, _watchLaterMovies.length - 1)]
                  .name,
      AppSection.recentlyAdded =>
        _movies.isEmpty
            ? 'Nessun titolo'
            : _movies
                  .take(350)
                  .toList()[index.clamp(0, _movies.take(350).length - 1)]
                  .name,
      AppSection.epg =>
        _epgChannels.isEmpty
            ? 'Nessun canale'
            : _epgChannels[index.clamp(0, _epgChannels.length - 1)].name,
      AppSection.downloads =>
        _watchLaterMovies.isEmpty
            ? 'Nessun download'
            : _watchLaterMovies[index.clamp(0, _watchLaterMovies.length - 1)]
                  .name,
      AppSection.settings => _settingsSelectionLabel(index),
    };
  }

  String _settingsSelectionLabel(int index) {
    if (index < _profiles.length) {
      final profile = _profiles[index];
      return profile.title.trim().isEmpty
          ? profile.displayName
          : profile.title.trim();
    }
    final offset = index - _profiles.length;
    const labels = [
      'Nome lista',
      'Server URL',
      'Username',
      'Password',
      'Salva e carica',
      'Ricarica dal provider',
    ];
    return labels[offset.clamp(0, labels.length - 1)];
  }

  void _moveTvContentSelection(int delta) {
    final count = _tvContentItemCount;
    if (count <= 0) return;
    final next = (_tvContentIndex + delta).clamp(0, count - 1).toInt();
    if (next == _tvContentIndex) return;
    _traceTv(
      'move selection section=$_section from=$_tvContentIndex to=$next '
      'delta=$delta label="${_tvContentSelectionLabel(next)}"',
    );
    setState(() {
      _tvContentIndex = next;
      _browseHeroActionSelected = false;
      _status = 'Selezionato: ${_tvContentSelectionLabel(next)}';
    });
    if (_section == AppSection.live) {
      _previewLiveChannelAt(next);
    } else if (_section == AppSection.epg) {
      _previewEpgChannelAt(next);
    } else if (_isAndroidTv &&
        (_section == AppSection.movies || _section == AppSection.favorites) &&
        _selectedMovie == null) {
      unawaited(_previewMovieAt(next));
    } else if (_isAndroidTv &&
        _section == AppSection.series &&
        _selectedSeries == null) {
      unawaited(_previewSeriesAt(next));
    }
  }

  void _setLiveCategory(String id) {
    setState(() {
      _liveCategoryId = id;
      _tvContentIndex = 0;
      _selectedLiveEpg = const [];
    });
    final size = MediaQuery.sizeOf(context);
    if (_useHandheldPhoneShell(size)) {
      unawaited(_prefetchLiveListEpgs());
    } else {
      _previewLiveChannelAt(0);
    }
  }

  void _setEpgCategory(String id) {
    if (_liveCategoryId == id) return;
    _epgLoadGeneration += 1;
    setState(() {
      _liveCategoryId = id;
      _tvContentIndex = 0;
      _selectedLiveEpg = const [];
      _epgGuideDayOffset = 0;
    });
    unawaited(_reloadEpgAfterCategoryChange());
  }

  Future<void> _reloadEpgAfterCategoryChange() async {
    for (final channel in _epgChannels) {
      _epgByChannel.remove(channel.id);
    }
    await _loadEpgPage();
    if (!mounted) return;
    _previewEpgChannelAt(0);
  }

  bool _epgCoverageIsShallow(List<EpgProgramme> programmes) {
    if (programmes.isEmpty) return true;
    final now = DateTime.now();
    final minStart = now.subtract(
      Duration(days: _guideDefaultLookbackDays - 1),
    );
    return !programmes.any((programme) {
      final start = programme.start;
      return start != null && !start.isAfter(minStart);
    });
  }

  void _setMovieCategory(String id) {
    setState(() {
      _movieCategoryId = id;
      _tvContentIndex = 0;
    });
    if (_isAndroidTv) unawaited(_previewMovieAt(0));
  }

  void _setSeriesCategory(String id) {
    setState(() {
      _seriesCategoryId = id;
      _tvContentIndex = 0;
    });
    if (_isAndroidTv) unawaited(_previewSeriesAt(0));
  }

  void _previewLiveChannelAt(int index) {
    if (_filteredLive.isEmpty) {
      setState(() {
        _tvContentIndex = 0;
        _selectedLiveChannel = null;
        _selectedLiveEpg = const [];
        _playerTitle = 'Scegli qualcosa da guardare.';
        _status = 'Nessun canale disponibile per questa categoria.';
      });
      return;
    }
    final safeIndex = index.clamp(0, _filteredLive.length - 1).toInt();
    final channel = _filteredLive[safeIndex];
    if (_selectedLiveChannel?.id == channel.id && _selectedLiveEpg.isNotEmpty) {
      setState(() => _tvContentIndex = safeIndex);
      return;
    }
    setState(() {
      _tvContentIndex = safeIndex;
      _selectedLiveChannel = channel;
      _playerTitle = channel.name;
      _status = 'Canale selezionato: ${channel.name}';
    });
    unawaited(_recordRecentLiveChannel(channel.id));
    unawaited(_loadChannelEpg(channel));
  }

  void _previewEpgChannelAt(int index) {
    if (_epgChannels.isEmpty) return;
    final safeIndex = index.clamp(0, _epgChannels.length - 1).toInt();
    final channel = _epgChannels[safeIndex];
    final cached = _epgByChannel[channel.id] ?? const <EpgProgramme>[];
    final hasUsableCache = cached.isNotEmpty && !_epgCoverageIsShallow(cached);
    if (_selectedLiveChannel?.id == channel.id && hasUsableCache) {
      setState(() {
        _tvContentIndex = safeIndex;
        _selectedLiveChannel = channel;
        final programmes = _epgGuideProgrammes(channel);
        _epgProgrammeIndex = programmes.isEmpty
            ? 0
            : _defaultProgrammeIndex(programmes);
        _status = 'Guida TV: ${channel.name}';
      });
      return;
    }
    setState(() {
      _tvContentIndex = safeIndex;
      _selectedLiveChannel = channel;
      final programmes = _epgGuideProgrammes(channel);
      _epgProgrammeIndex = programmes.isEmpty
          ? 0
          : _defaultProgrammeIndex(programmes);
      _status = 'Guida TV: ${channel.name}';
    });
    unawaited(_loadChannelEpg(channel));
  }

  int _channelIndexOf(List<LiveChannel> channels, LiveChannel channel) {
    final index = channels.indexWhere((item) => item.id == channel.id);
    return index < 0 ? 0 : index;
  }

  List<EpgProgramme> _epgGuideProgrammes(LiveChannel channel) {
    final source = _epgByChannel[channel.id] ?? const [];
    final dayStart = _guideDayStart(_epgGuideDayOffset);
    final dayEnd = _guideDayEnd(dayStart);
    return _programmesForGuideDay(source, dayStart, dayEnd);
  }

  void _setEpgGuideDayOffset(int offset) {
    final channel = _selectedLiveChannel;
    final clamped = channel == null
        ? offset
        : offset.clamp(-_guideLookbackDays(channel), 1).toInt();
    if (_epgGuideDayOffset == clamped) return;
    setState(() {
      _epgGuideDayOffset = clamped;
      if (channel != null) {
        final programmes = _epgGuideProgrammes(channel);
        _epgProgrammeIndex = programmes.isEmpty
            ? 0
            : _defaultProgrammeIndex(programmes);
      }
    });
    if (channel != null) {
      final programmes = _epgGuideProgrammes(channel);
      if (programmes.isEmpty) {
        unawaited(_loadChannelEpg(channel));
      }
    }
  }

  void _moveEpgProgrammeSelection(int delta) {
    final channel = _selectedLiveChannel;
    if (channel == null) return;
    final programmes = _epgGuideProgrammes(channel);
    if (programmes.isEmpty) return;
    final next = (_epgProgrammeIndex + delta)
        .clamp(0, programmes.length - 1)
        .toInt();
    if (next == _epgProgrammeIndex) return;
    setState(() {
      _epgProgrammeIndex = next;
      _status = 'Guida TV: ${channel.name} - ${programmes[next].title.trim()}';
    });
  }

  List<EpgProgramme> _fullscreenOverlayProgrammes(LiveChannel channel) {
    return _fullscreenOverlayProgrammesFrom(channel, _selectedLiveEpg);
  }

  List<EpgProgramme> _fullscreenOverlayProgrammesFrom(
    LiveChannel channel,
    List<EpgProgramme> source,
  ) {
    return _contextualEpgWindowForChannel(channel, source);
  }

  List<EpgProgramme> _contextualGuideProgrammesFrom(
    LiveChannel channel,
    List<EpgProgramme> source,
  ) {
    return _contextualEpgWindowForChannel(channel, source);
  }

  List<EpgProgramme> _guideProgrammesFrom(
    LiveChannel channel,
    List<EpgProgramme> source,
  ) {
    final items = source
        .where(
          (programme) =>
              _isLiveProgramme(programme) ||
              _canReplayProgramme(channel, programme) ||
              (programme.start?.isAfter(DateTime.now()) ?? false),
        )
        .toList();
    items.sort((a, b) {
      final aStart = a.start;
      final bStart = b.start;
      if (aStart == null && bStart == null) return 0;
      if (aStart == null) return 1;
      if (bStart == null) return -1;
      return aStart.compareTo(bStart);
    });
    return items;
  }

  int _defaultProgrammeIndex(List<EpgProgramme> programmes) {
    if (programmes.isEmpty) return 0;
    final liveIndex = programmes.indexWhere(_isLiveProgramme);
    if (liveIndex >= 0) return liveIndex;
    final now = DateTime.now();
    final nextIndex = programmes.indexWhere(
      (programme) => programme.start?.isAfter(now) ?? false,
    );
    return nextIndex >= 0 ? nextIndex : programmes.length - 1;
  }

  EpgProgramme? _selectedGuideProgrammeFor(LiveChannel? channel) {
    if (channel == null) return null;
    final programmes = _epgGuideProgrammes(channel);
    if (programmes.isEmpty) return null;
    return programmes[_epgProgrammeIndex.clamp(0, programmes.length - 1)];
  }

  bool _isLiveProgramme(EpgProgramme programme) => _epgIsLiveNow(programme);

  EpgProgramme _resolveGuideProgramme(
    LiveChannel channel,
    EpgProgramme programme,
  ) {
    final start = programme.start;
    if (start == null) return programme;
    final source = _epgByChannel[channel.id] ?? const <EpgProgramme>[];
    EpgProgramme? bestByStart;
    var bestDeltaSec = 1 << 30;
    for (final item in source) {
      final itemStart = item.start;
      if (itemStart == null) continue;
      final deltaSec = (itemStart.difference(start).inSeconds).abs();
      if (deltaSec > 180) continue;
      if (itemStart == start && item.end != null) return item;
      final better =
          deltaSec < bestDeltaSec ||
          (deltaSec == bestDeltaSec &&
              item.end != null &&
              bestByStart?.end == null);
      if (better) {
        bestByStart = item;
        bestDeltaSec = deltaSec;
      }
    }
    if (bestByStart != null) return bestByStart;
    for (final item in source) {
      final itemStart = item.start;
      final itemEnd = item.end;
      if (itemStart == null || itemEnd == null) continue;
      if (item.title.trim().toLowerCase() !=
          programme.title.trim().toLowerCase()) {
        continue;
      }
      if ((itemStart.difference(start).inMinutes).abs() > 5) continue;
      return item;
    }
    return programme;
  }

  EpgProgramme _enrichProgramme(LiveChannel channel, EpgProgramme programme) {
    if (programme.end != null) return programme;
    final start = programme.start;
    if (start == null) return programme;
    final source = [...(_epgByChannel[channel.id] ?? const <EpgProgramme>[])]
      ..sort((a, b) {
        final aStart = a.start;
        final bStart = b.start;
        if (aStart == null && bStart == null) return 0;
        if (aStart == null) return 1;
        if (bStart == null) return -1;
        return aStart.compareTo(bStart);
      });
    for (final item in source) {
      final itemStart = item.start;
      if (itemStart != null && itemStart.isAfter(start)) {
        return EpgProgramme(
          title: programme.title,
          description: programme.description,
          start: programme.start,
          end: itemStart,
        );
      }
    }
    return EpgProgramme(
      title: programme.title,
      description: programme.description,
      start: programme.start,
      end: start.add(const Duration(minutes: 60)),
    );
  }

  Future<void> _waitForPlayerSurfaceAttach() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 80));
  }

  bool _canReplayProgramme(LiveChannel channel, EpgProgramme programme) {
    return Catchup.canReplayProgramme(channel, programme);
  }

  Future<void> _activateTvContentSelection() async {
    final index = _tvContentIndex;
    _traceTv(
      'activate section=$_section index=$index label="${_tvContentSelectionLabel(index)}"',
    );
    switch (_section) {
      case AppSection.home:
        if (_homeTargets.isEmpty) return;
        final targets = _homeTargets;
        await _changeSection(targets[index.clamp(0, targets.length - 1)]);
      case AppSection.live:
        if (_filteredLive.isNotEmpty) {
          await _playLive(
            _filteredLive[index.clamp(0, _filteredLive.length - 1)],
          );
        }
      case AppSection.movies:
        if (_selectedMovie == null) {
          if (_filteredMovies.isNotEmpty) {
            _openMovie(
              _filteredMovies[index.clamp(0, _filteredMovies.length - 1)],
            );
          }
        } else if (_isAndroidTv && _movieCanResume(_selectedMovie!.id)) {
          switch (index) {
            case 0:
              await _playMovie(_selectedMovie!);
            case 1:
              await _playMovie(_selectedMovie!, fromStart: true);
            case 2:
              _toggleFavoriteMovie(_selectedMovie!);
            default:
              setState(() {
                _selectedMovie = null;
                _tvContentIndex = 0;
              });
              unawaited(_previewMovieAt(_tvContentIndex));
          }
        } else if (index == 0) {
          await _playMovie(_selectedMovie!, fromStart: true);
        } else if (index == 1 && _isAndroidTv) {
          _toggleFavoriteMovie(_selectedMovie!);
        } else if (index == 1 && !_isAndroidTv) {
          await _downloadMovie(_selectedMovie!);
        } else {
          setState(() {
            _selectedMovie = null;
            _tvContentIndex = 0;
          });
          if (_isAndroidTv) unawaited(_previewMovieAt(_tvContentIndex));
        }
      case AppSection.series:
        if (_selectedSeries == null) {
          if (_filteredSeries.isNotEmpty) {
            await _openSeries(
              _filteredSeries[index.clamp(0, _filteredSeries.length - 1)],
            );
            if (mounted) setState(() => _tvContentIndex = 0);
          }
        } else if (index == 0) {
          setState(() {
            _selectedSeries = null;
            _seriesEpisodes = const [];
            _tvContentIndex = 0;
          });
        } else if (_seriesEpisodes.isNotEmpty) {
          await _playEpisode(
            _seriesEpisodes[(index - 1).clamp(0, _seriesEpisodes.length - 1)],
          );
        }
      case AppSection.favorites:
        if (_favoriteMovies.isNotEmpty) {
          _openMovie(
            _favoriteMovies[index.clamp(0, _favoriteMovies.length - 1)],
          );
        }
      case AppSection.watchLater:
      case AppSection.downloads:
        if (_watchLaterMovies.isNotEmpty) {
          _openMovie(
            _watchLaterMovies[index.clamp(0, _watchLaterMovies.length - 1)],
          );
        }
      case AppSection.recentlyAdded:
        final recent = _movies.take(350).toList();
        if (recent.isNotEmpty) {
          _openMovie(recent[index.clamp(0, recent.length - 1)]);
        }
      case AppSection.epg:
        if (_epgChannels.isNotEmpty) {
          final channel = _epgChannels[index.clamp(0, _epgChannels.length - 1)];
          setState(() => _selectedLiveChannel = channel);
          await _loadChannelEpg(channel);
          final programme = _selectedGuideProgrammeFor(channel);
          if (programme != null &&
              (_isLiveProgramme(programme) ||
                  _canReplayProgramme(channel, programme))) {
            await _openLiveProgrammeFromGuide(channel, programme);
          } else {
            setState(() {
              _status = 'Seleziona un evento LIVE o REC per ${channel.name}.';
            });
          }
        }
      case AppSection.settings:
        if (index < _profiles.length) {
          await _selectProfile(_profiles[index]);
          if (mounted) {
            setState(() => _tvContentIndex = index);
          }
          return;
        }
        switch (index - _profiles.length) {
          case 0:
            _settingsTitleFocusNode.requestFocus();
            setState(() => _status = 'Modifica Nome lista');
            return;
          case 1:
            _settingsServerFocusNode.requestFocus();
            setState(() => _status = 'Modifica Server URL');
            return;
          case 2:
            _settingsUserFocusNode.requestFocus();
            setState(() => _status = 'Modifica Username');
            return;
          case 3:
            _settingsPassFocusNode.requestFocus();
            setState(() => _status = 'Modifica Password');
            return;
          case 4:
            await _saveAndLoadProfile(forceRefresh: false);
            return;
          case 5:
            await _loadCatalog(forceRefresh: true);
            return;
        }
    }
  }

  void _moveRemoteSelection(int delta) {
    final currentIndex = _remoteSections.indexOf(_remoteSection);
    if (currentIndex < 0) return;
    final nextIndex = (currentIndex + delta)
        .clamp(0, _remoteSections.length - 1)
        .toInt();
    if (nextIndex == currentIndex) return;
    _traceTv(
      'move menu from=$_remoteSection to=${_remoteSections[nextIndex]} delta=$delta',
    );
    setState(() {
      _remoteSearchSelected = false;
      _remoteSearchIconFocused = false;
      _remoteSection = _remoteSections[nextIndex];
    });
  }

  Future<void> _loadCatalog({
    XtreamProfile? profile,
    bool forceRefresh = false,
  }) async {
    final activeProfile = profile ?? _profile;
    if (activeProfile == null || !activeProfile.isComplete) return;
    setState(() {
      _section = AppSection.home;
      _remoteSection = AppSection.home;
      _remoteMenuMode = false;
      _tvContentIndex = 0;
      _loading = true;
      _status = 'Caricamento lista: ${activeProfile.displayName}...';
    });
    if (!forceRefresh && await _restoreCatalogCache(activeProfile)) {
      if (mounted) setState(() => _loading = false);
      if (_movies.isEmpty || _series.isEmpty) {
        unawaited(
          _loadMissingCatalogParts(
            activeProfile,
            movies: _movies.isEmpty,
            series: _series.isEmpty,
          ),
        );
      }
      if (_section == AppSection.epg) {
        unawaited(_loadEpgPage(force: true));
      }
      return;
    }
    setState(() {
      _loading = true;
      _status = 'Caricamento account...';
      _resetProfileScopedState();
      _section = AppSection.home;
      _remoteSection = AppSection.home;
      _remoteMenuMode = false;
      _tvContentIndex = 0;
    });
    try {
      final client = XtreamClient(activeProfile);
      final account = await client.accountInfo();
      if (!mounted) return;
      setState(() {
        _accountInfo = account;
        _status = 'Account OK. Caricamento Live TV...';
      });
      unawaited(_loadCategories(client));
      try {
        setState(() => _status = 'Caricamento Live TV...');
        final live = await client.liveStreams();
        if (!mounted) return;
        setState(() {
          _liveChannels = live;
          _status = 'Live TV caricata (${live.length}). Caricamento Film...';
        });
      } catch (error) {
        if (mounted) setState(() => _status = 'Live non caricata: $error');
      }
      try {
        setState(
          () => _status =
              'Caricamento Film... Live disponibili: ${_liveChannels.length}',
        );
        final movies = await client.vodStreams();
        if (!mounted) return;
        setState(() {
          _movies = movies;
          _status = 'Film caricati (${movies.length}). Caricamento Serie...';
        });
      } catch (error) {
        if (mounted) {
          setState(
            () => _status =
                'Film non caricati: $error. Live: ${_liveChannels.length}',
          );
        }
      }
      try {
        setState(
          () => _status =
              'Caricamento Serie... Film disponibili: ${_movies.length}',
        );
        final series = await client.seriesStreams();
        if (!mounted) return;
        setState(() {
          _series = series;
          _status =
              'Caricati ${_liveChannels.length} canali, ${_movies.length} film e ${series.length} serie.';
        });
        await _storeCatalogCache(activeProfile);
      } catch (error) {
        if (mounted) {
          setState(
            () =>
                _status = 'Serie non caricate: $error. Film: ${_movies.length}',
          );
        }
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'Errore catalogo: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _favoriteMoviesKey(XtreamProfile profile) =>
      '$_favoriteMoviesPrefix${profile.id}';

  String _favoriteSeriesKey(XtreamProfile profile) =>
      '$_favoriteSeriesPrefix${profile.id}';

  String _watchLaterMoviesKey(XtreamProfile profile) =>
      '$_watchLaterMoviesPrefix${profile.id}';

  Future<void> _loadMissingCatalogParts(
    XtreamProfile profile, {
    required bool movies,
    required bool series,
  }) async {
    final client = XtreamClient(profile);
    try {
      if (movies) {
        if (mounted) {
          setState(() => _status = 'Caricamento film dal server...');
        }
        final loaded = await client.vodStreams();
        if (!mounted) return;
        setState(() {
          _movies = loaded;
          _status = 'Film caricati (${loaded.length}).';
        });
      }
      if (series) {
        if (mounted) {
          setState(
            () => _status = 'Caricamento serie... Film: ${_movies.length}',
          );
        }
        final loaded = await client.seriesStreams();
        if (!mounted) return;
        setState(() {
          _series = loaded;
          _status =
              'Catalogo aggiornato: ${_movies.length} film, ${loaded.length} serie.';
        });
      }
      await _storeCatalogCache(profile);
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Catalogo incompleto: $error');
      }
    }
  }

  Future<void> _loadSeriesCatalogOnly(XtreamProfile profile) async {
    await _loadMissingCatalogParts(profile, movies: false, series: true);
  }

  Future<void> _prefetchLiveListEpgs() async {
    final profile = _profile;
    if (profile == null || _filteredLive.isEmpty) return;
    if (mounted) setState(() => _liveListEpgPrefetching = true);
    final client = XtreamClient(profile);
    try {
      for (final channel in _filteredLive.take(48)) {
        if (!mounted) return;
        final cached = _epgByChannel[channel.id];
        if (cached != null && cached.isNotEmpty) continue;
        try {
          final programmes = await client.shortEpg(channel, limit: 8);
          if (!mounted) return;
          if (programmes.isEmpty) continue;
          setState(() {
            _epgByChannel[channel.id] = programmes;
          });
        } catch (_) {
          // Best effort: keep scrolling the list usable without EPG.
        }
      }
    } finally {
      if (mounted) setState(() => _liveListEpgPrefetching = false);
    }
  }

  Future<void> _loadUserLists(XtreamProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final favorites = prefs
        .getStringList(_favoriteMoviesKey(profile))
        ?.map(int.tryParse)
        .whereType<int>()
        .toSet();
    final seriesFavorites = prefs
        .getStringList(_favoriteSeriesKey(profile))
        ?.map(int.tryParse)
        .whereType<int>()
        .toSet();
    final watchLater = prefs
        .getStringList(_watchLaterMoviesKey(profile))
        ?.map(int.tryParse)
        .whereType<int>()
        .toSet();
    if (!mounted) return;
    setState(() {
      _favoriteMovieIds
        ..clear()
        ..addAll(favorites ?? const {});
      _favoriteSeriesIds
        ..clear()
        ..addAll(seriesFavorites ?? const {});
      _watchLaterMovieIds
        ..clear()
        ..addAll(watchLater ?? const {});
      _recentLiveChannelIds = _readRecentIds(
        prefs,
        _recentLiveChannelsKey(profile),
      );
      _recentMovieHistoryIds = _readRecentIds(
        prefs,
        _recentMoviesHistoryKey(profile),
      );
      _recentSeriesHistoryIds = _readRecentIds(
        prefs,
        _recentSeriesHistoryKey(profile),
      );
      _movieProgress = _readProgressMap(prefs, _movieProgressKey(profile));
      _episodeProgress = _readProgressMap(prefs, _episodeProgressKey(profile));
      _lastVodPlay = _readLastVodPlay(prefs, _lastVodPlayKey(profile));
    });
  }

  Future<void> _persistUserLists() async {
    final profile = _profile;
    if (profile == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _favoriteMoviesKey(profile),
      _favoriteMovieIds.map((id) => id.toString()).toList()..sort(),
    );
    await prefs.setStringList(
      _favoriteSeriesKey(profile),
      _favoriteSeriesIds.map((id) => id.toString()).toList()..sort(),
    );
    await prefs.setStringList(
      _watchLaterMoviesKey(profile),
      _watchLaterMovieIds.map((id) => id.toString()).toList()..sort(),
    );
  }

  void _toggleFavoriteSeries(SeriesShow show) {
    setState(() {
      _favoriteSeriesIds.contains(show.id)
          ? _favoriteSeriesIds.remove(show.id)
          : _favoriteSeriesIds.add(show.id);
    });
    unawaited(_persistUserLists());
  }

  void _toggleFavoriteMovie(VodMovie movie) {
    setState(() {
      _favoriteMovieIds.contains(movie.id)
          ? _favoriteMovieIds.remove(movie.id)
          : _favoriteMovieIds.add(movie.id);
      if (_isAndroidTv && _section == AppSection.favorites) {
        final count = _favoriteMovies.length;
        if (count == 0) {
          _tvContentIndex = 0;
        } else if (_tvContentIndex >= count) {
          _tvContentIndex = count - 1;
        }
      }
    });
    unawaited(_persistUserLists());
    if (_isAndroidTv &&
        _selectedMovie == null &&
        (_section == AppSection.movies || _section == AppSection.favorites)) {
      unawaited(_previewMovieAt(_tvContentIndex));
    }
  }

  void _toggleWatchLaterMovie(VodMovie movie) {
    setState(() {
      _watchLaterMovieIds.contains(movie.id)
          ? _watchLaterMovieIds.remove(movie.id)
          : _watchLaterMovieIds.add(movie.id);
    });
    unawaited(_persistUserLists());
  }

  String _catalogCacheKey(XtreamProfile profile) {
    return 'leleg.native.catalog.${profile.id}';
  }

  Future<bool> _restoreCatalogCache(XtreamProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_catalogCacheKey(profile));
    if (raw == null || raw.trim().isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      if (decoded['version'] != _catalogCacheVersion) return false;
      final savedAt = DateTime.tryParse(decoded['savedAt']?.toString() ?? '');
      if (savedAt == null ||
          DateTime.now().difference(savedAt) > _catalogCacheTtl) {
        return false;
      }
      final liveCategories = _decodeList(
        decoded['liveCategories'],
        XtreamCategory.fromJson,
      );
      final movieCategories = _decodeList(
        decoded['movieCategories'],
        XtreamCategory.fromJson,
      );
      final seriesCategories = _decodeList(
        decoded['seriesCategories'],
        XtreamCategory.fromJson,
      );
      final live = _decodeList(decoded['liveChannels'], LiveChannel.fromJson);
      final movies = _decodeList(decoded['movies'], VodMovie.fromJson);
      final series = _decodeList(decoded['series'], SeriesShow.fromJson);
      if (live.isEmpty && movies.isEmpty && series.isEmpty) return false;
      if (live.isNotEmpty && movies.isEmpty && series.isEmpty) return false;
      if (!mounted) return false;
      setState(() {
        _resetProfileScopedState();
        _liveCategories = liveCategories;
        _movieCategories = movieCategories;
        _seriesCategories = seriesCategories;
        _liveChannels = live;
        _movies = movies;
        _series = series;
        _status =
            'Catalogo caricato dalla cache (${live.length} canali, ${movies.length} film, ${series.length} serie).';
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  void _resetProfileScopedState() {
    _liveCategories = const [];
    _movieCategories = const [];
    _seriesCategories = const [];
    _liveChannels = const [];
    _selectedLiveChannel = null;
    _selectedLiveEpg = const [];
    XtreamClient.clearXmlTvCache();
    _epgByChannel.clear();
    _movies = const [];
    _selectedMovie = null;
    _selectedMovieDescription = '';
    _selectedMovieGenre = '';
    _series = const [];
    _selectedSeries = null;
    _selectedSeriesDescription = '';
    _selectedSeriesGenre = '';
    _seriesEpisodes = const [];
    _liveCategoryId = '';
    _movieCategoryId = '';
    _seriesCategoryId = '';
    _movieSort = 'default';
    _seriesSort = 'default';
    _query = '';
    _searchController.clear();
  }

  List<T> _decodeList<T>(
    dynamic raw,
    T Function(Map<String, dynamic> json) decoder,
  ) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .map(decoder)
        .toList();
  }

  Future<void> _storeCatalogCache(XtreamProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _catalogCacheKey(profile),
      jsonEncode({
        'savedAt': DateTime.now().toIso8601String(),
        'version': _catalogCacheVersion,
        'liveCategories': _liveCategories.map((item) => item.toJson()).toList(),
        'movieCategories': _movieCategories
            .map((item) => item.toJson())
            .toList(),
        'seriesCategories': _seriesCategories
            .map((item) => item.toJson())
            .toList(),
        'liveChannels': _liveChannels.map((item) => item.toJson()).toList(),
        'movies': _movies.map((item) => item.toJson()).toList(),
        'series': _series.map((item) => item.toJson()).toList(),
      }),
    );
  }

  Future<void> _loadCategories(XtreamClient client) async {
    try {
      final results = await Future.wait([
        client.liveCategories(),
        client.vodCategories(),
        client.seriesCategories(),
      ]);
      if (!mounted) return;
      setState(() {
        _liveCategories = results[0];
        _movieCategories = results[1];
        _seriesCategories = results[2];
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'Categorie non caricate: $error');
    }
  }

  Future<void> _playLive(LiveChannel channel) async {
    final profile = _profile;
    if (profile == null) return;
    final playbackId = ++_livePlaybackGeneration;
    _traceTv('play live channel=${channel.name} id=${channel.id}');
    setState(() {
      _selectedLiveChannel = channel;
      _livePlayerActive = true;
      _playerTitle = channel.name;
    });
    final candidates = <XtreamProfile>[];
    void addCandidate(XtreamProfile candidate) {
      if (candidates.any(
        (item) => item.liveContainer == candidate.liveContainer,
      )) {
        return;
      }
      candidates.add(candidate);
    }

    if (_preferTsLivePlayback) {
      addCandidate(profile.copyWith(liveContainer: 'ts'));
      addCandidate(profile.copyWith(liveContainer: 'm3u8'));
    } else if (Platform.isAndroid && !isTizenRuntime) {
      final primary = profile.liveContainer.trim().toLowerCase();
      final first = primary == 'm3u8' ? 'm3u8' : 'ts';
      final second = first == 'ts' ? 'm3u8' : 'ts';
      addCandidate(profile.copyWith(liveContainer: first));
      addCandidate(profile.copyWith(liveContainer: second));
    } else {
      addCandidate(profile);
      addCandidate(
        profile.copyWith(
          liveContainer: profile.liveContainer == 'ts' ? 'm3u8' : 'ts',
        ),
      );
    }

    var opened = false;
    for (final candidate in candidates) {
      _traceTv(
        'try live container=${candidate.liveContainer} channel=${channel.name}',
      );
      opened = await _openMedia(
        XtreamClient(candidate).liveUrl(channel),
        channel.name,
        preferApple: Platform.isIOS,
        validatePlayback: _preferTsLivePlayback,
        validationTimeout: const Duration(seconds: 8),
      );
      if (playbackId != _livePlaybackGeneration) return;
      if (opened) {
        _enterLivePlaybackFullscreen();
        if (mounted) {
          setState(() {
            _status =
                'In riproduzione: ${channel.name} (${candidate.liveContainer.toUpperCase()})';
          });
        }
        break;
      }
    }
    if (opened) {
      unawaited(_recordRecentLiveChannel(channel.id));
    }
    if (!opened && mounted && playbackId == _livePlaybackGeneration) {
      setState(
        () => _status = 'Riproduzione live non riuscita: ${channel.name}',
      );
    }
    if (playbackId != _livePlaybackGeneration) return;
    unawaited(_loadChannelEpg(channel));
  }

  Future<void> _playProgramme(
    LiveChannel channel,
    EpgProgramme programme,
  ) async {
    final profile = _profile;
    if (profile == null) return;
    final playbackId = ++_livePlaybackGeneration;
    final resolved = _enrichProgramme(
      channel,
      _resolveGuideProgramme(channel, programme),
    );
    final now = DateTime.now();
    final start = resolved.start;
    final end = resolved.end;
    if (start != null &&
        end != null &&
        start.isBefore(now) &&
        end.isAfter(now)) {
      await _playLive(channel);
      return;
    }
    if (!Catchup.canReplayProgramme(channel, resolved)) {
      if (mounted) {
        setState(
          () => _status =
              'Archivio non disponibile per ${resolved.title.trim().isEmpty ? 'questo programma' : resolved.title}.',
        );
      }
      return;
    }
    final catchupUrls = <String>[];
    void addCatchupUrls(XtreamProfile candidate) {
      for (final url in XtreamClient(
        candidate,
      ).catchupUrls(channel, resolved)) {
        if (!catchupUrls.contains(url)) catchupUrls.add(url);
      }
    }

    addCatchupUrls(profile);
    addCatchupUrls(
      profile.copyWith(
        liveContainer: profile.liveContainer == 'ts' ? 'm3u8' : 'ts',
      ),
    );
    _sortCatchupUrlsForPlatform(catchupUrls);
    if (catchupUrls.isEmpty) {
      if (mounted) {
        setState(() {
          _status = 'Archivio non disponibile per ${resolved.title}.';
        });
      }
      return;
    }
    // ignore: avoid_print
    print('[leleg:catchup] ${catchupUrls.length} urls for ${resolved.title}');
    for (final url in catchupUrls) {
      // ignore: avoid_print
      print('[leleg:catchup] candidate $url');
    }
    if (mounted) {
      setState(() {
        _selectedLiveChannel = channel;
        _livePlayerActive = true;
        _playerTitle = '${channel.name} - ${resolved.title}';
        _status =
            'Apertura archivio: ${resolved.title} (${catchupUrls.length} sorgenti)';
      });
    }
    unawaited(_recordRecentLiveChannel(channel.id));
    var opened = false;
    for (final catchupUrl in catchupUrls) {
      // ignore: avoid_print
      print('[leleg:catchup] try $catchupUrl');
      if (playbackId != _livePlaybackGeneration) return;
      opened = await _openMedia(
        catchupUrl,
        '${channel.name} - ${resolved.title}',
        validatePlayback: !isTizenRuntime,
        validationTimeout: const Duration(seconds: 9),
        autoValidateLivePlayback: false,
      );
      if (opened) break;
    }
    if (playbackId != _livePlaybackGeneration) return;
    if (opened) {
      _enterLivePlaybackFullscreen();
      if (mounted) {
        setState(() => _status = 'Archivio in riproduzione: ${resolved.title}');
      }
    } else if (mounted) {
      setState(() {
        _status =
            'Archivio non riproducibile: ${resolved.title}. Prova un altro programma o canale.';
      });
    }
  }

  void _sortCatchupUrlsForPlatform(List<String> urls) {
    int score(String url) {
      final lower = url.toLowerCase();
      final isM3u8 = RegExp(r'\.m3u8(?:[?#]|$)').hasMatch(lower);
      final isTs = RegExp(r'\.ts(?:[?#]|$)').hasMatch(lower);
      if (Platform.isIOS) {
        if (isM3u8) return 0;
        if (!isTs) return 1;
        return 2;
      }
      if (isTs) return 0;
      if (!isM3u8) return 1;
      return 2;
    }

    urls.sort((a, b) {
      final byScore = score(a).compareTo(score(b));
      if (byScore != 0) return byScore;
      return a.length.compareTo(b.length);
    });
  }

  Future<void> _openLiveProgrammeFromGuide(
    LiveChannel channel,
    EpgProgramme programme,
  ) async {
    final resolved = _resolveGuideProgramme(channel, programme);
    final programmes = _epgGuideProgrammes(channel);
    final programmeIndex = programmes.indexWhere(
      (item) =>
          item.start == resolved.start &&
          item.title.trim() == resolved.title.trim(),
    );
    final switchingSection = _section != AppSection.live;
    if (switchingSection) {
      setState(() {
        _section = AppSection.live;
        _remoteSection = AppSection.live;
        _selectedLiveChannel = channel;
        _selectedLiveEpg = _epgByChannel[channel.id] ?? const [];
        if (programmeIndex >= 0) _epgProgrammeIndex = programmeIndex;
      });
      await _waitForPlayerSurfaceAttach();
    } else {
      setState(() {
        _selectedLiveChannel = channel;
        _selectedLiveEpg = _epgByChannel[channel.id] ?? const [];
        if (programmeIndex >= 0) _epgProgrammeIndex = programmeIndex;
      });
    }
    if (!mounted) return;
    await _playProgramme(channel, resolved);
  }

  Future<void> _playMovie(VodMovie movie, {bool fromStart = false}) async {
    final profile = _profile;
    if (profile == null) return;
    setState(() => _livePlayerActive = false);
    final progress = fromStart ? null : _movieProgress[movie.id];
    final startAt = progress?.canResume == true
        ? Duration(milliseconds: progress!.positionMs)
        : null;
    _beginPlaybackTracking(movieId: movie.id);
    unawaited(_setLastVodMovie(movie.id));
    final originalUrl = XtreamClient(profile).vodUrl(movie);
    final opened = await _openVodMedia(
      Platform.isWindows ? _vodPlayUrls(profile, movie) : <String>[originalUrl],
      movie.name,
      startAt: startAt,
    );
    if (opened) {
      _enterMobilePlaybackFullscreen();
      unawaited(_recordRecentMovie(movie.id));
    } else {
      await _endPlaybackTracking();
    }
    if (!opened && mounted) {
      setState(() => _status = 'Riproduzione film non riuscita: ${movie.name}');
    }
  }

  Future<void> _downloadMovie(VodMovie movie, {String? urlOverride}) async {
    final profile = _profile;
    if (profile == null) return;
    _traceTv('download tap movieId=${movie.id} title="${movie.name}"');
    if (_downloads[movie.id]?.status == DownloadStatus.downloading) {
      _traceTv('download skipped already-running movieId=${movie.id}');
      setState(() {
        _section = AppSection.downloads;
        _remoteSection = AppSection.downloads;
        _remoteMenuMode = false;
        _status = 'Download gia in corso: ${movie.name}';
      });
      _closeCompactDrawerIfNeeded();
      return;
    }
    final url = urlOverride ?? XtreamClient(profile).vodUrl(movie);
    final extension = movie.containerExtension.trim().isEmpty
        ? 'mp4'
        : movie.containerExtension.trim().replaceAll('.', '');
    final directory = await _downloadBaseDirectory();
    final filename = '${_safeFileName(movie.name)}.$extension';
    final file = File('${directory.path}/$filename');
    _traceTv(
      'download prepared movieId=${movie.id} url="$url" file="${file.path}"',
    );
    setState(() {
      _downloads[movie.id] = DownloadTask(
        movie: movie,
        status: DownloadStatus.downloading,
        progress: 0,
        filePath: file.path,
      );
      _section = AppSection.downloads;
      _remoteSection = AppSection.downloads;
      _remoteMenuMode = false;
      _selectedMovie = null;
      _selectedMovieDescription = '';
      _selectedMovieGenre = '';
      _status = 'Download avviato: ${movie.name}';
    });
    _closeCompactDrawerIfNeeded();
    try {
      if (Platform.isAndroid) {
        final enqueued = await _enqueueNativeAndroidDownload(
          url: url,
          filename: filename,
          referer: '${profile.baseUrl}/',
        );
        if (!mounted) return;
        setState(() {
          final current = _downloads[movie.id];
          if (current != null) {
            _downloads[movie.id] = current.copyWith(
              status: DownloadStatus.downloading,
              filePath: enqueued ?? file.path,
            );
          }
          _status = 'Download affidato al sistema: ${movie.name}';
        });
        _traceTv(
          'download delegated android movieId=${movie.id} file="${enqueued ?? file.path}"',
        );
        return;
      }
      if (Platform.isIOS) {
        Object? lastError;
        for (final candidate in _downloadUrlCandidates(url)) {
          try {
            _traceTv(
              'download native ios candidate movieId=${movie.id} url="$candidate"',
            );
            final savedPath = await _downloadNativeIosFile(
              url: candidate,
              filename: filename,
              referer: '${profile.baseUrl}/',
              movieId: movie.id,
            );
            if (!mounted) return;
            setState(() {
              final current = _downloads[movie.id];
              if (current != null) {
                _downloads[movie.id] = current.copyWith(
                  status: DownloadStatus.completed,
                  progress: 1,
                  filePath: savedPath ?? file.path,
                );
              }
              _status = 'Download completato: ${movie.name}';
            });
            _traceTv(
              'download native ios completed movieId=${movie.id} file="${savedPath ?? file.path}"',
            );
            return;
          } catch (error) {
            lastError = error;
            _traceTv(
              'download native ios candidate failed movieId=${movie.id} url="$candidate" error="$error"',
            );
          }
        }
        throw lastError ?? Exception('Download iOS non riuscito');
      }
      await directory.create(recursive: true);
      _traceTv('download directory ready path="${directory.path}"');
      Object? lastError;
      for (final candidate in _downloadUrlCandidates(url)) {
        try {
          _traceTv('download candidate movieId=${movie.id} url="$candidate"');
          await _downloadUrlToFile(
            url: candidate,
            file: file,
            profile: profile,
            movie: movie,
          );
          _traceTv(
            'download candidate ok movieId=${movie.id} url="$candidate"',
          );
          lastError = null;
          break;
        } catch (error) {
          _traceTv(
            'download candidate failed movieId=${movie.id} url="$candidate" error="$error"',
          );
          lastError = error;
          if (await file.exists()) {
            await file.delete();
          }
        }
      }
      if (lastError != null) {
        _traceTv(
          'download failed all candidates movieId=${movie.id} error="$lastError"',
        );
        throw lastError;
      }
      await _notifyDownloadedFile(file.path);
      _traceTv('download completed movieId=${movie.id} file="${file.path}"');
      if (!mounted) return;
      setState(() {
        final current = _downloads[movie.id];
        if (current != null) {
          _downloads[movie.id] = current.copyWith(
            status: DownloadStatus.completed,
            progress: 1,
          );
        }
        _status = 'Download completato: ${movie.name}';
      });
    } catch (error) {
      _traceTv('download final failure movieId=${movie.id} error="$error"');
      if (!mounted) return;
      setState(() {
        final current = _downloads[movie.id];
        _downloads[movie
            .id] = (current ?? DownloadTask(movie: movie, filePath: file.path))
            .copyWith(status: DownloadStatus.failed, error: error.toString());
        _status = 'Download non riuscito: ${movie.name}';
      });
    }
  }

  Future<void> _downloadSeries(SeriesShow show) async {
    final profile = _profile;
    if (profile == null) return;
    setState(() => _status = 'Preparazione download: ${show.name}...');
    try {
      final detail = await XtreamClient(profile).seriesDetail(show);
      if (detail.episodes.isEmpty) {
        if (mounted) {
          setState(
            () => _status = 'Nessun episodio scaricabile per ${show.name}',
          );
        }
        return;
      }
      final episode = detail.episodes.first;
      final placeholder = VodMovie(
        id: episode.id,
        name: '${show.name} · ${episode.title}',
        logo: show.logo,
        containerExtension: episode.containerExtension,
        rating: show.rating,
        categoryId: show.categoryId,
      );
      await _downloadMovie(
        placeholder,
        urlOverride: XtreamClient(profile).episodeUrl(episode),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Download serie non riuscito: $error');
      }
    }
  }

  Future<String?> _downloadNativeIosFile({
    required String url,
    required String filename,
    required String referer,
    required int movieId,
  }) async {
    try {
      return await _storageChannel.invokeMethod<String>('downloadFile', {
        'url': url,
        'filename': filename,
        'referer': referer,
        'userAgent': 'VLC/3.0.20 LibVLC/3.0.20',
        'movieId': movieId,
      });
    } catch (error) {
      _traceTv('download native ios failed error="$error"');
      rethrow;
    }
  }

  Future<String?> _enqueueNativeAndroidDownload({
    required String url,
    required String filename,
    required String referer,
  }) async {
    try {
      return await _storageChannel.invokeMethod<String>('enqueueDownload', {
        'url': url,
        'filename': filename,
        'referer': referer,
        'userAgent': 'VLC/3.0.20 LibVLC/3.0.20',
      });
    } catch (error) {
      _traceTv('download enqueue android failed error="$error"');
      rethrow;
    }
  }

  Future<void> _downloadUrlToFile({
    required String url,
    required File file,
    required XtreamProfile profile,
    required VodMovie movie,
  }) async {
    final client = HttpClient();
    client.badCertificateCallback = (_, _, _) => true;
    client.connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      _traceTv('download http start url="$url"');
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'VLC/3.0.20 LibVLC/3.0.20',
      );
      request.headers.set(HttpHeaders.refererHeader, '${profile.baseUrl}/');
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      final response = await request.close();
      _traceTv(
        'download http response url="$url" status=${response.statusCode} length=${response.contentLength}',
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      sink = file.openWrite();
      var received = 0;
      final total = response.contentLength;
      await for (final chunk in response) {
        received += chunk.length;
        sink.add(chunk);
        if (!mounted) continue;
        final progress = total <= 0 ? -1.0 : received / total;
        setState(() {
          final current = _downloads[movie.id];
          if (current != null) {
            _downloads[movie.id] = current.copyWith(progress: progress);
          }
        });
      }
      _traceTv('download stream complete url="$url" received=$received');
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }

  List<String> _downloadUrlCandidates(String url) {
    final candidates = <String>[url];
    final uri = Uri.tryParse(url);
    if (uri != null && uri.hasScheme) {
      if (uri.scheme == 'https') {
        candidates.add(uri.replace(scheme: 'http').toString());
      } else if (uri.scheme == 'http') {
        candidates.add(uri.replace(scheme: 'https').toString());
      }
    }
    return candidates.toSet().toList(growable: false);
  }

  Future<void> _openDownloadedFile(DownloadTask task) async {
    final path = task.filePath;
    if (path == null || path.isEmpty) return;
    _traceTv('open download requested path="$path"');
    if (Platform.isMacOS) {
      await Process.run('/usr/bin/open', [path]);
      return;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final opened = await _storageChannel.invokeMethod<bool>('openFile', {
          'path': path,
        });
        if (opened == true) {
          _traceTv('open download native ok path="$path"');
          if (!mounted) return;
          setState(() => _status = 'Aperto file locale');
          return;
        }
      } catch (_) {}
    }
    _traceTv('open download fallback path="$path"');
    if (mounted) {
      setState(() => _status = 'File salvato in: $path');
    }
  }

  Future<Directory> _downloadBaseDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final path = await _storageChannel.invokeMethod<String>(
          'downloadsDirectory',
        );
        if (path != null && path.trim().isNotEmpty) {
          return Directory(path);
        }
      } catch (_) {}
    }
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? Directory.current.path;
      return Directory('$home/Downloads/LelegIPTV');
    }
    return Directory('${Directory.systemTemp.path}/LelegIPTV-downloads');
  }

  Future<void> _notifyDownloadedFile(String path) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await _storageChannel.invokeMethod('notifyFileSaved', {'path': path});
    } catch (_) {}
  }

  void _clearSearchAndReturnHome() {
    unawaited(_exitTvSearchEditing());
    _searchController.clear();
    setState(() {
      _query = '';
      _section = AppSection.home;
      _remoteSection = AppSection.home;
      _remoteMenuMode = false;
      _remoteSearchSelected = false;
      _remoteSearchIconFocused = false;
      _tvContentIndex = 0;
      _status = 'Home';
    });
    _closeCompactDrawerIfNeeded();
  }

  void _closeCompactDrawerIfNeeded() {
    final size = MediaQuery.maybeOf(context)?.size;
    if (size == null || !_useHandheldTabletShell(size)) return;
    Navigator.of(context).maybePop();
  }

  String _safeFileName(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'video' : cleaned;
  }

  Future<void> _openMovie(VodMovie movie) async {
    final profile = _profile;
    if (_isAndroidTv) unawaited(_saveLastMovieId(movie.id));
    setState(() {
      _section = AppSection.movies;
      _selectedMovie = movie;
      _selectedMovieDescription =
          _movieDescriptionCache[movie.id] ?? _browseHeroDescription;
      _selectedMovieGenre = _movieGenreCache[movie.id] ?? '';
      _playerTitle = movie.name;
      _status = 'Dettaglio film: ${movie.name}';
    });
    if (profile == null) return;
    if (_selectedMovieDescription.trim().isNotEmpty &&
        _selectedMovieGenre.trim().isNotEmpty) {
      return;
    }
    try {
      final detail = await XtreamClient(profile).vodDetail(movie);
      _movieDescriptionCache[movie.id] = detail.description;
      _movieGenreCache[movie.id] = detail.genre;
      if (!mounted || _selectedMovie?.id != movie.id) return;
      setState(() {
        _selectedMovieDescription = detail.description;
        _selectedMovieGenre = detail.genre;
      });
    } catch (_) {
      // Keep detail page usable even when provider omits VOD metadata.
    }
  }

  Future<void> _openSeries(SeriesShow show) async {
    final profile = _profile;
    if (profile == null) return;
    if (_isAndroidTv) unawaited(_saveLastSeriesId(show.id));
    unawaited(_recordRecentSeries(show.id));
    setState(() {
      _selectedSeries = show;
      _selectedSeriesDescription =
          _seriesDescriptionCache[show.id] ?? _browseHeroDescription;
      _selectedSeriesGenre = _seriesGenreCache[show.id] ?? '';
      _seriesEpisodes = const [];
      _seriesDetailLoading = true;
      _status = 'Caricamento episodi: ${show.name}';
    });
    try {
      final detail = await XtreamClient(profile).seriesDetail(show);
      _seriesDescriptionCache[show.id] = detail.description;
      _seriesGenreCache[show.id] = detail.genre;
      if (!mounted) return;
      setState(() {
        _selectedSeriesDescription = detail.description;
        _selectedSeriesGenre = detail.genre;
        _seriesEpisodes = detail.episodes;
        _status = 'Episodi caricati: ${show.name} (${detail.episodes.length})';
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'Episodi non caricati: $error');
    } finally {
      if (mounted) setState(() => _seriesDetailLoading = false);
    }
  }

  Future<void> _playEpisode(
    SeriesEpisode episode, {
    bool fromStart = false,
  }) async {
    final profile = _profile;
    final show = _selectedSeries;
    if (profile == null) return;
    if (show != null) unawaited(_recordRecentSeries(show.id));
    setState(() => _livePlayerActive = false);
    final progress = fromStart ? null : _episodeProgress[episode.id];
    final startAt = progress?.canResume == true
        ? Duration(milliseconds: progress!.positionMs)
        : null;
    _beginPlaybackTracking(episodeId: episode.id);
    if (show != null) {
      unawaited(_setLastVodEpisode(seriesId: show.id, episodeId: episode.id));
    }
    final originalUrl = XtreamClient(profile).episodeUrl(episode);
    final opened = await _openVodMedia(
      Platform.isWindows
          ? _episodePlayUrls(profile, episode)
          : <String>[originalUrl],
      show == null ? episode.title : '${show.name} - ${episode.title}',
      startAt: startAt,
    );
    if (opened) {
      _enterMobilePlaybackFullscreen();
    } else {
      await _endPlaybackTracking();
    }
    if (!opened && mounted) {
      setState(
        () => _status = 'Riproduzione episodio non riuscita: ${episode.title}',
      );
    }
  }

  bool get _isMobileHandheld =>
      (Platform.isAndroid || Platform.isIOS) &&
      !_isAndroidTv &&
      !lelegTvShellActive &&
      !isTizenRuntime;

  bool get _shouldUsePhoneFullscreenPlayback {
    if (!mounted || !_isMobileHandheld) {
      return false;
    }
    final mediaQuery = MediaQuery.maybeOf(context);
    final shortestSide = mediaQuery?.size.shortestSide ?? 9999;
    return shortestSide < 700;
  }

  void _enterFullscreenOnPhonePlayback({bool force = false}) {
    final allow = force || _shouldUsePhoneFullscreenPlayback;
    if (!allow || _playerFocusMode) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _playerFocusMode ||
          !(force || _shouldUsePhoneFullscreenPlayback)) {
        return;
      }
      _setPlayerFocusMode(true);
    });
  }

  /// Fullscreen landscape player on phone and tablet (mobile flavor only).
  void _enterMobilePlaybackFullscreen() {
    _enterFullscreenOnPhonePlayback(force: _isMobileHandheld);
  }

  /// Live TV stays inline on tablets and enters fullscreen directly on phones.
  void _enterLivePlaybackFullscreen() {
    _enterFullscreenOnPhonePlayback();
  }

  Future<bool> _openMedia(
    String url,
    String title, {
    bool preferApple = false,
    Duration? startAt,
    bool validatePlayback = false,
    Duration validationTimeout = const Duration(seconds: 5),
    bool autoValidateLivePlayback = true,
  }) async {
    setState(() {
      _playerTitle = title;
      _status = 'Apertura: $title';
    });
    if (preferApple || _useAppleVideoBackend) {
      final opened = await _openAppleMedia(url, title, startAt: startAt);
      if (opened) return true;
      if (preferApple && !_useAppleVideoBackend) {
        return _openMediaKitMedia(
          url,
          startAt: startAt,
          validatePlayback: validatePlayback,
          validationTimeout: validationTimeout,
          autoValidateLivePlayback: autoValidateLivePlayback,
        );
      }
      return false;
    }
    if (isTizenRuntime) {
      for (final candidate in _tizenMediaCandidates(url)) {
        final opened = await _openTizenMedia(
          candidate,
          title,
          startAt: startAt,
        );
        if (opened) return true;
      }
      return false;
    }
    return _openMediaKitMedia(
      url,
      startAt: startAt,
      validatePlayback: validatePlayback,
      validationTimeout: validationTimeout,
      autoValidateLivePlayback: autoValidateLivePlayback,
    );
  }

  Future<bool> _openVodMedia(
    List<String> candidates,
    String title, {
    Duration? startAt,
  }) async {
    final uniqueCandidates = candidates.toSet().toList(growable: false);
    for (var index = 0; index < uniqueCandidates.length; index += 1) {
      _traceTv(
        'open vod title="$title" candidate=${index + 1}/${uniqueCandidates.length} '
        'url="${uniqueCandidates[index]}"',
      );
      if (mounted && uniqueCandidates.length > 1) {
        setState(() {
          _status =
              'Apertura: $title (${index + 1}/${uniqueCandidates.length})';
        });
      }
      final opened = await _openMedia(
        uniqueCandidates[index],
        title,
        startAt: startAt,
        validatePlayback: Platform.isWindows,
        validationTimeout: const Duration(seconds: 12),
        autoValidateLivePlayback: false,
      );
      if (opened) return true;
    }
    return false;
  }

  Future<bool> _openMediaKitMedia(
    String url, {
    Duration? startAt,
    bool validatePlayback = false,
    Duration validationTimeout = const Duration(seconds: 5),
    bool autoValidateLivePlayback = true,
  }) async {
    final appleController = _appleVideoController;
    _appleVideoController = null;
    if (mounted && appleController != null) setState(() {});
    try {
      await appleController?.pause();
    } catch (_) {}
    await appleController?.dispose();

    final mediaPlayer = _player;
    if (mediaPlayer == null) return false;
    try {
      if (mediaPlayer.state.playing ||
          mediaPlayer.state.playlist.medias.isNotEmpty) {
        await mediaPlayer.stop();
      }
    } catch (_) {}
    final isLive = _isLivePlaybackUrl(url);
    try {
      await mediaPlayer.open(
        Media(
          url,
          httpHeaders: _profile == null
              ? const {}
              : _mediaHttpHeaders(url, _profile),
        ),
        play: true,
      );
    } catch (_) {
      return false;
    }
    if (startAt != null && startAt.inMilliseconds > 0) {
      await mediaPlayer.seek(startAt);
    }
    final shouldValidate =
        validatePlayback ||
        (autoValidateLivePlayback &&
            isLive &&
            (Platform.isAndroid ||
                Platform.isMacOS ||
                Platform.isWindows ||
                Platform.isLinux) &&
            !isTizenRuntime);
    if (shouldValidate) {
      final hasVideo = await _waitForMediaKitVideoFrame(
        mediaPlayer,
        timeout: validatePlayback
            ? validationTimeout
            : const Duration(seconds: 5),
      );
      if (!hasVideo) {
        try {
          await mediaPlayer.stop();
        } catch (_) {}
        return false;
      }
      if (Platform.isAndroid) {
        _syncMediaKitSurfaceAfterLayoutChange();
      }
    }
    return true;
  }

  /// Live/HLS often omits [Player.state.width]/height; wait for decoded video params.
  Future<bool> _waitForMediaKitVideoFrame(
    Player player, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if ((player.state.width ?? 0) > 0 && (player.state.height ?? 0) > 0) {
      return true;
    }
    try {
      await for (final params in player.stream.videoParams.timeout(
        timeout,
        onTimeout: (sink) => sink.close(),
      )) {
        final w = params.dw ?? 0;
        final h = params.dh ?? 0;
        if (w > 0 && h > 0) return true;
      }
    } catch (_) {}
    return (player.state.width ?? 0) > 0 && (player.state.height ?? 0) > 0;
  }

  Future<bool> _openAppleMedia(
    String url,
    String title, {
    Duration? startAt,
  }) async {
    final mediaPlayer = _player;
    if (mediaPlayer != null && mediaPlayer.state.playlist.medias.isNotEmpty) {
      try {
        await mediaPlayer.stop();
      } catch (_) {}
    }
    final previous = _appleVideoController;
    _appleVideoController = null;
    if (mounted) setState(() {});
    try {
      await previous?.pause();
    } catch (_) {}
    await previous?.dispose();

    final controller = vp.VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: _profile == null
          ? const <String, String>{}
          : {
              'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
              'Referer': '${_profile!.baseUrl}/',
            },
      videoPlayerOptions: vp.VideoPlayerOptions(allowBackgroundPlayback: false),
    );
    controller.addListener(() {
      final value = controller.value;
      if (!mounted) return;
      if (value.hasError) {
        setState(() => _status = 'Player iPhone: ${value.errorDescription}');
      } else if (value.isPlaying) {
        setState(() => _status = 'In riproduzione');
      }
    });
    _appleVideoController = controller;
    setState(() => _status = 'Preparazione player iPhone: $title');
    try {
      await controller.initialize();
      var size = controller.value.size;
      for (var attempt = 0; attempt < 12; attempt += 1) {
        if (size.width > 0 && size.height > 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        size = controller.value.size;
      }
      if (size.width <= 0 || size.height <= 0) {
        throw StateError('Player Apple inizializzato senza traccia video');
      }
      if (startAt != null && startAt.inMilliseconds > 0) {
        await controller.seekTo(startAt);
      }
      await controller.play();
      if (mounted) setState(() => _status = 'In riproduzione');
      return true;
    } catch (error) {
      try {
        await controller.pause();
      } catch (_) {}
      await controller.dispose();
      if (_appleVideoController == controller) {
        _appleVideoController = null;
      }
      if (mounted) {
        setState(() => _status = 'Errore player iPhone: $error');
      }
      return false;
    }
  }

  Future<bool> _openTizenMedia(
    String url,
    String title, {
    Duration? startAt,
  }) async {
    _traceTv('open tizen media title="$title" url="$url"');
    final previous = _tizenVideoController;
    _tizenVideoController = null;
    if (mounted) setState(() {});
    await previous?.pause();
    await previous?.dispose();

    final headers = _profile == null
        ? const <String, String>{}
        : {'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20'};
    final controller = avplay.VideoPlayerController.network(
      url,
      httpHeaders: headers,
      formatHint: _tizenFormatHint(url),
    );
    controller.addListener(() {
      final value = controller.value;
      if (!mounted) return;
      if (value.isInitialized) {
        _traceTv(
          'tizen value init=true playing=${value.isPlaying} buffering=${value.isBuffering} '
          'pos=${value.position.inSeconds}s dur=${value.duration.end.inSeconds}s '
          'err=${value.errorDescription}',
        );
      }
      if (value.hasError) {
        setState(() => _status = 'Player Tizen: ${value.errorDescription}');
      } else if (value.isPlaying) {
        setState(() => _status = 'In riproduzione');
      }
    });
    _tizenVideoController = controller;
    setState(() => _status = 'Preparazione AVPlay: $title');
    try {
      await controller.initialize();
      if (startAt != null && startAt.inMilliseconds > 0) {
        await controller.seekTo(startAt);
      }
      await controller.play();
      if (mounted) setState(() => _status = 'In riproduzione');
      return true;
    } catch (error) {
      if (mounted) setState(() => _status = 'Errore AVPlay: $error');
      return false;
    }
  }

  List<String> _tizenMediaCandidates(String url) {
    final candidates = <String>[url];
    final uri = Uri.tryParse(url);
    if (uri != null && uri.hasScheme) {
      if (uri.scheme == 'https') {
        candidates.add(uri.replace(scheme: 'http').toString());
      } else if (uri.scheme == 'http') {
        candidates.add(uri.replace(scheme: 'https').toString());
      }
    }
    return candidates.toSet().toList(growable: false);
  }

  avplay_platform.VideoFormat? _tizenFormatHint(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (path.endsWith('.m3u8')) return avplay_platform.VideoFormat.hls;
    if (path.endsWith('.mpd')) return avplay_platform.VideoFormat.dash;
    if (path.endsWith('.mp4') ||
        path.endsWith('.mkv') ||
        path.endsWith('.ts') ||
        path.endsWith('.avi') ||
        path.endsWith('.mov') ||
        path.endsWith('.m4v')) {
      return avplay_platform.VideoFormat.other;
    }
    return null;
  }

  Future<void> _loadChannelEpg(LiveChannel channel) async {
    final profile = _profile;
    if (profile == null) return;
    final channelId = channel.id;
    final previous = _epgByChannel[channelId] ?? const <EpgProgramme>[];
    _epgLoadingChannelId = channelId;
    if (mounted) {
      setState(() => _epgLoading = true);
    }
    try {
      final client = XtreamClient(profile);
      var epg = List<EpgProgramme>.from(previous);
      Object? epgError;
      try {
        epg = _mergeProgrammes(epg, await client.simpleEpg(channel));
      } catch (error) {
        epgError = error;
      }
      try {
        epg = _mergeProgrammes(epg, await client.shortEpg(channel, limit: 500));
      } catch (error) {
        epgError ??= error;
      }
      try {
        final xmltv = await client.xmlTvEpgForChannels(
          [channel],
          limit: 240,
          lookbackDays: _guideDefaultLookbackDays,
        );
        final xmltvEpg = xmltv[channelId] ?? const <EpgProgramme>[];
        if (xmltvEpg.isNotEmpty) {
          epg = _mergeProgrammes(epg, xmltvEpg);
        }
      } catch (_) {
        // Keep provider/API results when XMLTV is unavailable.
      }
      if (!mounted || _epgLoadingChannelId != channelId) return;
      final guideItems = _guideProgrammesFrom(channel, epg);
      setState(() {
        if (_selectedLiveChannel?.id == channelId) {
          _selectedLiveEpg = epg;
        }
        _epgByChannel[channelId] = epg;
        if (_selectedLiveChannel?.id == channelId) {
          _epgProgrammeIndex = _defaultProgrammeIndex(guideItems);
        }
        if (epg.isEmpty && epgError != null) {
          _status = 'EPG non caricato: $epgError';
        }
      });
    } catch (error) {
      if (mounted && _epgLoadingChannelId == channelId) {
        setState(() => _status = 'EPG non caricato: $error');
      }
    } finally {
      if (mounted && _epgLoadingChannelId == channelId) {
        setState(() => _epgLoading = false);
      }
    }
  }

  Future<void> _loadEpgPage({bool force = false}) async {
    final profile = _profile;
    if (profile == null || _liveChannels.isEmpty) return;
    final loadId = ++_epgLoadGeneration;
    setState(() {
      _epgLoading = true;
      _status = 'Caricamento guida TV...';
    });
    final client = XtreamClient(profile);
    final channels = _epgChannels.take(80).toList();
    if (channels.isEmpty) {
      if (!mounted || loadId != _epgLoadGeneration) return;
      setState(() {
        _epgLoading = false;
        _status = 'Guida TV: nessun canale per la categoria selezionata.';
      });
      return;
    }
    if (force) {
      for (final channel in channels) {
        _epgByChannel.remove(channel.id);
      }
    }
    var xmlTvMappedChannels = 0;
    var xmlTvProgrammesCount = 0;
    Object? xmlTvError;
    if (!mounted || loadId != _epgLoadGeneration) return;
    setState(() => _status = 'Guida TV: caricamento XMLTV...');
    try {
      final xmlTvProgrammes = await client.xmlTvEpgForChannels(
        channels,
        limit: 240,
        lookbackDays: _guideDefaultLookbackDays,
      );
      if (!mounted || loadId != _epgLoadGeneration) return;
      xmlTvMappedChannels = xmlTvProgrammes.length;
      xmlTvProgrammesCount = xmlTvProgrammes.values.fold<int>(
        0,
        (count, programmes) => count + programmes.length,
      );
      setState(() {
        for (final entry in xmlTvProgrammes.entries) {
          final existing = _epgByChannel[entry.key] ?? const <EpgProgramme>[];
          _epgByChannel[entry.key] = _mergeProgrammes(existing, entry.value);
        }
        _status =
            'XMLTV: $xmlTvMappedChannels/${channels.length} canali, '
            '$xmlTvProgrammesCount programmi';
      });
    } catch (error) {
      xmlTvError = error;
      if (!mounted || loadId != _epgLoadGeneration) return;
      setState(() => _status = 'XMLTV non caricato: $error');
    }

    final needsAttention = channels.where((channel) {
      final programmes = _epgByChannel[channel.id] ?? const [];
      return programmes.isEmpty || _epgCoverageIsShallow(programmes);
    }).toList();
    if (needsAttention.isNotEmpty) {
      var loaded = channels.length - needsAttention.length;
      var fallbackLoaded = 0;
      var fallback429Count = 0;
      for (final channel in needsAttention.take(24)) {
        if (!mounted || loadId != _epgLoadGeneration) return;
        try {
          var programmes = await client.simpleEpg(channel);
          if (programmes.isEmpty) {
            programmes = await client.shortEpg(channel, limit: 500);
          }
          if (!mounted || loadId != _epgLoadGeneration) return;
          setState(() {
            if (programmes.isNotEmpty) {
              final existing =
                  _epgByChannel[channel.id] ?? const <EpgProgramme>[];
              _epgByChannel[channel.id] = _mergeProgrammes(
                existing,
                programmes,
              );
              fallbackLoaded += 1;
            }
            loaded += 1;
            _status =
                'Guida TV fallback: $loaded/${channels.length} canali '
                '($fallbackLoaded da API provider)';
          });
        } catch (error) {
          if (!mounted || loadId != _epgLoadGeneration) return;
          if (error.toString().contains('HTTP 429')) {
            fallback429Count += 1;
          }
          setState(() {
            _status =
                'Guida TV fallback limitato'
                '${fallback429Count > 0 ? ' ($fallback429Count rate limit)' : ''}: $error';
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    if (mounted && loadId == _epgLoadGeneration) {
      final programmeCount = channels.fold<int>(
        0,
        (count, channel) => count + (_epgByChannel[channel.id]?.length ?? 0),
      );
      setState(() {
        _epgLoading = false;
        if (programmeCount > 0) {
          _status = 'Guida TV caricata ($programmeCount programmi)';
        } else if (xmlTvError != null) {
          _status = 'XMLTV non caricato: $xmlTvError';
        } else {
          _status =
              'XMLTV caricato, ma nessun programma futuro mappato '
              '($xmlTvMappedChannels/${channels.length} canali).';
        }
      });
    }
  }

  List<EpgProgramme> _mergeProgrammes(
    List<EpgProgramme> primary,
    List<EpgProgramme> secondary,
  ) {
    final byKey = <String, EpgProgramme>{};
    for (final programme in _cleanEpgProgrammes([...primary, ...secondary])) {
      final startMs = programme.start?.millisecondsSinceEpoch ?? 0;
      final title = programme.title.trim().toLowerCase();
      final key = '$startMs|$title';
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = programme;
        continue;
      }
      byKey[key] = EpgProgramme(
        title: programme.title.trim().isNotEmpty
            ? programme.title
            : existing.title,
        description: programme.description.length >= existing.description.length
            ? programme.description
            : existing.description,
        start: existing.start ?? programme.start,
        end: programme.end ?? existing.end,
      );
    }
    final merged = byKey.values.toList()
      ..sort((a, b) {
        final aStart = a.start;
        final bStart = b.start;
        if (aStart == null && bStart == null) return 0;
        if (aStart == null) return 1;
        if (bStart == null) return -1;
        return aStart.compareTo(bStart);
      });
    return merged;
  }

  Future<void> _selectAudioTrack(AudioTrack track) async {
    await _player?.setAudioTrack(track);
    if (mounted) setState(() => _status = 'Audio: ${_trackLabel(track)}');
  }

  Future<void> _selectSubtitleTrack(SubtitleTrack track) async {
    await _player?.setSubtitleTrack(track);
    if (mounted) setState(() => _status = 'Sottotitoli: ${_trackLabel(track)}');
  }

  Future<void> _seekFullscreenRelative(Duration delta) async {
    final mediaPlayer = _player;
    if (mediaPlayer == null) return;
    final duration = mediaPlayer.state.duration;
    final current = mediaPlayer.state.position;
    final next = current + delta;
    final clamped = duration > Duration.zero
        ? Duration(
            milliseconds: next.inMilliseconds.clamp(0, duration.inMilliseconds),
          )
        : (next.isNegative ? Duration.zero : next);
    await mediaPlayer.seek(clamped);
    if (mounted) {
      setState(() => _status = 'Posizione: ${_formatPlayerDuration(clamped)}');
    }
  }

  Future<void> _cycleFullscreenAudioTrack(int delta) async {
    final mediaPlayer = _player;
    if (mediaPlayer == null) return;
    final values = <AudioTrack>[
      AudioTrack.auto(),
      AudioTrack.no(),
      ...mediaPlayer.state.tracks.audio,
    ];
    if (values.isEmpty) return;
    final currentLabel = _trackLabel(mediaPlayer.state.track.audio);
    final currentIndex = values.indexWhere(
      (track) => _trackLabel(track) == currentLabel,
    );
    final base = currentIndex < 0 ? 0 : currentIndex;
    final next = values[(base + delta) % values.length];
    await _selectAudioTrack(next);
  }

  Future<void> _cycleFullscreenSubtitleTrack(int delta) async {
    final mediaPlayer = _player;
    if (mediaPlayer == null) return;
    final values = <SubtitleTrack>[
      SubtitleTrack.no(),
      SubtitleTrack.auto(),
      ...mediaPlayer.state.tracks.subtitle,
    ];
    if (values.isEmpty) return;
    final currentLabel = _trackLabel(mediaPlayer.state.track.subtitle);
    final currentIndex = values.indexWhere(
      (track) => _trackLabel(track) == currentLabel,
    );
    final base = currentIndex < 0 ? 0 : currentIndex;
    final next = values[(base + delta) % values.length];
    await _selectSubtitleTrack(next);
  }

  String _formatPlayerDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  Future<void> _setRate(double value) async {
    final mediaPlayer = _player;
    if (!isTizenRuntime && mediaPlayer != null) {
      await mediaPlayer.setRate(value);
    }
    final appleController = _appleVideoController;
    if (appleController != null) {
      await appleController.setPlaybackSpeed(value);
    }
    if (!mounted) return;
    setState(() {
      _rate = value;
      _status = 'Velocita: ${value.toStringAsFixed(2)}x';
    });
  }

  void _togglePlayerFocusMode() {
    _setPlayerFocusMode(!_playerFocusMode);
  }

  void _setPlayerFocusMode(bool next) {
    if (_playerFocusMode == next) return;
    setState(() {
      _playerFocusMode = next;
      _fullscreenOverlayVisible = next;
      _vodToolbarIndex = -1;
    });
    if (next) {
      _scheduleFullscreenOverlayHide();
    } else {
      _fullscreenOverlayTimer?.cancel();
    }
    if (Platform.isAndroid || Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          _applyMobileOrientationPolicy(fullscreen: next)
              .then((_) {
                if (next && _livePlayerActive && Platform.isAndroid) {
                  _syncMediaKitSurfaceAfterLayoutChange();
                }
              })
              .catchError((error) {
                if (mounted) {
                  setState(
                    () => _status = 'Fullscreen non disponibile: $error',
                  );
                }
              }),
        );
      });
      return;
    }
    if (Platform.isMacOS || Platform.isWindows) {
      unawaited(
        windowManager.setFullScreen(next).catchError((error) {
          if (mounted) {
            setState(() => _status = 'Fullscreen non disponibile: $error');
          }
        }),
      );
    }
  }

  /// Re-binds the Android media_kit surface after fullscreen layout/orientation changes.
  void _syncMediaKitSurfaceAfterLayoutChange() {
    if (!Platform.isAndroid || _useAppleVideoBackend || _player == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final player = _player;
        if (!mounted || player == null) return;
        try {
          final position = player.state.position;
          final wasPlaying = player.state.playing;
          await player.seek(position);
          if (wasPlaying && !player.state.playing) {
            await player.play();
          }
        } catch (_) {
          // Best-effort; playback may still recover on the next surface attach.
        }
      });
    });
  }

  void _revealFullscreenOverlay({bool resetTimer = false}) {
    if (!_playerFocusMode) return;
    final wasHidden = !_fullscreenOverlayVisible;
    if (wasHidden && mounted) {
      setState(() => _fullscreenOverlayVisible = true);
      _scheduleFullscreenOverlayHide();
    } else if (resetTimer) {
      _scheduleFullscreenOverlayHide();
    }
  }

  void _scheduleFullscreenOverlayHide() {
    _fullscreenOverlayTimer?.cancel();
    if (_vodToolbarIndex >= 0) return;
    _fullscreenOverlayTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playerFocusMode && _vodToolbarIndex < 0) {
        setState(() => _fullscreenOverlayVisible = false);
      }
    });
  }

  void _setFullscreenChromeVisible(bool visible) {
    if (!_playerFocusMode || _fullscreenOverlayVisible == visible) return;
    setState(() => _fullscreenOverlayVisible = visible);
    if (visible) {
      _scheduleFullscreenOverlayHide();
    } else {
      _fullscreenOverlayTimer?.cancel();
    }
  }

  Future<void> _playAdjacentLiveChannel(int direction) async {
    final current = _selectedLiveChannel;
    if (current == null) return;
    final filteredIndex = _filteredLive.indexWhere(
      (item) => item.id == current.id,
    );
    final channels = filteredIndex >= 0 ? _filteredLive : _playableLiveChannels;
    if (channels.isEmpty) return;
    final currentIndex = channels.indexWhere((item) => item.id == current.id);
    final base = currentIndex < 0 ? 0 : currentIndex;
    final nextIndex = (base + direction) % channels.length;
    final next = channels[nextIndex];
    _traceTv('fullscreen channel switch ${current.name} -> ${next.name}');
    setState(() {
      _tvContentIndex = _channelIndexOf(_filteredLive, next);
      _selectedLiveChannel = next;
      _playerTitle = next.name;
    });
    await _playLive(next);
    _revealFullscreenOverlay();
  }

  Future<void> _closePlayer() async {
    final mediaPlayer = _player;
    if (mediaPlayer != null && mediaPlayer.state.playlist.medias.isNotEmpty) {
      await mediaPlayer.stop();
    }
    final appleController = _appleVideoController;
    if (appleController != null) {
      try {
        await appleController.pause();
      } catch (_) {}
    }
    final tizenController = _tizenVideoController;
    if (tizenController != null) {
      try {
        await tizenController.pause();
      } catch (_) {}
    }
    _setPlayerFocusMode(false);
    if (!mounted) return;
    setState(() {
      _playerTitle = 'Scegli qualcosa da guardare.';
      _status = 'Riproduzione chiusa';
      _livePlayerActive = false;
    });
  }

  void _showPictureInPictureUnavailable() {
    setState(
      () => _status =
          'Picture-in-Picture nativo non disponibile in questa build.',
    );
  }

  String _trackLabel(dynamic track) {
    final title = track.title?.toString();
    final language = track.language?.toString();
    final id = track.id?.toString();
    final parts = [
      if (title != null && title.isNotEmpty) title,
      if (language != null && language.isNotEmpty) language,
      if (id != null && id.isNotEmpty) '#$id',
    ];
    return parts.isEmpty ? 'Auto' : parts.join(' - ');
  }

  List<LiveChannel> get _filteredLive {
    final q = _query.trim().toLowerCase();
    final activeCategoryId = _validLiveCategoryId;
    final byCategory = activeCategoryId.isEmpty
        ? _playableLiveChannels
        : _liveChannels
              .where(
                (item) =>
                    _isPlayableLiveChannel(item) &&
                    item.categoryId == activeCategoryId,
              )
              .toList();
    final source = q.isEmpty
        ? byCategory
        : byCategory
              .where((item) => item.name.toLowerCase().contains(q))
              .toList();
    return source.take(350).toList();
  }

  List<LiveChannel> get _epgChannels {
    final activeCategoryId = _validLiveCategoryId;
    final byCategory = activeCategoryId.isEmpty
        ? _playableLiveChannels
        : _liveChannels
              .where(
                (item) =>
                    _isPlayableLiveChannel(item) &&
                    item.categoryId == activeCategoryId,
              )
              .toList();
    return byCategory;
  }

  List<LiveChannel> get _playableLiveChannels =>
      _liveChannels.where(_isPlayableLiveChannel).toList();

  bool _isPlayableLiveChannel(LiveChannel channel) {
    final name = channel.name.trim();
    if (channel.id <= 0) return false;
    if (RegExp(r'^[-\s]+[^-\s].*[-\s]+$').hasMatch(name)) return false;
    if (RegExp(r'^[-_=]{3,}.*[-_=]{3,}$').hasMatch(name)) return false;
    return true;
  }

  String get _validLiveCategoryId {
    if (_liveCategoryId.isEmpty) return '';
    final exists = _liveCategories.any((item) => item.id == _liveCategoryId);
    return exists ? _liveCategoryId : '';
  }

  List<VodMovie> get _filteredMovies {
    final q = _query.trim().toLowerCase();
    final byCategory = _movieCategoryId.isEmpty
        ? _movies
        : _movies.where((item) => item.categoryId == _movieCategoryId).toList();
    final source = q.isEmpty
        ? byCategory
        : byCategory
              .where((item) => item.name.toLowerCase().contains(q))
              .toList();
    return _sortMovies(source, _movieSort);
  }

  List<VodMovie> get _favoriteMovies =>
      _movies.where((movie) => _favoriteMovieIds.contains(movie.id)).toList();

  List<VodMovie> get _watchLaterMovies =>
      _movies.where((movie) => _watchLaterMovieIds.contains(movie.id)).toList();

  List<SeriesShow> get _filteredSeries {
    final q = _query.trim().toLowerCase();
    final byCategory = _seriesCategoryId.isEmpty
        ? _series
        : _series
              .where((item) => item.categoryId == _seriesCategoryId)
              .toList();
    final source = q.isEmpty
        ? byCategory
        : byCategory
              .where((item) => item.name.toLowerCase().contains(q))
              .toList();
    return _sortSeries(source, _seriesSort);
  }

  List<VodMovie> _sortMovies(List<VodMovie> movies, String sort) {
    final copy = [...movies];
    if (sort == 'az') {
      copy.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else if (sort == 'rating') {
      copy.sort(
        (a, b) => _catalogRating(b.rating).compareTo(_catalogRating(a.rating)),
      );
    } else if (sort == 'recommended') {
      final favorites = movies
          .where((movie) => _favoriteMovieIds.contains(movie.id))
          .toList();
      copy.sort(
        (a, b) => _movieRecommendationScore(
          b,
          favorites,
        ).compareTo(_movieRecommendationScore(a, favorites)),
      );
    } else {
      copy.sort((a, b) => b.id.compareTo(a.id));
    }
    return copy;
  }

  List<SeriesShow> _sortSeries(List<SeriesShow> shows, String sort) {
    final copy = [...shows];
    if (sort == 'az') {
      copy.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } else if (sort == 'rating') {
      copy.sort(
        (a, b) => _catalogRating(b.rating).compareTo(_catalogRating(a.rating)),
      );
    } else if (sort == 'recommended') {
      final favorites = shows
          .where((show) => _favoriteSeriesIds.contains(show.id))
          .toList();
      copy.sort(
        (a, b) => _seriesRecommendationScore(
          b,
          favorites,
        ).compareTo(_seriesRecommendationScore(a, favorites)),
      );
    } else {
      copy.sort((a, b) => b.id.compareTo(a.id));
    }
    return copy;
  }

  double _catalogRating(String value) =>
      double.tryParse(value.replaceAll(',', '.')) ?? 0;

  Set<String> _catalogWords(String value) => value
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9à-ÿ]+'))
      .where((word) => word.length >= 3)
      .toSet();

  double _movieRecommendationScore(VodMovie movie, List<VodMovie> favorites) {
    if (favorites.isEmpty) return movie.id.toDouble();
    var score = _catalogRating(movie.rating) * 0.1;
    final words = _catalogWords(
      '${movie.name} ${_movieGenreCache[movie.id] ?? ''}',
    );
    for (final favorite in favorites) {
      if (favorite.categoryId == movie.categoryId) score += 6;
      final favoriteWords = _catalogWords(
        '${favorite.name} ${_movieGenreCache[favorite.id] ?? ''}',
      );
      score += words.intersection(favoriteWords).length * 2;
    }
    if (_favoriteMovieIds.contains(movie.id)) score -= 1000;
    return score;
  }

  double _seriesRecommendationScore(
    SeriesShow show,
    List<SeriesShow> favorites,
  ) {
    if (favorites.isEmpty) return show.id.toDouble();
    var score = _catalogRating(show.rating) * 0.1;
    final words = _catalogWords(
      '${show.name} ${_seriesGenreCache[show.id] ?? ''}',
    );
    for (final favorite in favorites) {
      if (favorite.categoryId == show.categoryId) score += 6;
      final favoriteWords = _catalogWords(
        '${favorite.name} ${_seriesGenreCache[favorite.id] ?? ''}',
      );
      score += words.intersection(favoriteWords).length * 2;
    }
    if (_favoriteSeriesIds.contains(show.id)) score -= 1000;
    return score;
  }

  String _categoryName(List<XtreamCategory> categories, String id) {
    if (id.isEmpty) return 'Tutte le categorie';
    for (final category in categories) {
      if (category.id == id) return category.name;
    }
    return 'Categoria $id';
  }

  Map<String, int> _liveCategoryCounts() {
    final counts = <String, int>{'': _playableLiveChannels.length};
    for (final channel in _playableLiveChannels) {
      counts[channel.categoryId] = (counts[channel.categoryId] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, int> _movieCategoryCounts() {
    final counts = <String, int>{'': _movies.length};
    for (final movie in _movies) {
      counts[movie.categoryId] = (counts[movie.categoryId] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, int> _seriesCategoryCounts() {
    final counts = <String, int>{'': _series.length};
    for (final show in _series) {
      counts[show.categoryId] = (counts[show.categoryId] ?? 0) + 1;
    }
    return counts;
  }

  String _categoryNameWithCount(
    List<XtreamCategory> categories,
    String id,
    Map<String, int> counts,
  ) {
    final name = _categoryName(categories, id);
    final count = counts[id];
    return count == null ? name : '$name ($count)';
  }

  Widget _tvPopScope(Widget child) {
    if (!_isAndroidTv) return child;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleAndroidBack();
      },
      child: child,
    );
  }

  static const _phonePrimarySections = <AppSection>[
    AppSection.home,
    AppSection.live,
    AppSection.movies,
    AppSection.series,
  ];

  int _phoneNavSelectedIndex() {
    final primary = _phonePrimarySections.indexOf(_section);
    if (primary >= 0) return primary;
    return 4;
  }

  Future<void> _showPhoneMoreMenu() async {
    final section = await showModalBottomSheet<AppSection>(
      context: context,
      backgroundColor: LelegColors.surface,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PhoneMoreTile(
              icon: Icons.star_border,
              label: 'Preferiti',
              section: AppSection.favorites,
              current: _section,
            ),
            _PhoneMoreTile(
              icon: Icons.bookmark_border,
              label: 'Da vedere',
              section: AppSection.watchLater,
              current: _section,
            ),
            _PhoneMoreTile(
              icon: Icons.auto_awesome,
              label: 'Aggiunti di recente',
              section: AppSection.recentlyAdded,
              current: _section,
            ),
            _PhoneMoreTile(
              icon: Icons.calendar_month_outlined,
              label: 'Guida TV',
              section: AppSection.epg,
              current: _section,
            ),
            if (!_isAndroidTv)
              _PhoneMoreTile(
                icon: Icons.download_outlined,
                label: 'Download',
                section: AppSection.downloads,
                current: _section,
              ),
            const Divider(height: 1, color: LelegColors.line),
            _PhoneMoreTile(
              icon: Icons.settings_outlined,
              label: 'Impostazioni',
              section: AppSection.settings,
              current: _section,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || section == null) return;
    await _changeSection(section);
  }

  Future<void> _showPhoneSearchSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: LelegColors.surface,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            16 + MediaQuery.paddingOf(context).bottom,
          ),
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              labelText: 'Cerca canali, film e serie',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => _query = value),
            onSubmitted: (value) {
              setState(() => _query = value);
              Navigator.of(context).pop();
              if (value.trim().isNotEmpty && _section != AppSection.home) {
                unawaited(_changeSection(AppSection.home));
              }
            },
          ),
        );
      },
    );
  }

  Widget _buildHandheldPhoneShell() {
    final navIndex = _phoneNavSelectedIndex();
    return Scaffold(
      backgroundColor: LelegColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: const BoxDecoration(
                color: LelegColors.sidebar,
                border: Border(bottom: BorderSide(color: LelegColors.line)),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _sectionLabel(_section),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cerca',
                    onPressed: _showPhoneSearchSheet,
                    icon: const Icon(Icons.search),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FocusTraversalGroup(
                policy: ReadingOrderTraversalPolicy(),
                child: FocusScope(
                  node: _contentFocusScopeNode,
                  descendantsAreFocusable: _contentDescendantsAreFocusable,
                  child: _buildSection(),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: LelegColors.sidebar,
        indicatorColor: LelegColors.accent.withValues(alpha: 0.22),
        selectedIndex: navIndex,
        onDestinationSelected: (index) {
          if (index == 4) {
            unawaited(_showPhoneMoreMenu());
            return;
          }
          unawaited(_changeSection(_phonePrimarySections[index]));
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.live_tv_outlined),
            selectedIcon: Icon(Icons.live_tv),
            label: 'Live',
          ),
          NavigationDestination(
            icon: Icon(Icons.movie_outlined),
            selectedIcon: Icon(Icons.movie),
            label: 'Film',
          ),
          NavigationDestination(
            icon: Icon(Icons.layers_outlined),
            selectedIcon: Icon(Icons.layers),
            label: 'Serie',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz),
            selectedIcon: Icon(Icons.more_horiz),
            label: 'Altro',
          ),
        ],
      ),
    );
  }

  Widget _buildHandheldTabletShell() {
    return Scaffold(
      backgroundColor: LelegColors.bg,
      drawer: Drawer(
        backgroundColor: LelegColors.sidebar,
        child: SafeArea(
          child: LelegSidebar(
            compact: true,
            showDownloads: !_isAndroidTv,
            searchFocusNode: _searchFocusNode,
            remoteSearchSelected: _remoteSearchSelected,
            section: _section,
            remoteSection: _remoteMenuMode ? _remoteSection : null,
            queryController: _searchController,
            accountInfo: _accountInfo,
            profile: _profile,
            status: _status,
            loading: _loading || _epgLoading || _seriesDetailLoading,
            onQueryChanged: (value) => setState(() => _query = value),
            onResetSearch: _clearSearchAndReturnHome,
            onSectionChanged: (section) {
              Navigator.of(context).maybePop();
              unawaited(_changeSection(section));
            },
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Builder(
              builder: (context) => Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: const BoxDecoration(
                  color: LelegColors.sidebar,
                  border: Border(bottom: BorderSide(color: LelegColors.line)),
                ),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Scaffold.of(context).openDrawer(),
                      icon: const Icon(Icons.menu),
                      tooltip: 'Menu',
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _sectionLabel(_section),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Cerca',
                      onPressed: _showPhoneSearchSheet,
                      icon: const Icon(Icons.search),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: FocusTraversalGroup(
                policy: ReadingOrderTraversalPolicy(),
                child: FocusScope(
                  node: _contentFocusScopeNode,
                  descendantsAreFocusable: _contentDescendantsAreFocusable,
                  child: _buildSection(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final phoneShell =
        !_isAndroidTv && !lelegTvShellActive && _useHandheldPhoneShell(size);
    final tabletShell =
        !_isAndroidTv && !lelegTvShellActive && _useHandheldTabletShell(size);
    if (_playerFocusMode) {
      return _tvPopScope(
        Focus(
          focusNode: _shellFocusNode,
          autofocus: true,
          onKeyEvent: (_, event) => _handleShellKey(event),
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: PlayerCard(
                    title: _playerTitle,
                    controller: _videoController,
                    player: _player,
                    appleController: _appleVideoController,
                    tizenController: _tizenVideoController,
                    rate: _rate,
                    labelFor: _trackLabel,
                    onAudioChanged: _selectAudioTrack,
                    onSubtitleChanged: _selectSubtitleTrack,
                    onRateChanged: _setRate,
                    focusMode: true,
                    pinControlsOnFocus: _isAndroidTv,
                    onControlsVisibilityChanged: _isAndroidTv
                        ? null
                        : _setFullscreenChromeVisible,
                    onToggleFocusMode: _togglePlayerFocusMode,
                    onPictureInPicture: _showPictureInPictureUnavailable,
                  ),
                ),
                SafeArea(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_isAndroidTv && !_livePlayerActive)
                        Positioned(
                          left: 24,
                          right: 24,
                          bottom: 24,
                          child: AnimatedOpacity(
                            opacity:
                                (_fullscreenOverlayVisible ||
                                    _vodToolbarIndex >= 0)
                                ? 1
                                : 0,
                            duration: const Duration(milliseconds: 180),
                            child: IgnorePointer(
                              ignoring:
                                  !(_fullscreenOverlayVisible ||
                                      _vodToolbarIndex >= 0),
                              child: _TvVodToolbar(
                                focusIndex: _vodToolbarIndex,
                                playing: _player?.state.playing ?? false,
                                audioLabel: _player == null
                                    ? 'Auto'
                                    : _trackLabel(_player!.state.track.audio),
                                subtitleLabel: _player == null
                                    ? 'Off'
                                    : _trackLabel(
                                        _player!.state.track.subtitle,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      if (_livePlayerActive && _isAndroidTv)
                        Positioned(
                          left: 32,
                          right: 32,
                          bottom: 32,
                          child: AnimatedOpacity(
                            opacity: _fullscreenOverlayVisible ? 1 : 0,
                            duration: const Duration(milliseconds: 180),
                            child: IgnorePointer(
                              ignoring: !_fullscreenOverlayVisible,
                              child: _FullscreenLiveOverlay(
                                channel: _selectedLiveChannel,
                                programmes: _selectedLiveEpg,
                                loading: _epgLoading,
                                selectedIndex: _epgProgrammeIndex,
                                onPreviousChannel: () =>
                                    unawaited(_playAdjacentLiveChannel(-1)),
                                onNextChannel: () =>
                                    unawaited(_playAdjacentLiveChannel(1)),
                                onWatchProgramme: _playProgramme,
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 20,
                        right: 20,
                        child: AnimatedOpacity(
                          opacity: _fullscreenOverlayVisible ? 1 : 0,
                          duration: const Duration(milliseconds: 180),
                          child: IgnorePointer(
                            ignoring: !_fullscreenOverlayVisible,
                            child: Material(
                              color: Colors.black.withValues(alpha: 0.72),
                              shape: const CircleBorder(),
                              child: IconButton(
                                tooltip: 'Chiudi player',
                                onPressed: () => unawaited(_closePlayer()),
                                icon: const Icon(Icons.close),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return _tvPopScope(
      Focus(
        focusNode: _shellFocusNode,
        autofocus: true,
        onKeyEvent: (_, event) => _handleShellKey(event),
        child: phoneShell
            ? _buildHandheldPhoneShell()
            : tabletShell
            ? _buildHandheldTabletShell()
            : (_isAndroidTv || lelegTvShellActive)
            ? Scaffold(
                backgroundColor: LelegColors.bg,
                body: _TvUiScope(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TvTopNavigation(
                        section: _section,
                        remoteSection: _remoteMenuMode ? _remoteSection : null,
                        remoteSearchSelected: _remoteSearchSelected,
                        remoteSearchIconFocused: _remoteSearchIconFocused,
                        sections: _remoteSections,
                        sectionLabel: _sectionLabel,
                        queryController: _searchController,
                        searchFocusNode: _searchFocusNode,
                        profile: _profile,
                        status: _status,
                        loading:
                            _loading || _epgLoading || _seriesDetailLoading,
                        onQueryChanged: (value) =>
                            setState(() => _query = value),
                        onResetSearch: _clearSearchAndReturnHome,
                        onSectionChanged: (section) =>
                            unawaited(_changeSection(section)),
                        onOpenSettings: () =>
                            unawaited(_changeSection(AppSection.settings)),
                        onOpenSearch: () => unawaited(_enterTvSearchEditing()),
                      ),
                      Expanded(
                        child: FocusTraversalGroup(
                          policy: ReadingOrderTraversalPolicy(),
                          child: FocusScope(
                            node: _contentFocusScopeNode,
                            descendantsAreFocusable:
                                _contentDescendantsAreFocusable,
                            child: _buildSection(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : Scaffold(
                body: Row(
                  children: [
                    LelegSidebar(
                      showDownloads: !_isAndroidTv,
                      searchFocusNode: _searchFocusNode,
                      remoteSearchSelected: _remoteSearchSelected,
                      section: _section,
                      remoteSection: _remoteMenuMode ? _remoteSection : null,
                      queryController: _searchController,
                      accountInfo: _accountInfo,
                      profile: _profile,
                      status: _status,
                      loading: _loading || _epgLoading || _seriesDetailLoading,
                      onQueryChanged: (value) => setState(() => _query = value),
                      onResetSearch: _clearSearchAndReturnHome,
                      onSectionChanged: (section) =>
                          unawaited(_changeSection(section)),
                    ),
                    Expanded(
                      child: FocusTraversalGroup(
                        policy: ReadingOrderTraversalPolicy(),
                        child: FocusScope(
                          node: _contentFocusScopeNode,
                          descendantsAreFocusable:
                              _contentDescendantsAreFocusable,
                          child: _buildSection(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  String _movieBrowseMeta(VodMovie movie) {
    return [
      if (movie.rating.trim().isNotEmpty) movie.rating.trim(),
      _categoryName(_movieCategories, movie.categoryId),
      movie.containerExtension.toUpperCase(),
    ].where((part) => part.isNotEmpty).join(' · ');
  }

  String _seriesBrowseMeta(SeriesShow show) {
    return [
      if (show.rating.trim().isNotEmpty) show.rating.trim(),
      if (show.year.trim().isNotEmpty) show.year.trim(),
      _categoryName(_seriesCategories, show.categoryId),
    ].where((part) => part.isNotEmpty).join(' · ');
  }

  Widget _buildSection() {
    if (_query.trim().isNotEmpty && _section == AppSection.home) {
      return SearchResultsScreen(
        query: _query,
        liveChannels: _filteredLive,
        movies: _filteredMovies,
        series: _filteredSeries,
        onOpenLive: (channel) async {
          _closeCompactDrawerIfNeeded();
          await _changeSection(AppSection.live);
          await _playLive(channel);
        },
        onOpenMovie: (movie) async {
          _closeCompactDrawerIfNeeded();
          await _openMovie(movie);
        },
        onOpenSeries: (show) async {
          _closeCompactDrawerIfNeeded();
          await _changeSection(AppSection.series);
          await _openSeries(show);
        },
      );
    }
    return switch (_section) {
      AppSection.home => HomeScreen(
        tvSelectedIndex: _remoteMenuMode ? null : _tvContentIndex,
        liveCount: _liveChannels.length,
        movieCount: _movies.length,
        seriesCount: _series.length,
        loading: _loading,
        status: _status,
        recentMovies: _movies.take(12).toList(),
        favoriteMovies: _favoriteMovies.take(12).toList(),
        watchLaterMovies: _watchLaterMovies.take(12).toList(),
        recentLiveChannels: _recentLiveChannels.take(16).toList(),
        recentMovieHistory: _recentMovieHistory.take(16).toList(),
        recentSeriesHistory: _recentSeriesHistory.take(16).toList(),
        heroTarget: _buildTvHomeHeroTarget(),
        favoriteCount: _favoriteMovieIds.length,
        watchLaterCount: _watchLaterMovieIds.length,
        onOpenLive: () => unawaited(_changeSection(AppSection.live)),
        onOpenMovies: () => unawaited(_changeSection(AppSection.movies)),
        onOpenSeries: () => unawaited(_changeSection(AppSection.series)),
        onOpenFavorites: () => unawaited(_changeSection(AppSection.favorites)),
        onOpenWatchLater: () =>
            unawaited(_changeSection(AppSection.watchLater)),
        onOpenEpg: () => unawaited(_changeSection(AppSection.epg)),
        onOpenDownloads: () => unawaited(_changeSection(AppSection.downloads)),
        onOpenSettings: () => unawaited(_changeSection(AppSection.settings)),
        showDownloads: !_isAndroidTv,
        isTv: _isAndroidTv,
        onPlayMovie: _openMovie,
        onPlayLiveChannel: (channel) async {
          await _changeSection(AppSection.live);
          await _playLive(channel);
        },
        onOpenSeriesShow: (show) async {
          await _changeSection(AppSection.series);
          await _openSeries(show);
        },
      ),
      AppSection.live => LiveScreen(
        tvSelectedIndex: _remoteMenuMode ? null : _tvContentIndex,
        channels: _filteredLive,
        allCount: _liveChannels.length,
        categories: _liveCategories,
        selectedCategoryId: _liveCategoryId,
        categoryName: (id) => _categoryName(_liveCategories, id),
        categoryLabel: (id) =>
            _categoryNameWithCount(_liveCategories, id, _liveCategoryCounts()),
        playerTitle: _playerTitle,
        controller: _videoController,
        player: _player,
        appleController: _appleVideoController,
        tizenController: _tizenVideoController,
        rate: _rate,
        labelFor: _trackLabel,
        onPlay: _playLive,
        onAudioChanged: _selectAudioTrack,
        onSubtitleChanged: _selectSubtitleTrack,
        onRateChanged: _setRate,
        onCategoryChanged: _setLiveCategory,
        preferTvLayout: _isAndroidTv,
        onToggleFocusMode: _togglePlayerFocusMode,
        onPictureInPicture: _showPictureInPictureUnavailable,
        epg: _selectedLiveChannel == null
            ? const <EpgProgramme>[]
            : _contextualGuideProgrammesFrom(
                _selectedLiveChannel!,
                _selectedLiveEpg,
              ),
        epgByChannel: _epgByChannel,
        epgLoading: _epgLoading,
        liveProgrammeLoading: _liveListEpgPrefetching,
        selectedChannel: _selectedLiveChannel,
        onSelectChannel: (channel) =>
            _previewLiveChannelAt(_channelIndexOf(_filteredLive, channel)),
        onWatchProgramme: _playProgramme,
        onOpenGuide: () => _changeSection(AppSection.epg),
      ),
      AppSection.movies =>
        _selectedMovie == null
            ? (_isAndroidTv
                  ? TvFeaturedBrowseScreen<VodMovie>(
                      kindLabel: 'FILM',
                      rowTitle: _movieCategoryId.isEmpty
                          ? 'Catalogo film'
                          : _categoryName(_movieCategories, _movieCategoryId),
                      items: _filteredMovies,
                      selectedIndex: _remoteMenuMode ? null : _tvContentIndex,
                      imageUrl: (movie) => movie.logo,
                      titleFor: (movie) => movie.name,
                      metaFor: (movie) => _movieBrowseMeta(movie),
                      description: _browseHeroDescription,
                      descriptionLoading: _browseHeroLoading,
                      categories: _movieCategories,
                      selectedCategoryId: _movieCategoryId,
                      categoryName: (id) => _categoryName(_movieCategories, id),
                      categoryLabel: (id) => _categoryNameWithCount(
                        _movieCategories,
                        id,
                        _movieCategoryCounts(),
                      ),
                      onCategoryChanged: _setMovieCategory,
                      onOpen: _openMovie,
                      isFavorite: (movie) =>
                          _favoriteMovieIds.contains(movie.id),
                      onToggleFavorite: _toggleFavoriteMovie,
                      heroActionSelected: _browseHeroActionSelected,
                    )
                  : MoviesScreen(
                      tvSelectedIndex: _remoteMenuMode ? null : _tvContentIndex,
                      movies: _filteredMovies,
                      movieProgress: _movieProgress,
                      allCount: _movies.length,
                      categories: _movieCategories,
                      selectedCategoryId: _movieCategoryId,
                      sort: _movieSort,
                      categoryName: (id) => _categoryName(_movieCategories, id),
                      categoryLabel: (id) => _categoryNameWithCount(
                        _movieCategories,
                        id,
                        _movieCategoryCounts(),
                      ),
                      onCategoryChanged: _setMovieCategory,
                      onSortChanged: (sort) =>
                          setState(() => _movieSort = sort),
                      onPlay: _openMovie,
                      onFavorite: _toggleFavoriteMovie,
                      onWatchLater: _toggleWatchLaterMovie,
                      onDownload: _isAndroidTv ? null : _downloadMovie,
                      favorites: _favoriteMovieIds,
                      watchLater: _watchLaterMovieIds,
                    ))
            : MovieDetailScreen(
                movie: _selectedMovie!,
                description: _selectedMovieDescription,
                genre: _selectedMovieGenre,
                category: _categoryName(
                  _movieCategories,
                  _selectedMovie!.categoryId,
                ),
                isFavorite: _favoriteMovieIds.contains(_selectedMovie!.id),
                onToggleFavorite: () => _toggleFavoriteMovie(_selectedMovie!),
                tvActionIndex: _isAndroidTv && !_remoteMenuMode
                    ? _tvContentIndex
                    : null,
                controller: _videoController,
                player: _player,
                appleController: _appleVideoController,
                tizenController: _tizenVideoController,
                playerTitle: _playerTitle,
                rate: _rate,
                labelFor: _trackLabel,
                onBack: () {
                  setState(() => _selectedMovie = null);
                  if (_isAndroidTv) {
                    unawaited(_previewMovieAt(_tvContentIndex));
                  }
                },
                onPlay: () => _playMovie(_selectedMovie!, fromStart: true),
                onResume: () => _playMovie(_selectedMovie!),
                onRestart: () => _playMovie(_selectedMovie!, fromStart: true),
                canResume: _movieCanResume(_selectedMovie!.id),
                watchProgress: _movieProgress[_selectedMovie!.id],
                onDownload: _isAndroidTv
                    ? null
                    : () => _downloadMovie(_selectedMovie!),
                onAudioChanged: _selectAudioTrack,
                onSubtitleChanged: _selectSubtitleTrack,
                onRateChanged: _setRate,
                onToggleFocusMode: _togglePlayerFocusMode,
                onPictureInPicture: _showPictureInPictureUnavailable,
              ),
      AppSection.favorites =>
        _isAndroidTv
            ? TvFeaturedBrowseScreen<VodMovie>(
                kindLabel: 'PREFERITI',
                rowTitle: 'I tuoi preferiti',
                items: _favoriteMovies,
                selectedIndex: _remoteMenuMode ? null : _tvContentIndex,
                imageUrl: (movie) => movie.logo,
                titleFor: (movie) => movie.name,
                metaFor: (movie) => _movieBrowseMeta(movie),
                description: _browseHeroDescription,
                descriptionLoading: _browseHeroLoading,
                onOpen: _openMovie,
                isFavorite: (movie) => _favoriteMovieIds.contains(movie.id),
                onToggleFavorite: _toggleFavoriteMovie,
                heroActionSelected: _browseHeroActionSelected,
              )
            : MoviesScreen(
                tvSelectedIndex: _remoteMenuMode ? null : _tvContentIndex,
                title: 'Preferiti',
                movies: _favoriteMovies,
                movieProgress: _movieProgress,
                onPlay: _openMovie,
                onFavorite: _toggleFavoriteMovie,
                onWatchLater: _toggleWatchLaterMovie,
                onDownload: _isAndroidTv ? null : _downloadMovie,
                favorites: _favoriteMovieIds,
                watchLater: _watchLaterMovieIds,
              ),
      AppSection.watchLater => MoviesScreen(
        tvSelectedIndex: _remoteMenuMode ? null : _tvContentIndex,
        title: 'Da vedere',
        movies: _watchLaterMovies,
        movieProgress: _movieProgress,
        onPlay: _openMovie,
        onFavorite: _toggleFavoriteMovie,
        onWatchLater: _toggleWatchLaterMovie,
        onDownload: _isAndroidTv ? null : _downloadMovie,
        favorites: _favoriteMovieIds,
        watchLater: _watchLaterMovieIds,
      ),
      AppSection.recentlyAdded => MoviesScreen(
        tvSelectedIndex: _remoteMenuMode ? null : _tvContentIndex,
        title: 'Aggiunti di recente',
        movies: _movies.take(350).toList(),
        movieProgress: _movieProgress,
        onPlay: _openMovie,
        onFavorite: _toggleFavoriteMovie,
        onWatchLater: _toggleWatchLaterMovie,
        onDownload: _isAndroidTv ? null : _downloadMovie,
        favorites: _favoriteMovieIds,
        watchLater: _watchLaterMovieIds,
      ),
      AppSection.settings => SettingsScreen(
        tvSelectedIndex: _remoteMenuMode ? null : _tvContentIndex,
        profiles: _profiles,
        activeProfile: _profile,
        titleController: _titleController,
        serverController: _serverController,
        userController: _userController,
        passController: _passController,
        titleFocusNode: _settingsTitleFocusNode,
        serverFocusNode: _settingsServerFocusNode,
        userFocusNode: _settingsUserFocusNode,
        passFocusNode: _settingsPassFocusNode,
        liveCount: _liveChannels.length,
        movieCount: _movies.length,
        seriesCount: _series.length,
        favoriteCount: _favoriteMovieIds.length,
        watchLaterCount: _watchLaterMovieIds.length,
        onSave: () => _saveAndLoadProfile(forceRefresh: false),
        onReload: () => _loadCatalog(forceRefresh: true),
        onSelectProfile: _selectProfile,
        onDeleteProfile: _deleteProfile,
      ),
      AppSection.series =>
        _selectedSeries == null
            ? (_isAndroidTv
                  ? TvFeaturedBrowseScreen<SeriesShow>(
                      kindLabel: 'SERIE',
                      rowTitle: _seriesCategoryId.isEmpty
                          ? 'Catalogo serie'
                          : _categoryName(_seriesCategories, _seriesCategoryId),
                      items: _filteredSeries,
                      selectedIndex: _remoteMenuMode ? null : _tvContentIndex,
                      imageUrl: (show) => show.logo,
                      titleFor: (show) => show.name,
                      metaFor: (show) => _seriesBrowseMeta(show),
                      description: _browseHeroDescription,
                      descriptionLoading: _browseHeroLoading,
                      categories: _seriesCategories,
                      selectedCategoryId: _seriesCategoryId,
                      categoryName: (id) =>
                          _categoryName(_seriesCategories, id),
                      categoryLabel: (id) => _categoryNameWithCount(
                        _seriesCategories,
                        id,
                        _seriesCategoryCounts(),
                      ),
                      onCategoryChanged: _setSeriesCategory,
                      onOpen: _openSeries,
                    )
                  : SeriesScreen(
                      tvSelectedIndex: _remoteMenuMode ? null : _tvContentIndex,
                      shows: _filteredSeries,
                      seriesWatchProgress: _seriesWatchProgress,
                      allCount: _series.length,
                      categories: _seriesCategories,
                      selectedCategoryId: _seriesCategoryId,
                      sort: _seriesSort,
                      categoryName: (id) =>
                          _categoryName(_seriesCategories, id),
                      categoryLabel: (id) => _categoryNameWithCount(
                        _seriesCategories,
                        id,
                        _seriesCategoryCounts(),
                      ),
                      onCategoryChanged: _setSeriesCategory,
                      onSortChanged: (sort) =>
                          setState(() => _seriesSort = sort),
                      onOpen: _openSeries,
                      onFavorite: _toggleFavoriteSeries,
                      onDownload: _isAndroidTv ? null : _downloadSeries,
                      favorites: _favoriteSeriesIds,
                    ))
            : SeriesDetailScreen(
                show: _selectedSeries!,
                description: _selectedSeriesDescription,
                genre: _selectedSeriesGenre,
                episodes: _seriesEpisodes,
                loading: _seriesDetailLoading,
                canResume: _seriesCanResume(_selectedSeries!),
                watchProgress: _seriesWatchProgress(_selectedSeries!),
                onResume: () {
                  final episodeId = _seriesResumeEpisodeId(_selectedSeries!);
                  if (episodeId != null) {
                    unawaited(
                      _continueSeries(_selectedSeries!, episodeId: episodeId),
                    );
                  }
                },
                tvActionIndex: _isAndroidTv && !_remoteMenuMode
                    ? _tvContentIndex
                    : null,
                controller: _videoController,
                player: _player,
                appleController: _appleVideoController,
                tizenController: _tizenVideoController,
                playerTitle: _playerTitle,
                rate: _rate,
                labelFor: _trackLabel,
                onBack: () {
                  setState(() {
                    _selectedSeries = null;
                    _seriesEpisodes = const [];
                  });
                  if (_isAndroidTv) {
                    unawaited(_previewSeriesAt(_tvContentIndex));
                  }
                },
                onPlay: _playEpisode,
                episodeProgress: _episodeProgress,
                onAudioChanged: _selectAudioTrack,
                onSubtitleChanged: _selectSubtitleTrack,
                onRateChanged: _setRate,
                onToggleFocusMode: _togglePlayerFocusMode,
                onPictureInPicture: _showPictureInPictureUnavailable,
              ),
      AppSection.epg => EpgScreen(
        tvSelectedIndex: _remoteMenuMode ? null : _tvContentIndex,
        selectedProgrammeIndex: _epgProgrammeIndex,
        selectedProgramme: _selectedGuideProgrammeFor(_selectedLiveChannel),
        channels: _epgChannels,
        categories: _liveCategories,
        selectedCategoryId: _liveCategoryId,
        selectedChannel: _selectedLiveChannel,
        selectedDayOffset: _epgGuideDayOffset,
        epgByChannel: _epgByChannel,
        loading: _epgLoading,
        canReplayProgramme: _canReplayProgramme,
        onCategoryChanged: _setEpgCategory,
        onDayOffsetChanged: _setEpgGuideDayOffset,
        onRefresh: () => unawaited(_loadEpgPage(force: true)),
        onSelectChannel: (channel) =>
            _previewEpgChannelAt(_channelIndexOf(_epgChannels, channel)),
        onWatchProgramme: _openLiveProgrammeFromGuide,
        onLoadChannel: (channel) => unawaited(_loadChannelEpg(channel)),
      ),
      AppSection.downloads => DownloadsScreen(
        tvSelectedIndex: _remoteMenuMode ? null : _tvContentIndex,
        movies: _watchLaterMovies,
        onPlay: _openMovie,
        onFavorite: _toggleFavoriteMovie,
        onWatchLater: _toggleWatchLaterMovie,
        onDownload: _downloadMovie,
        onOpenDownloadedFile: _openDownloadedFile,
        favorites: _favoriteMovieIds,
        watchLater: _watchLaterMovieIds,
        downloads: _downloads,
      ),
    };
  }
}

class _TvTopNavigation extends StatelessWidget {
  const _TvTopNavigation({
    required this.section,
    required this.remoteSection,
    required this.remoteSearchSelected,
    required this.remoteSearchIconFocused,
    required this.sections,
    required this.sectionLabel,
    required this.queryController,
    required this.searchFocusNode,
    required this.profile,
    required this.status,
    required this.loading,
    required this.onQueryChanged,
    required this.onResetSearch,
    required this.onSectionChanged,
    required this.onOpenSettings,
    required this.onOpenSearch,
  });

  final AppSection section;
  final AppSection? remoteSection;
  final bool remoteSearchSelected;
  final bool remoteSearchIconFocused;
  final List<AppSection> sections;
  final String Function(AppSection section) sectionLabel;
  final TextEditingController queryController;
  final FocusNode searchFocusNode;
  final XtreamProfile? profile;
  final String status;
  final bool loading;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onResetSearch;
  final ValueChanged<AppSection> onSectionChanged;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenSearch;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: LelegColors.sidebar.withValues(alpha: 0.96),
        border: const Border(bottom: BorderSide(color: LelegColors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(
        TvUi.contentPadding,
        0,
        TvUi.contentPadding,
        0,
      ),
      height: TvUi.navHeight,
      child: Row(
        children: [
          const _Brand(compact: true),
          const SizedBox(width: 20),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final item in sections) ...[
                      _TvTopNavItem(
                        label: sectionLabel(item),
                        selected: remoteSection == item,
                        active: section == item,
                        onTap: () => onSectionChanged(item),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (remoteSearchSelected)
            SizedBox(
              width: 200,
              child: TextField(
                controller: queryController,
                focusNode: searchFocusNode,
                autofocus: true,
                style: const TextStyle(fontSize: TvUi.body),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Cerca titoli, canali…',
                  hintStyle: const TextStyle(fontSize: TvUi.body),
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: queryController.text.trim().isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: onResetSearch,
                        ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                ),
                onChanged: onQueryChanged,
                onSubmitted: onQueryChanged,
              ),
            )
          else
            // Cerca: evidenziata solo con remoteSearchIconFocused, si apre solo con OK
            _TvHeaderIconButton(
              tooltip: 'Cerca (OK per aprire)',
              icon: Icons.search,
              selected: remoteSearchIconFocused,
              onTap: onOpenSearch,
            ),
          const SizedBox(width: 4),
          _TvHeaderIconButton(
            tooltip: 'Impostazioni',
            icon: Icons.settings_outlined,
            selected: section == AppSection.settings,
            onTap: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

class _TvTopNavItem extends StatelessWidget {
  const _TvTopNavItem({
    required this.label,
    required this.selected,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final highlighted = selected || active;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: TvUi.navHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: TvUi.navLabel,
                    fontWeight: highlighted ? FontWeight.w700 : FontWeight.w500,
                    color: highlighted ? LelegColors.fg : LelegColors.muted,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 5),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  height: 2.5,
                  width: selected ? 22 : (active ? 22 : 0),
                  decoration: BoxDecoration(
                    color: selected
                        ? LelegColors.accent
                        : LelegColors.accent.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottone icona nell'header TV con focus gestito via telecomando (non apre al solo focus).
class _TvHeaderIconButton extends StatefulWidget {
  const _TvHeaderIconButton({
    required this.icon,
    required this.selected,
    required this.onTap,
    this.tooltip = '',
  });

  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final String tooltip;

  @override
  State<_TvHeaderIconButton> createState() => _TvHeaderIconButtonState();
}

class _TvHeaderIconButtonState extends State<_TvHeaderIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.selected
        ? LelegColors.accent
        : (_focused ? LelegColors.fg : LelegColors.muted);
    return Focus(
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _focused
                  ? LelegColors.accent.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(widget.icon, size: 20, color: color),
          ),
        ),
      ),
    );
  }
}

class LelegSidebar extends StatelessWidget {
  const LelegSidebar({
    required this.section,
    required this.remoteSection,
    required this.queryController,
    required this.accountInfo,
    required this.profile,
    required this.status,
    required this.loading,
    required this.onQueryChanged,
    required this.onResetSearch,
    required this.onSectionChanged,
    this.compact = false,
    this.showDownloads = true,
    this.searchFocusNode,
    this.remoteSearchSelected = false,
    super.key,
  });

  final AppSection section;
  final AppSection? remoteSection;
  final TextEditingController queryController;
  final XtreamAccountInfo? accountInfo;
  final XtreamProfile? profile;
  final String status;
  final bool loading;
  final bool compact;
  final bool showDownloads;
  final FocusNode? searchFocusNode;
  final bool remoteSearchSelected;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onResetSearch;
  final ValueChanged<AppSection> onSectionChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? double.infinity : 300,
      decoration: const BoxDecoration(
        color: LelegColors.sidebar,
        border: Border(right: BorderSide(color: LelegColors.line)),
      ),
      padding: EdgeInsets.fromLTRB(18, compact ? 12 : 22, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Brand(compact: compact),
          SizedBox(height: compact ? 18 : 28),
          if (queryController.text.trim().isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onResetSearch,
                icon: const Icon(Icons.home_outlined),
                label: const Text('Reset ricerca'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: remoteSearchSelected
                    ? LelegColors.accent
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: TextField(
              controller: queryController,
              focusNode: searchFocusNode,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'Cerca',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: queryController.text.trim().isEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            searchFocusNode == null ? 'Ctrl K' : 'Su + OK',
                            style: const TextStyle(
                              fontSize: 11,
                              color: LelegColors.muted,
                            ),
                          ),
                        ),
                      )
                    : IconButton(
                        tooltip: 'Pulisci ricerca',
                        onPressed: onResetSearch,
                        icon: const Icon(Icons.close),
                      ),
              ),
              onChanged: onQueryChanged,
              onSubmitted: (_) {
                onQueryChanged(queryController.text);
                FocusScope.of(context).unfocus();
                if (compact) {
                  Navigator.of(context).maybePop();
                }
              },
              onEditingComplete: () {
                onQueryChanged(queryController.text);
              },
            ),
          ),
          const SizedBox(height: 18),
          Expanded(
            child: ListView(
              children: [
                _NavItem(
                  Icons.home_outlined,
                  'Home',
                  AppSection.home,
                  section,
                  remoteSection,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.live_tv_outlined,
                  'Live TV',
                  AppSection.live,
                  section,
                  remoteSection,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.movie_outlined,
                  'Film',
                  AppSection.movies,
                  section,
                  remoteSection,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.layers_outlined,
                  'Serie',
                  AppSection.series,
                  section,
                  remoteSection,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.star_border,
                  'Preferiti',
                  AppSection.favorites,
                  section,
                  remoteSection,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.bookmark_border,
                  'Da vedere',
                  AppSection.watchLater,
                  section,
                  remoteSection,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.auto_awesome,
                  'Aggiunti di recente',
                  AppSection.recentlyAdded,
                  section,
                  remoteSection,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.calendar_month_outlined,
                  'Guida TV',
                  AppSection.epg,
                  section,
                  remoteSection,
                  onSectionChanged,
                ),
                if (showDownloads)
                  _NavItem(
                    Icons.download_outlined,
                    'Download',
                    AppSection.downloads,
                    section,
                    remoteSection,
                    onSectionChanged,
                  ),
              ],
            ),
          ),
          if (accountInfo?.expiresAt != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Account scade il ${accountInfo!.expiresAt!.day}/${accountInfo!.expiresAt!.month}/${accountInfo!.expiresAt!.year}',
                style: const TextStyle(fontSize: 12, color: LelegColors.muted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          _SidebarStatus(status: status, loading: loading),
          const SizedBox(height: 10),
          _RemoteActivate(
            onActivate: () => onSectionChanged(AppSection.settings),
            child: OutlinedButton.icon(
              onPressed: () => onSectionChanged(AppSection.settings),
              icon: const Icon(Icons.settings_outlined),
              label: Text(
                profile == null
                    ? 'Impostazioni'
                    : (profile!.title.trim().isEmpty
                          ? 'Lista attiva'
                          : profile!.title.trim()),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                side: BorderSide(
                  color: remoteSection == AppSection.settings
                      ? LelegColors.accent
                      : LelegColors.line,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final fontSize = compact ? TvUi.brandLabel : 18.0;
    final iconSize = compact ? TvUi.brandIcon : 42.0;
    return Row(
      children: [
        Icon(Icons.all_inclusive, color: LelegColors.accent, size: iconSize),
        SizedBox(width: compact ? 10 : 12),
        Text(
          'Leleg',
          style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800),
        ),
        Text(
          ' IPTV',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w900,
            color: LelegColors.accent,
          ),
        ),
      ],
    );
  }
}

class _RemoteActivate extends StatelessWidget {
  const _RemoteActivate({required this.onActivate, required this.child});

  final VoidCallback onActivate;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            onActivate();
            return null;
          },
        ),
      },
      child: child,
    );
  }
}

class _EnsureVisibleWhenSelected extends StatelessWidget {
  const _EnsureVisibleWhenSelected({
    required this.selected,
    required this.child,
  });

  final bool selected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final renderObject = context.findRenderObject();
        if (renderObject is! RenderBox || !renderObject.attached) return;
        if (!renderObject.hasSize) return;
        try {
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          );
        } catch (_) {
          // Ignore transient layout timing issues on TV focus transitions.
        }
      });
    }
    return child;
  }
}

class _PhoneMoreTile extends StatelessWidget {
  const _PhoneMoreTile({
    required this.icon,
    required this.label,
    required this.section,
    required this.current,
  });

  final IconData icon;
  final String label;
  final AppSection section;
  final AppSection current;

  @override
  Widget build(BuildContext context) {
    final selected = section == current;
    return ListTile(
      leading: Icon(
        icon,
        color: selected ? LelegColors.accent : LelegColors.muted,
      ),
      title: Text(
        label,
        style: TextStyle(
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
          color: selected ? LelegColors.fg : LelegColors.muted,
        ),
      ),
      trailing: selected
          ? const Icon(Icons.check, color: LelegColors.accent, size: 20)
          : null,
      onTap: () => Navigator.of(context).pop(section),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem(
    this.icon,
    this.label,
    this.value,
    this.current,
    this.remote,
    this.onTap,
  );

  final IconData icon;
  final String label;
  final AppSection value;
  final AppSection current;
  final AppSection? remote;
  final ValueChanged<AppSection> onTap;

  @override
  Widget build(BuildContext context) {
    final active = value == current;
    final selected = value == remote;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: _RemoteActivate(
        onActivate: () => onTap(value),
        child: Material(
          color: active || selected ? LelegColors.surface3 : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onTap(value),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              decoration: active || selected
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: selected
                            ? LelegColors.accent
                            : LelegColors.accent.withValues(alpha: 0.45),
                      ),
                    )
                  : null,
              child: Row(
                children: [
                  Icon(
                    icon,
                    color: active || selected
                        ? LelegColors.accent
                        : LelegColors.muted,
                    size: 22,
                  ),
                  const SizedBox(width: 14),
                  Text(
                    label,
                    style: TextStyle(
                      color: active ? LelegColors.fg : LelegColors.muted,
                      fontWeight: active || selected
                          ? FontWeight.w800
                          : FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarStatus extends StatelessWidget {
  const _SidebarStatus({required this.status, required this.loading});

  final String status;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LelegColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LelegColors.line),
      ),
      child: Row(
        children: [
          if (loading)
            const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (loading) const SizedBox(width: 10),
          Expanded(
            child: Text(
              status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LelegColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TvHomeHero extends StatelessWidget {
  const _TvHomeHero({required this.target});

  final TvHomeHeroTarget? target;

  @override
  Widget build(BuildContext context) {
    if (target == null) {
      return const SizedBox.shrink();
    }
    final hero = target!;
    final heroHeight = TvUi.heroHeight(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    return SizedBox(
      width: double.infinity,
      height: heroHeight,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: LelegColors.bg),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: screenWidth * 0.62,
              child: ClipRect(
                child: _BackdropImage(
                  url: hero.imageUrl,
                  alignment: Alignment.center,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    LelegColors.bg,
                    LelegColors.bg.withValues(alpha: 0.96),
                    LelegColors.bg.withValues(alpha: 0.72),
                    Colors.transparent,
                  ],
                  stops: const [0, 0.34, 0.58, 0.9],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    LelegColors.bg,
                    LelegColors.bg.withValues(alpha: 0.5),
                    Colors.transparent,
                  ],
                  stops: const [0, 0.28, 0.62],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                TvUi.contentPadding,
                10,
                TvUi.contentPadding,
                18,
              ),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hero.eyebrow,
                        style: TextStyle(
                          color: LelegColors.muted,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w800,
                          fontSize: TvUi.eyebrow,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        hero.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: TvUi.heroTitle,
                          fontWeight: FontWeight.w900,
                          height: 1.08,
                        ),
                      ),
                      if (hero.progress != null &&
                          hero.progress!.fraction > 0) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            minHeight: 4,
                            value: hero.progress!.isCompleted
                                ? 1
                                : hero.progress!.fraction,
                            backgroundColor: LelegColors.line,
                            color: LelegColors.accent,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          hero.progress!.isCompleted
                              ? 'Visto'
                              : '${(hero.progress!.fraction * 100).round()}% visto',
                          style: const TextStyle(
                            color: LelegColors.muted,
                            fontSize: TvUi.caption,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: hero.onAction,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          minimumSize: const Size(0, 32),
                          textStyle: const TextStyle(
                            fontSize: TvUi.body,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        icon: Icon(
                          hero.progress?.canResume == true
                              ? Icons.play_circle_outline
                              : Icons.play_arrow,
                          size: 16,
                        ),
                        label: Text(hero.actionLabel),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.tvSelectedIndex,
    required this.liveCount,
    required this.movieCount,
    required this.seriesCount,
    required this.loading,
    required this.status,
    required this.recentMovies,
    required this.favoriteMovies,
    required this.watchLaterMovies,
    required this.recentLiveChannels,
    required this.recentMovieHistory,
    required this.recentSeriesHistory,
    this.heroTarget,
    required this.favoriteCount,
    required this.watchLaterCount,
    required this.onOpenLive,
    required this.onOpenMovies,
    required this.onOpenSeries,
    required this.onOpenFavorites,
    required this.onOpenWatchLater,
    required this.onOpenEpg,
    required this.onOpenDownloads,
    required this.onOpenSettings,
    required this.onPlayMovie,
    required this.onPlayLiveChannel,
    required this.onOpenSeriesShow,
    this.isTv = false,
    this.showDownloads = true,
    super.key,
  });

  final int? tvSelectedIndex;
  final int liveCount;
  final int movieCount;
  final int seriesCount;
  final bool loading;
  final String status;
  final List<VodMovie> recentMovies;
  final List<VodMovie> favoriteMovies;
  final List<VodMovie> watchLaterMovies;
  final List<LiveChannel> recentLiveChannels;
  final List<VodMovie> recentMovieHistory;
  final List<SeriesShow> recentSeriesHistory;
  final TvHomeHeroTarget? heroTarget;
  final int favoriteCount;
  final int watchLaterCount;
  final bool isTv;
  final bool showDownloads;
  final VoidCallback onOpenLive;
  final VoidCallback onOpenMovies;
  final VoidCallback onOpenSeries;
  final VoidCallback onOpenFavorites;
  final VoidCallback onOpenWatchLater;
  final VoidCallback onOpenEpg;
  final VoidCallback onOpenDownloads;
  final VoidCallback onOpenSettings;
  final ValueChanged<VodMovie> onPlayMovie;
  final ValueChanged<LiveChannel> onPlayLiveChannel;
  final ValueChanged<SeriesShow> onOpenSeriesShow;

  @override
  Widget build(BuildContext context) {
    final mobile =
        !isTv && _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
    if (isTv) {
      return _PageScaffold(
        title: 'Home',
        hideHeader: true,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _TvHomeHero(target: heroTarget),
            if (loading)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: _LoadingBand(status: status),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                TvUi.contentPadding,
                12,
                TvUi.contentPadding,
                20,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _HomeMovieStrip(
                    title: 'Preferiti',
                    empty: 'Nessun preferito salvato.',
                    movies: favoriteMovies,
                    onPlayMovie: onPlayMovie,
                  ),
                  const SizedBox(height: TvUi.rowGap),
                  _HomeChannelStrip(
                    title: 'Ultimi canali visti',
                    empty: 'Nessun canale visto di recente.',
                    channels: recentLiveChannels,
                    onPlayChannel: onPlayLiveChannel,
                  ),
                  const SizedBox(height: TvUi.rowGap),
                  _HomeMovieStrip(
                    title: 'Ultimi film visti',
                    empty: 'Nessun film visto di recente.',
                    movies: recentMovieHistory,
                    onPlayMovie: onPlayMovie,
                  ),
                  const SizedBox(height: TvUi.rowGap),
                  _HomeSeriesStrip(
                    title: 'Ultime serie viste',
                    empty: 'Nessuna serie vista di recente.',
                    series: recentSeriesHistory,
                    onOpenSeries: onOpenSeriesShow,
                  ),
                  const SizedBox(height: TvUi.rowGap),
                  _HomeMovieStrip(
                    title: 'Nuovi arrivi',
                    empty: 'Carica una playlist in Impostazioni.',
                    movies: recentMovies,
                    onPlayMovie: onPlayMovie,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return _PageScaffold(
      eyebrow: _greeting(),
      title: 'Leleg IPTV',
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          mobile ? 16 : 28,
          mobile ? 8 : 16,
          mobile ? 16 : 28,
          mobile ? 20 : 28,
        ),
        children: [
          _HomeHeroGrid(
            selectedIndex: tvSelectedIndex,
            liveCount: liveCount,
            movieCount: movieCount,
            seriesCount: seriesCount,
            onOpenLive: onOpenLive,
            onOpenMovies: onOpenMovies,
            onOpenSeries: onOpenSeries,
          ),
          if (loading) ...[
            const SizedBox(height: 18),
            _LoadingBand(status: status),
          ],
          const SizedBox(height: 18),
          _HomeQuickActions(
            selectedIndex: tvSelectedIndex == null
                ? null
                : (tvSelectedIndex! - 3),
            favoriteCount: favoriteCount,
            watchLaterCount: watchLaterCount,
            onOpenFavorites: onOpenFavorites,
            onOpenWatchLater: onOpenWatchLater,
            onOpenEpg: onOpenEpg,
            onOpenDownloads: onOpenDownloads,
            onOpenSettings: onOpenSettings,
            showDownloads: showDownloads,
          ),
          const SizedBox(height: 28),
          _HomeMovieStrip(
            title: 'Preferiti',
            empty: 'Nessun preferito salvato.',
            movies: favoriteMovies,
            onPlayMovie: onPlayMovie,
          ),
          const SizedBox(height: 28),
          _HomeMovieStrip(
            title: 'Da vedere',
            empty: 'Nessun titolo in Da vedere.',
            movies: watchLaterMovies,
            onPlayMovie: onPlayMovie,
          ),
          const SizedBox(height: 28),
          _HomeMovieStrip(
            title: 'Aggiunti di recente',
            empty: 'Carica una playlist in Impostazioni.',
            movies: recentMovies,
            onPlayMovie: onPlayMovie,
          ),
        ],
      ),
    );
  }

  String _greeting() {
    return 'IN EVIDENZA';
  }
}

class _HomeHeroGrid extends StatelessWidget {
  const _HomeHeroGrid({
    required this.selectedIndex,
    required this.liveCount,
    required this.movieCount,
    required this.seriesCount,
    required this.onOpenLive,
    required this.onOpenMovies,
    required this.onOpenSeries,
  });

  final int? selectedIndex;
  final int liveCount;
  final int movieCount;
  final int seriesCount;
  final VoidCallback onOpenLive;
  final VoidCallback onOpenMovies;
  final VoidCallback onOpenSeries;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 700;
        if (compact) {
          return Column(
            children: [
              _HubTile(
                title: 'Live TV',
                subtitle: '$liveCount canali e cosa va in onda adesso.',
                icon: Icons.live_tv,
                onTap: onOpenLive,
                prominent: true,
                selected: selectedIndex == 0,
              ),
              const SizedBox(height: 14),
              _HubTile(
                title: 'Film',
                subtitle: '$movieCount titoli nel catalogo.',
                icon: Icons.movie,
                onTap: onOpenMovies,
                selected: selectedIndex == 1,
              ),
              const SizedBox(height: 14),
              _HubTile(
                title: 'Serie',
                subtitle: '$seriesCount serie e stagioni complete.',
                icon: Icons.layers,
                onTap: onOpenSeries,
                selected: selectedIndex == 2,
              ),
            ],
          );
        }
        return SizedBox(
          height: 360,
          child: Row(
            children: [
              Expanded(
                flex: 2,
                child: _HubTile(
                  title: 'Live TV',
                  subtitle: '$liveCount canali e cosa va in onda adesso.',
                  icon: Icons.live_tv,
                  onTap: onOpenLive,
                  prominent: true,
                  selected: selectedIndex == 0,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: _HubTile(
                        title: 'Film',
                        subtitle: '$movieCount titoli nel catalogo.',
                        icon: Icons.movie,
                        onTap: onOpenMovies,
                        selected: selectedIndex == 1,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: _HubTile(
                        title: 'Serie',
                        subtitle: '$seriesCount serie e stagioni complete.',
                        icon: Icons.layers,
                        onTap: onOpenSeries,
                        selected: selectedIndex == 2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HubTile extends StatelessWidget {
  const _HubTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.prominent = false,
    this.selected = false,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final bool prominent;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final gradientColors = prominent
        ? const [Color(0xFF0E3540), Color(0xFF122026), LelegColors.surface]
        : const [Color(0xFF0D2D36), Color(0xFF142229), LelegColors.surface];
    return _EnsureVisibleWhenSelected(
      selected: selected,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mobile = constraints.maxWidth < 520;
          return Material(
            color: LelegColors.surface,
            borderRadius: BorderRadius.circular(18),
            child: _RemoteActivate(
              onActivate: onTap,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  width: double.infinity,
                  constraints: BoxConstraints(
                    minHeight: prominent
                        ? (mobile ? 180 : 220)
                        : (mobile ? 128 : 150),
                  ),
                  padding: EdgeInsets.all(
                    prominent ? (mobile ? 22 : 32) : (mobile ? 18 : 22),
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: selected ? LelegColors.accent : LelegColors.line,
                      width: selected ? 2 : 1,
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: gradientColors,
                      stops: const [0, 0.48, 1],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Icon(
                            icon,
                            color: LelegColors.accent,
                            size: prominent
                                ? (mobile ? 54 : 74)
                                : (mobile ? 34 : 42),
                          ),
                          const Icon(
                            Icons.chevron_right,
                            color: LelegColors.muted,
                          ),
                        ],
                      ),
                      SizedBox(
                        height: prominent
                            ? (mobile ? 46 : 64)
                            : (mobile ? 18 : 24),
                      ),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: prominent
                              ? (mobile ? 42 : 72)
                              : (mobile ? 24 : 30),
                          height: 0.92,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      SizedBox(height: prominent ? (mobile ? 8 : 12) : 7),
                      Text(
                        subtitle,
                        maxLines: prominent ? (mobile ? 3 : 2) : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: LelegColors.muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HomeQuickActions extends StatelessWidget {
  const _HomeQuickActions({
    required this.selectedIndex,
    required this.favoriteCount,
    required this.watchLaterCount,
    required this.onOpenFavorites,
    required this.onOpenWatchLater,
    required this.onOpenEpg,
    required this.onOpenDownloads,
    required this.onOpenSettings,
    this.showDownloads = true,
  });

  final int? selectedIndex;
  final int favoriteCount;
  final int watchLaterCount;
  final bool showDownloads;
  final VoidCallback onOpenFavorites;
  final VoidCallback onOpenWatchLater;
  final VoidCallback onOpenEpg;
  final VoidCallback onOpenDownloads;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final mobile = _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
    final actions = [
      _QuickActionData(
        Icons.star,
        'Preferiti',
        '$favoriteCount salvati',
        onOpenFavorites,
      ),
      _QuickActionData(
        Icons.bookmark,
        'Da vedere',
        '$watchLaterCount titoli',
        onOpenWatchLater,
      ),
      _QuickActionData(
        Icons.calendar_month,
        'Guida TV',
        'Canali e archivio',
        onOpenEpg,
      ),
      if (showDownloads)
        _QuickActionData(
          Icons.download,
          'Download',
          'Offline e coda',
          onOpenDownloads,
        ),
      _QuickActionData(
        Icons.settings,
        'Impostazioni',
        'Provider e catalogo',
        onOpenSettings,
      ),
    ];
    return SizedBox(
      height: mobile ? 72 : 82,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: actions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, index) {
          final action = actions[index];
          return _QuickActionChip(
            action: action,
            selected: selectedIndex == index,
          );
        },
      ),
    );
  }
}

class _QuickActionData {
  const _QuickActionData(this.icon, this.title, this.subtitle, this.onTap);

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
}

class _QuickActionChip extends StatelessWidget {
  const _QuickActionChip({required this.action, required this.selected});

  final _QuickActionData action;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return _EnsureVisibleWhenSelected(
      selected: selected,
      child: SizedBox(
        width: 240,
        child: Material(
          color: LelegColors.surface,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: action.onTap,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: selected ? LelegColors.accent : LelegColors.line,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(action.icon, color: LelegColors.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          action.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        Text(
                          action.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LelegColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeMovieStrip extends StatelessWidget {
  const _HomeMovieStrip({
    required this.title,
    required this.empty,
    required this.movies,
    required this.onPlayMovie,
  });

  final String title;
  final String empty;
  final List<VodMovie> movies;
  final ValueChanged<VodMovie> onPlayMovie;

  @override
  Widget build(BuildContext context) {
    final mobile = _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
    final tv = TvUi.isActive(context);
    final cardHeight = tv
        ? (TvUi.cardWidth * 9 / 16)
        : (mobile ? 240.0 : 290.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: tv ? TvUi.sectionTitle : (mobile ? 18 : 22),
            fontWeight: FontWeight.w800,
          ),
        ),
        SizedBox(height: tv ? 6 : 14),
        if (movies.isEmpty)
          _InlineEmptyStrip(message: empty, compact: tv)
        else
          SizedBox(
            height: cardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: movies.length,
              separatorBuilder: (_, _) => SizedBox(width: tv ? 8 : 14),
              itemBuilder: (_, index) => tv
                  ? _TvLandscapeCard(
                      title: movies[index].name,
                      image: movies[index].logo,
                      onTap: () => onPlayMovie(movies[index]),
                    )
                  : SizedBox(
                      width: mobile ? 170 : 190,
                      child: _MoviePosterCard(
                        movie: movies[index],
                        onPlay: onPlayMovie,
                      ),
                    ),
            ),
          ),
      ],
    );
  }
}

class _HomeChannelStrip extends StatelessWidget {
  const _HomeChannelStrip({
    required this.title,
    required this.empty,
    required this.channels,
    required this.onPlayChannel,
  });

  final String title;
  final String empty;
  final List<LiveChannel> channels;
  final ValueChanged<LiveChannel> onPlayChannel;

  @override
  Widget build(BuildContext context) {
    final cardHeight = TvUi.cardWidth * 9 / 16;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: TvUi.sectionTitle,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        if (channels.isEmpty)
          _InlineEmptyStrip(message: empty, compact: true)
        else
          SizedBox(
            height: cardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: channels.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, index) => _TvLandscapeCard(
                title: channels[index].name,
                image: channels[index].logo,
                onTap: () => onPlayChannel(channels[index]),
              ),
            ),
          ),
      ],
    );
  }
}

class _HomeSeriesStrip extends StatelessWidget {
  const _HomeSeriesStrip({
    required this.title,
    required this.empty,
    required this.series,
    required this.onOpenSeries,
  });

  final String title;
  final String empty;
  final List<SeriesShow> series;
  final ValueChanged<SeriesShow> onOpenSeries;

  @override
  Widget build(BuildContext context) {
    final cardHeight = TvUi.cardWidth * 9 / 16;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: TvUi.sectionTitle,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        if (series.isEmpty)
          _InlineEmptyStrip(message: empty, compact: true)
        else
          SizedBox(
            height: cardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: series.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, index) => _TvLandscapeCard(
                title: series[index].name,
                image: series[index].logo,
                onTap: () => onOpenSeries(series[index]),
              ),
            ),
          ),
      ],
    );
  }
}

class _InlineEmptyStrip extends StatelessWidget {
  const _InlineEmptyStrip({required this.message, this.compact = false});

  final String message;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 2),
        child: Text(
          message,
          style: const TextStyle(color: LelegColors.muted, fontSize: TvUi.body),
        ),
      );
    }
    return Container(
      height: 96,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: LelegColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: LelegColors.line),
      ),
      child: Text(message, style: const TextStyle(color: LelegColors.muted)),
    );
  }
}

class LiveScreen extends StatelessWidget {
  const LiveScreen({
    required this.tvSelectedIndex,
    required this.channels,
    required this.allCount,
    required this.categories,
    required this.selectedCategoryId,
    required this.categoryName,
    this.categoryLabel,
    required this.playerTitle,
    required this.controller,
    required this.player,
    this.appleController,
    this.tizenController,
    required this.rate,
    required this.labelFor,
    required this.onPlay,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    required this.onCategoryChanged,
    required this.preferTvLayout,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
    required this.epg,
    required this.epgLoading,
    required this.epgByChannel,
    this.liveProgrammeLoading = false,
    required this.selectedChannel,
    required this.onSelectChannel,
    required this.onWatchProgramme,
    this.onOpenGuide,
    super.key,
  });

  final int? tvSelectedIndex;
  final List<LiveChannel> channels;
  final int allCount;
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final String Function(String id) categoryName;
  final String Function(String id)? categoryLabel;
  final String playerTitle;
  final VideoController? controller;
  final Player? player;
  final vp.VideoPlayerController? appleController;
  final avplay.VideoPlayerController? tizenController;
  final double rate;
  final String Function(dynamic value) labelFor;
  final ValueChanged<LiveChannel> onPlay;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;
  final ValueChanged<String> onCategoryChanged;
  final bool preferTvLayout;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;
  final List<EpgProgramme> epg;
  final bool epgLoading;
  final Map<int, List<EpgProgramme>> epgByChannel;
  final bool liveProgrammeLoading;
  final LiveChannel? selectedChannel;
  final ValueChanged<LiveChannel> onSelectChannel;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onWatchProgramme;
  final VoidCallback? onOpenGuide;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final phoneLive =
        !preferTvLayout &&
        _isMobileHandheldPlatform() &&
        _isHandheldPhoneSize(size);
    final splitLive = !preferTvLayout && !phoneLive;
    return _PageScaffold(
      title: 'Live TV',
      eyebrow: '${channels.length} di $allCount canali',
      hideHeader: preferTvLayout || phoneLive || splitLive,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              !preferTvLayout && _useCompactAdaptiveConstraints(constraints);
          Widget buildChannelList({
            required bool playOnTap,
            required bool showLiveProgramme,
            required bool showPlayButton,
          }) {
            if (channels.isEmpty) {
              return const _EmptyState(message: 'Nessun canale caricato.');
            }
            return ListView.separated(
              padding: EdgeInsets.fromLTRB(
                preferTvLayout ? 8 : (compact ? 12 : 16),
                0,
                preferTvLayout ? 8 : (compact ? 12 : 16),
                preferTvLayout ? 8 : (compact ? 12 : 16),
              ),
              itemCount: channels.length,
              separatorBuilder: (_, _) =>
                  SizedBox(height: preferTvLayout ? 4 : (phoneLive ? 4 : 8)),
              itemBuilder: (_, index) {
                final channel = channels[index];
                final programmes = epgByChannel[channel.id] ?? const [];
                final liveTitle = showLiveProgramme
                    ? (_liveNowProgrammeTitle(programmes) ??
                          (liveProgrammeLoading && programmes.isEmpty
                              ? '…'
                              : programmes.isEmpty
                              ? 'Guida non disponibile'
                              : ''))
                    : null;
                return _ChannelTile(
                  channel: channel,
                  onOpen: onSelectChannel,
                  onPlay: onPlay,
                  category: categoryName(channel.categoryId),
                  liveProgramme: liveTitle,
                  selected:
                      selectedChannel?.id == channel.id ||
                      (preferTvLayout && tvSelectedIndex == index),
                  compact: preferTvLayout,
                  playOnTap: playOnTap,
                  showPlayButton: showPlayButton,
                );
              },
            );
          }

          final channelList = buildChannelList(
            playOnTap: phoneLive || splitLive,
            showLiveProgramme: phoneLive,
            showPlayButton: !phoneLive && !splitLive,
          );
          final playerPane = Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 10, 8),
            child: Column(
              children: [
                Expanded(
                  flex: 6,
                  child: PlayerCard(
                    title: playerTitle,
                    controller: controller,
                    player: player,
                    appleController: appleController,
                    tizenController: tizenController,
                    rate: rate,
                    labelFor: labelFor,
                    onAudioChanged: onAudioChanged,
                    onSubtitleChanged: onSubtitleChanged,
                    onRateChanged: onRateChanged,
                    onToggleFocusMode: onToggleFocusMode,
                    onPictureInPicture: onPictureInPicture,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  flex: 4,
                  child: _EpgProgrammeList(
                    programmes: epg,
                    loading: epgLoading,
                    emptyMessage: 'Seleziona un canale per vedere la guida.',
                    channel: selectedChannel,
                    onWatch: onWatchProgramme,
                  ),
                ),
              ],
            ),
          );
          if (phoneLive) {
            return Column(
              children: [
                _CatalogToolbar(
                  categories: categories,
                  selectedCategoryId: selectedCategoryId,
                  categoryName: categoryName,
                  categoryLabel: categoryLabel,
                  onCategoryChanged: onCategoryChanged,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: channelList,
                  ),
                ),
              ],
            );
          }
          if (splitLive) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 360,
                  child: Column(
                    children: [
                      _CatalogToolbar(
                        categories: categories,
                        selectedCategoryId: selectedCategoryId,
                        categoryName: categoryName,
                        categoryLabel: categoryLabel,
                        onCategoryChanged: onCategoryChanged,
                        narrow: true,
                      ),
                      Expanded(
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            border: Border(
                              right: BorderSide(color: LelegColors.line),
                            ),
                          ),
                          child: buildChannelList(
                            playOnTap: true,
                            showLiveProgramme: false,
                            showPlayButton: false,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: playerPane),
              ],
            );
          }
          if (preferTvLayout) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: TvUi.liveCategoryWidth,
                  child: _TvCategorySidebar(
                    categories: categories,
                    selectedCategoryId: selectedCategoryId,
                    categoryLabel: categoryLabel,
                    onCategoryChanged: onCategoryChanged,
                  ),
                ),
                const VerticalDivider(width: 1, color: LelegColors.line),
                SizedBox(width: TvUi.liveChannelWidth, child: channelList),
                const VerticalDivider(width: 1, color: LelegColors.line),
                Expanded(child: playerPane),
              ],
            );
          }
          return const _EmptyState(
            message: 'Layout Live TV non disponibile su questo dispositivo.',
          );
        },
      ),
    );
  }
}

class SearchResultsScreen extends StatelessWidget {
  const SearchResultsScreen({
    required this.query,
    required this.liveChannels,
    required this.movies,
    required this.series,
    required this.onOpenLive,
    required this.onOpenMovie,
    required this.onOpenSeries,
    super.key,
  });

  final String query;
  final List<LiveChannel> liveChannels;
  final List<VodMovie> movies;
  final List<SeriesShow> series;
  final ValueChanged<LiveChannel> onOpenLive;
  final ValueChanged<VodMovie> onOpenMovie;
  final ValueChanged<SeriesShow> onOpenSeries;

  @override
  Widget build(BuildContext context) {
    final total = liveChannels.length + movies.length + series.length;
    final tv = TvUi.isActive(context);
    if (tv) {
      return _PageScaffold(
        title: '',
        hideHeader: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            TvUi.contentPadding,
            8,
            TvUi.contentPadding,
            20,
          ),
          children: [
            Text(
              '$total risultati per "$query"',
              style: const TextStyle(
                color: LelegColors.muted,
                fontSize: TvUi.eyebrow,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 10),
            _HomeChannelStrip(
              title: 'Live TV',
              empty: 'Nessun canale trovato.',
              channels: liveChannels,
              onPlayChannel: onOpenLive,
            ),
            const SizedBox(height: TvUi.rowGap),
            _HomeMovieStrip(
              title: 'Film',
              empty: 'Nessun film trovato.',
              movies: movies,
              onPlayMovie: onOpenMovie,
            ),
            const SizedBox(height: TvUi.rowGap),
            _HomeSeriesStrip(
              title: 'Serie',
              empty: 'Nessuna serie trovata.',
              series: series,
              onOpenSeries: onOpenSeries,
            ),
          ],
        ),
      );
    }
    return _PageScaffold(
      title: 'Cerca',
      eyebrow: '$total risultati per "$query"',
      child: ListView(
        padding: const EdgeInsets.all(28),
        children: [
          _SearchSection<LiveChannel>(
            title: 'Live TV',
            items: liveChannels.take(18).toList(),
            empty: 'Nessun canale trovato.',
            itemBuilder: (channel) => _ChannelTile(
              channel: channel,
              onOpen: onOpenLive,
              onPlay: onOpenLive,
            ),
          ),
          const SizedBox(height: 26),
          _SearchSection<VodMovie>(
            title: 'Film',
            items: movies.take(18).toList(),
            empty: 'Nessun film trovato.',
            itemBuilder: (movie) => _SearchMediaTile(
              title: movie.name,
              image: movie.logo,
              subtitle: movie.containerExtension.toUpperCase(),
              onTap: () => onOpenMovie(movie),
            ),
          ),
          const SizedBox(height: 26),
          _SearchSection<SeriesShow>(
            title: 'Serie',
            items: series.take(18).toList(),
            empty: 'Nessuna serie trovata.',
            itemBuilder: (show) => _SearchMediaTile(
              title: show.name,
              image: show.logo,
              subtitle: show.year,
              onTap: () => onOpenSeries(show),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchSection<T> extends StatelessWidget {
  const _SearchSection({
    required this.title,
    required this.items,
    required this.empty,
    required this.itemBuilder,
  });

  final String title;
  final List<T> items;
  final String empty;
  final Widget Function(T item) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return _SettingsBand(
      title: title,
      child: items.isEmpty
          ? Text(empty, style: const TextStyle(color: LelegColors.muted))
          : Column(
              children: [
                for (final item in items) ...[
                  itemBuilder(item),
                  if (item != items.last) const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }
}

class _SearchMediaTile extends StatelessWidget {
  const _SearchMediaTile({
    required this.title,
    required this.image,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String image;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: LelegColors.surface2,
      borderRadius: BorderRadius.circular(14),
      child: _RemoteActivate(
        onActivate: onTap,
        child: ListTile(
          leading: _Logo(url: image, fallback: Icons.movie),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: subtitle.isEmpty
              ? null
              : Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: LelegColors.muted),
                ),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      ),
    );
  }
}

class TvFeaturedBrowseScreen<T> extends StatelessWidget {
  const TvFeaturedBrowseScreen({
    required this.kindLabel,
    required this.rowTitle,
    required this.items,
    required this.selectedIndex,
    required this.imageUrl,
    required this.titleFor,
    required this.metaFor,
    required this.description,
    required this.descriptionLoading,
    required this.onOpen,
    this.categories = const [],
    this.selectedCategoryId = '',
    this.categoryName,
    this.categoryLabel,
    this.onCategoryChanged,
    this.isFavorite,
    this.onToggleFavorite,
    this.heroActionSelected = false,
    super.key,
  });

  final String kindLabel;
  final String rowTitle;
  final List<T> items;
  final int? selectedIndex;
  final String Function(T item) imageUrl;
  final String Function(T item) titleFor;
  final String Function(T item) metaFor;
  final String description;
  final bool descriptionLoading;
  final ValueChanged<T> onOpen;
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final String Function(String id)? categoryName;
  final String Function(String id)? categoryLabel;
  final ValueChanged<String>? onCategoryChanged;
  final bool Function(T item)? isFavorite;
  final ValueChanged<T>? onToggleFavorite;
  final bool heroActionSelected;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _PageScaffold(
        title: '',
        hideHeader: true,
        child: _EmptyState(message: 'Nessun titolo da mostrare.'),
      );
    }
    final index = ((selectedIndex ?? 0).clamp(0, items.length - 1)).toInt();
    final selected = items[index];
    return _PageScaffold(
      title: '',
      hideHeader: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final heroHeight = constraints.maxHeight * TvUi.browseHeroFraction;
          final rowHeight = constraints.maxHeight - heroHeight;
          return Column(
            children: [
              SizedBox(
                height: heroHeight,
                child: _TvBrowseHeroPanel(
                  kindLabel: kindLabel,
                  title: titleFor(selected),
                  imageUrl: imageUrl(selected),
                  metaLine: metaFor(selected),
                  description: description,
                  loading: descriptionLoading,
                  isFavorite: isFavorite == null ? null : isFavorite!(selected),
                  onToggleFavorite: onToggleFavorite == null
                      ? null
                      : () => onToggleFavorite!(selected),
                  favoriteActionSelected: heroActionSelected,
                ),
              ),
              SizedBox(
                height: rowHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (onCategoryChanged != null &&
                        categoryName != null &&
                        categories.isNotEmpty &&
                        _useQuickCategoryChips(context))
                      _QuickCategoryStrip(
                        categories: categories,
                        selectedCategoryId: selectedCategoryId,
                        categoryLabel: categoryLabel,
                        onCategoryChanged: onCategoryChanged!,
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        TvUi.contentPadding,
                        8,
                        TvUi.contentPadding,
                        0,
                      ),
                      child: Text(
                        rowTitle,
                        style: const TextStyle(
                          fontSize: TvUi.sectionTitle,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                          TvUi.contentPadding,
                          10,
                          TvUi.contentPadding,
                          14,
                        ),
                        scrollDirection: Axis.horizontal,
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (_, itemIndex) {
                          final item = items[itemIndex];
                          return _EnsureVisibleWhenSelected(
                            selected: selectedIndex == itemIndex,
                            child: _TvBrowseThumbnail(
                              title: titleFor(item),
                              imageUrl: imageUrl(item),
                              selected: selectedIndex == itemIndex,
                              onTap: () => onOpen(item),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TvBrowseHeroPanel extends StatelessWidget {
  const _TvBrowseHeroPanel({
    required this.kindLabel,
    required this.title,
    required this.imageUrl,
    required this.metaLine,
    required this.description,
    required this.loading,
    this.isFavorite,
    this.onToggleFavorite,
    this.favoriteActionSelected = false,
  });

  final String kindLabel;
  final String title;
  final String imageUrl;
  final String metaLine;
  final String description;
  final bool loading;
  final bool? isFavorite;
  final VoidCallback? onToggleFavorite;
  final bool favoriteActionSelected;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          _BackdropImage(
            key: ValueKey(imageUrl),
            url: imageUrl,
            alignment: const Alignment(0.55, -0.1),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  LelegColors.bg,
                  LelegColors.bg.withValues(alpha: 0.94),
                  LelegColors.bg.withValues(alpha: 0.55),
                  Colors.transparent,
                ],
                stops: const [0, 0.34, 0.58, 0.92],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  LelegColors.bg,
                  LelegColors.bg.withValues(alpha: 0.72),
                  Colors.transparent,
                ],
                stops: const [0, 0.32, 0.72],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              TvUi.contentPadding,
              14,
              TvUi.contentPadding,
              18,
            ),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kindLabel,
                      style: TextStyle(
                        color: LelegColors.muted,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w800,
                        fontSize: TvUi.eyebrow,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: TvUi.heroTitle,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                    if (metaLine.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        metaLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: LelegColors.muted,
                          fontWeight: FontWeight.w700,
                          fontSize: TvUi.body,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    if (loading)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (description.trim().isNotEmpty)
                      Text(
                        description.trim(),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: LelegColors.fg.withValues(alpha: 0.88),
                          fontSize: TvUi.body,
                          height: 1.35,
                        ),
                      )
                    else
                      Text(
                        'Nessuna descrizione disponibile.',
                        style: TextStyle(
                          color: LelegColors.muted,
                          fontSize: TvUi.body,
                        ),
                      ),
                    if (onToggleFavorite != null) ...[
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: onToggleFavorite,
                        icon: Icon(
                          isFavorite == true ? Icons.star : Icons.star_border,
                          color: isFavorite == true ? LelegColors.accent : null,
                        ),
                        label: Text(
                          isFavorite == true
                              ? 'Nei preferiti'
                              : 'Aggiungi ai preferiti',
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: favoriteActionSelected
                                ? LelegColors.accent
                                : (isFavorite == true
                                      ? LelegColors.accent
                                      : LelegColors.line),
                            width: favoriteActionSelected ? 2 : 1,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TvBrowseThumbnail extends StatelessWidget {
  const _TvBrowseThumbnail({
    required this.title,
    required this.imageUrl,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String imageUrl;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _RemoteActivate(
      onActivate: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: TvUi.thumbnailWidth,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: selected ? Colors.white : Colors.transparent,
              width: selected ? 3 : 0,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _BackdropImage(url: imageUrl, alignment: Alignment.center),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.82),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: TvUi.font(11),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CatalogCategoryRowsScreen extends StatelessWidget {
  const CatalogCategoryRowsScreen({
    required this.title,
    required this.categories,
    required this.items,
    required this.categoryName,
    required this.onPlay,
    super.key,
  });

  final String title;
  final List<XtreamCategory> categories;
  final List<VodMovie> items;
  final String Function(String id) categoryName;
  final ValueChanged<VodMovie> onPlay;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, List<VodMovie>)>[];
    for (final category in categories.take(12)) {
      final rowItems = items
          .where((item) => item.categoryId == category.id)
          .take(16)
          .toList();
      if (rowItems.isNotEmpty) {
        rows.add((categoryName(category.id), rowItems));
      }
    }
    if (rows.isEmpty && items.isNotEmpty) {
      rows.add(('Catalogo', items.take(16).toList()));
    }
    return _PageScaffold(
      title: title,
      eyebrow: '${items.length} titoli · scorri per categoria',
      hideHeader: TvUi.isActive(context),
      child: rows.isEmpty
          ? const _EmptyState(message: 'Nessun titolo caricato.')
          : ListView.separated(
              padding: EdgeInsets.fromLTRB(
                TvUi.isActive(context) ? TvUi.contentPadding : 24,
                TvUi.isActive(context) ? 16 : 8,
                TvUi.isActive(context) ? TvUi.contentPadding : 24,
                24,
              ),
              itemCount: rows.length,
              separatorBuilder: (_, _) =>
                  SizedBox(height: TvUi.isActive(context) ? TvUi.rowGap : 24),
              itemBuilder: (_, index) {
                final row = rows[index];
                return _HomeMovieStrip(
                  title: row.$1,
                  empty: 'Nessun titolo in questa categoria.',
                  movies: row.$2,
                  onPlayMovie: onPlay,
                );
              },
            ),
    );
  }
}

class SeriesCategoryRowsScreen extends StatelessWidget {
  const SeriesCategoryRowsScreen({
    required this.title,
    required this.categories,
    required this.items,
    required this.categoryName,
    required this.onOpen,
    this.onFavorite,
    this.onDownload,
    this.favorites = const {},
    super.key,
  });

  final String title;
  final List<XtreamCategory> categories;
  final List<SeriesShow> items;
  final String Function(String id) categoryName;
  final ValueChanged<SeriesShow> onOpen;
  final ValueChanged<SeriesShow>? onFavorite;
  final ValueChanged<SeriesShow>? onDownload;
  final Set<int> favorites;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, List<SeriesShow>)>[];
    for (final category in categories.take(12)) {
      final rowItems = items
          .where((item) => item.categoryId == category.id)
          .take(16)
          .toList();
      if (rowItems.isNotEmpty) {
        rows.add((categoryName(category.id), rowItems));
      }
    }
    if (rows.isEmpty && items.isNotEmpty) {
      rows.add(('Catalogo', items.take(16).toList()));
    }
    return _PageScaffold(
      title: title,
      eyebrow: '${items.length} serie · scorri per categoria',
      hideHeader: TvUi.isActive(context),
      child: rows.isEmpty
          ? const _EmptyState(message: 'Nessuna serie caricata.')
          : ListView.separated(
              padding: EdgeInsets.fromLTRB(
                TvUi.isActive(context) ? TvUi.contentPadding : 24,
                TvUi.isActive(context) ? 16 : 8,
                TvUi.isActive(context) ? TvUi.contentPadding : 24,
                24,
              ),
              itemCount: rows.length,
              separatorBuilder: (_, _) =>
                  SizedBox(height: TvUi.isActive(context) ? TvUi.rowGap : 24),
              itemBuilder: (_, index) {
                final row = rows[index];
                final tv = TvUi.isActive(context);
                final cardHeight = tv ? (TvUi.cardWidth * 9 / 16) : 290.0;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.$1,
                      style: TextStyle(
                        fontSize: tv ? 13 : 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: tv ? 8 : 14),
                    SizedBox(
                      height: cardHeight,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: row.$2.length,
                        separatorBuilder: (_, _) =>
                            SizedBox(width: tv ? 8 : 14),
                        itemBuilder: (_, itemIndex) {
                          final show = row.$2[itemIndex];
                          if (TvUi.isActive(context)) {
                            return _TvLandscapeCard(
                              title: show.name,
                              image: show.logo,
                              onTap: () => onOpen(show),
                            );
                          }
                          return SizedBox(
                            width: tv ? TvUi.cardWidth : 190,
                            child: _SeriesPosterCard(
                              show: show,
                              category: categoryName(show.categoryId),
                              onOpen: onOpen,
                              onFavorite: onFavorite,
                              onDownload: onDownload,
                              isFavorite: favorites.contains(show.id),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class MoviesScreen extends StatelessWidget {
  const MoviesScreen({
    required this.tvSelectedIndex,
    required this.movies,
    required this.onPlay,
    required this.onFavorite,
    required this.onWatchLater,
    required this.favorites,
    required this.watchLater,
    this.movieProgress = const {},
    this.onDownload,
    this.title = 'Film',
    this.allCount,
    this.categories = const [],
    this.selectedCategoryId = '',
    this.sort = 'default',
    this.categoryName,
    this.categoryLabel,
    this.onCategoryChanged,
    this.onSortChanged,
    super.key,
  });

  final int? tvSelectedIndex;
  final String title;
  final List<VodMovie> movies;
  final int? allCount;
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final String sort;
  final String Function(String id)? categoryName;
  final String Function(String id)? categoryLabel;
  final ValueChanged<String>? onCategoryChanged;
  final ValueChanged<String>? onSortChanged;
  final ValueChanged<VodMovie> onPlay;
  final ValueChanged<VodMovie> onFavorite;
  final ValueChanged<VodMovie> onWatchLater;
  final ValueChanged<VodMovie>? onDownload;
  final Set<int> favorites;
  final Set<int> watchLater;
  final Map<int, PlaybackProgress> movieProgress;

  @override
  Widget build(BuildContext context) {
    final mobile = _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
    return _PageScaffold(
      title: title,
      eyebrow: allCount == null
          ? '${movies.length} nel catalogo'
          : '${movies.length} di $allCount nel catalogo',
      child: Column(
        children: [
          if (onCategoryChanged != null && categoryName != null)
            _CatalogToolbar(
              categories: categories,
              selectedCategoryId: selectedCategoryId,
              categoryName: categoryName!,
              categoryLabel: categoryLabel,
              onCategoryChanged: onCategoryChanged!,
              sort: sort,
              onSortChanged: onSortChanged,
            ),
          if (onCategoryChanged != null &&
              categories.isNotEmpty &&
              _useQuickCategoryChips(context))
            _QuickCategoryStrip(
              categories: categories,
              selectedCategoryId: selectedCategoryId,
              categoryLabel: categoryLabel,
              onCategoryChanged: onCategoryChanged!,
            ),
          Expanded(
            child: movies.isEmpty
                ? const _EmptyState(message: 'Nessun titolo da mostrare.')
                : GridView.builder(
                    padding: EdgeInsets.all(mobile ? 16 : 28),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: mobile ? 170 : 210,
                      mainAxisExtent: mobile ? 302 : 332,
                      crossAxisSpacing: mobile ? 12 : 18,
                      mainAxisSpacing: mobile ? 14 : 20,
                    ),
                    itemCount: movies.length,
                    itemBuilder: (_, index) {
                      final movie = movies[index];
                      return _MoviePosterCard(
                        movie: movie,
                        category: categoryName?.call(movie.categoryId),
                        watchProgress: movieProgress[movie.id],
                        onPlay: onPlay,
                        onFavorite: onFavorite,
                        onWatchLater: onWatchLater,
                        onDownload: onDownload,
                        isFavorite: favorites.contains(movie.id),
                        isWatchLater: watchLater.contains(movie.id),
                        selected: tvSelectedIndex == index,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class MovieDetailScreen extends StatelessWidget {
  const MovieDetailScreen({
    required this.movie,
    required this.description,
    required this.genre,
    required this.category,
    required this.controller,
    required this.player,
    this.appleController,
    this.tizenController,
    required this.playerTitle,
    required this.rate,
    required this.labelFor,
    required this.onBack,
    required this.onPlay,
    this.onResume,
    this.onRestart,
    this.canResume = false,
    this.watchProgress,
    this.onDownload,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.tvActionIndex,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
    super.key,
  });

  final VodMovie movie;
  final String description;
  final String genre;
  final String category;
  final VideoController? controller;
  final Player? player;
  final vp.VideoPlayerController? appleController;
  final avplay.VideoPlayerController? tizenController;
  final String playerTitle;
  final double rate;
  final String Function(dynamic value) labelFor;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final VoidCallback? onResume;
  final VoidCallback? onRestart;
  final bool canResume;
  final PlaybackProgress? watchProgress;
  final VoidCallback? onDownload;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final int? tvActionIndex;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;

  @override
  Widget build(BuildContext context) {
    final tv = TvUi.isActive(context);
    if (tv) {
      final meta = [
        if (genre.isNotEmpty) genre,
        if (category.isNotEmpty) category,
        if (movie.rating.isNotEmpty) '★ ${movie.rating}',
        movie.containerExtension.toUpperCase(),
      ].join(' · ');
      return _PageScaffold(
        title: '',
        hideHeader: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _BackdropImage(
              key: ValueKey(movie.logo),
              url: movie.logo,
              alignment: const Alignment(0.55, -0.15),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    LelegColors.bg,
                    LelegColors.bg.withValues(alpha: 0.95),
                    LelegColors.bg.withValues(alpha: 0.55),
                    Colors.transparent,
                  ],
                  stops: const [0, 0.34, 0.58, 0.92],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    LelegColors.bg,
                    LelegColors.bg.withValues(alpha: 0.72),
                    Colors.transparent,
                  ],
                  stops: const [0, 0.28, 0.68],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                TvUi.contentPadding,
                16,
                TvUi.contentPadding,
                24,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        onPressed: onBack,
                        icon: const Icon(Icons.arrow_back, size: 18),
                        label: const Text('Film'),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: tvActionIndex == (canResume ? 3 : 2)
                                ? LelegColors.accent
                                : LelegColors.line,
                            width: tvActionIndex == (canResume ? 3 : 2) ? 2 : 1,
                          ),
                        ),
                      ),
                      if (canResume &&
                          onResume != null &&
                          onRestart != null) ...[
                        FilledButton.icon(
                          onPressed: onResume,
                          icon: const Icon(Icons.play_circle_outline, size: 20),
                          label: const Text('Riprendi'),
                          style: FilledButton.styleFrom(
                            side: tvActionIndex == 0
                                ? const BorderSide(
                                    color: Colors.white,
                                    width: 2,
                                  )
                                : null,
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: onRestart,
                          icon: const Icon(Icons.restart_alt, size: 18),
                          label: const Text('Ricomincia'),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: tvActionIndex == 1
                                  ? LelegColors.accent
                                  : LelegColors.line,
                              width: tvActionIndex == 1 ? 2 : 1,
                            ),
                          ),
                        ),
                      ] else
                        FilledButton.icon(
                          onPressed: onPlay,
                          icon: const Icon(Icons.play_arrow, size: 20),
                          label: const Text('Riproduci'),
                          style: FilledButton.styleFrom(
                            side: tvActionIndex == 0
                                ? const BorderSide(
                                    color: Colors.white,
                                    width: 2,
                                  )
                                : null,
                          ),
                        ),
                      if (onToggleFavorite != null)
                        OutlinedButton.icon(
                          onPressed: onToggleFavorite,
                          icon: Icon(
                            isFavorite ? Icons.star : Icons.star_border,
                            color: isFavorite ? LelegColors.accent : null,
                          ),
                          label: Text(isFavorite ? 'Preferito' : 'Preferiti'),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: tvActionIndex == (canResume ? 2 : 1)
                                  ? LelegColors.accent
                                  : LelegColors.line,
                              width: tvActionIndex == (canResume ? 2 : 1)
                                  ? 2
                                  : 1,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    'FILM',
                    style: TextStyle(
                      color: LelegColors.muted,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w800,
                      fontSize: TvUi.eyebrow,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    movie.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TvUi.heroTitle,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: LelegColors.muted,
                        fontWeight: FontWeight.w700,
                        fontSize: TvUi.body,
                      ),
                    ),
                  ],
                  if (watchProgress != null && watchProgress!.fraction > 0) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 4,
                        value: watchProgress!.isCompleted
                            ? 1
                            : watchProgress!.fraction,
                        backgroundColor: LelegColors.line,
                        color: LelegColors.accent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      watchProgress!.isCompleted
                          ? 'Visto'
                          : '${(watchProgress!.fraction * 100).round()}% visto',
                      style: const TextStyle(
                        color: LelegColors.muted,
                        fontSize: TvUi.caption,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    description.trim().isNotEmpty
                        ? description.trim()
                        : 'Nessuna descrizione disponibile dal provider.',
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: LelegColors.fg.withValues(alpha: 0.88),
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final mobile =
        !Platform.isWindows &&
        _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
    return _PageScaffold(
      title: movie.name,
      eyebrow: [
        if (category.isNotEmpty) category,
        if (movie.rating.isNotEmpty) '★ ${movie.rating}',
        movie.containerExtension.toUpperCase(),
      ].join(' · '),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          mobile ? 16 : 28,
          8,
          mobile ? 16 : 28,
          mobile ? 18 : 28,
        ),
        child: Column(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Film'),
                ),
                FilledButton.icon(
                  onPressed: canResume && onResume != null ? onResume : onPlay,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(canResume ? 'Riprendi' : 'Play'),
                ),
                if (canResume && onResume != null && onRestart != null) ...[
                  OutlinedButton.icon(
                    onPressed: onRestart,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Ricomincia'),
                  ),
                ],
                if (onDownload != null)
                  OutlinedButton.icon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download),
                    label: const Text('Download'),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            if (watchProgress != null && watchProgress!.fraction > 0) ...[
              Padding(
                padding: EdgeInsets.symmetric(horizontal: mobile ? 0 : 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _WatchProgressBar(progress: watchProgress!),
                    const SizedBox(height: 6),
                    Text(
                      watchProgress!.isCompleted
                          ? 'Visto'
                          : '${(watchProgress!.fraction * 100).round()}% visto',
                      style: const TextStyle(
                        color: LelegColors.muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            Expanded(
              child: mobile
                  ? ListView(
                      children: [
                        SizedBox(
                          height: 280,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: _Poster(url: movie.logo),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: LelegColors.surface2,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: LelegColors.line),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _MetaBadge(
                                    icon: Icons.movie_outlined,
                                    label: genre.isNotEmpty
                                        ? genre
                                        : (category.isEmpty
                                              ? 'Film'
                                              : category),
                                  ),
                                  if (movie.rating.isNotEmpty)
                                    _MetaBadge(
                                      icon: Icons.star_outline,
                                      label: movie.rating,
                                    ),
                                  _MetaBadge(
                                    icon: Icons.video_file_outlined,
                                    label: movie.containerExtension
                                        .toUpperCase(),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              if (description.trim().isNotEmpty)
                                Text(
                                  description.trim(),
                                  style: const TextStyle(
                                    color: LelegColors.muted,
                                    fontWeight: FontWeight.w700,
                                    height: 1.45,
                                  ),
                                )
                              else
                                const Text(
                                  'Nessuna descrizione disponibile dal provider.',
                                  style: TextStyle(
                                    color: LelegColors.muted,
                                    fontWeight: FontWeight.w700,
                                    height: 1.45,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 260,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: _Poster(url: movie.logo),
                          ),
                        ),
                        const SizedBox(width: 22),
                        Expanded(
                          child: PlayerCard(
                            title: playerTitle,
                            controller: controller,
                            player: player,
                            appleController: appleController,
                            tizenController: tizenController,
                            rate: rate,
                            labelFor: labelFor,
                            onAudioChanged: onAudioChanged,
                            onSubtitleChanged: onSubtitleChanged,
                            onRateChanged: onRateChanged,
                            onToggleFocusMode: onToggleFocusMode,
                            onPictureInPicture: onPictureInPicture,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SeriesScreen extends StatelessWidget {
  const SeriesScreen({
    required this.tvSelectedIndex,
    required this.shows,
    required this.allCount,
    required this.categories,
    required this.selectedCategoryId,
    required this.sort,
    required this.categoryName,
    this.categoryLabel,
    required this.onCategoryChanged,
    required this.onSortChanged,
    required this.onOpen,
    this.seriesWatchProgress,
    this.onFavorite,
    this.onDownload,
    this.favorites = const {},
    super.key,
  });

  final int? tvSelectedIndex;
  final List<SeriesShow> shows;
  final int allCount;
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final String sort;
  final String Function(String id) categoryName;
  final String Function(String id)? categoryLabel;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<String> onSortChanged;
  final ValueChanged<SeriesShow> onOpen;
  final PlaybackProgress? Function(SeriesShow show)? seriesWatchProgress;
  final ValueChanged<SeriesShow>? onFavorite;
  final ValueChanged<SeriesShow>? onDownload;
  final Set<int> favorites;

  @override
  Widget build(BuildContext context) {
    final mobile = _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
    return _PageScaffold(
      title: 'Serie',
      eyebrow: '${shows.length} di $allCount nel catalogo',
      child: Column(
        children: [
          _CatalogToolbar(
            categories: categories,
            selectedCategoryId: selectedCategoryId,
            categoryName: categoryName,
            categoryLabel: categoryLabel,
            onCategoryChanged: onCategoryChanged,
            sort: sort,
            onSortChanged: onSortChanged,
          ),
          if (categories.isNotEmpty && _useQuickCategoryChips(context))
            _QuickCategoryStrip(
              categories: categories,
              selectedCategoryId: selectedCategoryId,
              categoryLabel: categoryLabel,
              onCategoryChanged: onCategoryChanged,
            ),
          Expanded(
            child: shows.isEmpty
                ? const _EmptyState(message: 'Nessuna serie da mostrare.')
                : GridView.builder(
                    padding: EdgeInsets.all(mobile ? 16 : 28),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: mobile ? 170 : 210,
                      mainAxisExtent: mobile ? 302 : 320,
                      crossAxisSpacing: mobile ? 12 : 18,
                      mainAxisSpacing: mobile ? 14 : 20,
                    ),
                    itemCount: shows.length,
                    itemBuilder: (_, index) => _SeriesPosterCard(
                      show: shows[index],
                      category: categoryName(shows[index].categoryId),
                      watchProgress: seriesWatchProgress?.call(shows[index]),
                      onOpen: onOpen,
                      onFavorite: onFavorite,
                      onDownload: onDownload,
                      isFavorite: favorites.contains(shows[index].id),
                      selected: tvSelectedIndex == index,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class SeriesDetailScreen extends StatelessWidget {
  const SeriesDetailScreen({
    required this.show,
    required this.description,
    required this.genre,
    required this.episodes,
    required this.loading,
    required this.controller,
    required this.player,
    this.appleController,
    this.tizenController,
    required this.playerTitle,
    required this.rate,
    required this.labelFor,
    required this.onBack,
    required this.onPlay,
    this.episodeProgress = const {},
    this.canResume = false,
    this.watchProgress,
    this.onResume,
    this.tvActionIndex,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
    super.key,
  });

  final SeriesShow show;
  final String description;
  final String genre;
  final List<SeriesEpisode> episodes;
  final bool loading;
  final VideoController? controller;
  final Player? player;
  final vp.VideoPlayerController? appleController;
  final avplay.VideoPlayerController? tizenController;
  final String playerTitle;
  final double rate;
  final String Function(dynamic value) labelFor;
  final VoidCallback onBack;
  final ValueChanged<SeriesEpisode> onPlay;
  final Map<int, PlaybackProgress> episodeProgress;
  final bool canResume;
  final PlaybackProgress? watchProgress;
  final VoidCallback? onResume;
  final int? tvActionIndex;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;

  @override
  Widget build(BuildContext context) {
    final tv = TvUi.isActive(context);
    if (tv) {
      final meta = [
        if (genre.isNotEmpty) genre,
        if (show.rating.isNotEmpty) '★ ${show.rating}',
        if (show.year.isNotEmpty) show.year,
        '${episodes.length} episodi',
      ].join(' · ');
      final episodeIndex = tvActionIndex == null || tvActionIndex! <= 0
          ? null
          : tvActionIndex! - 1;
      return _PageScaffold(
        title: '',
        hideHeader: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height:
                  MediaQuery.sizeOf(context).height * TvUi.seriesHeroFraction,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _BackdropImage(
                    key: ValueKey(show.logo),
                    url: show.logo,
                    alignment: const Alignment(0.55, -0.1),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          LelegColors.bg,
                          LelegColors.bg.withValues(alpha: 0.94),
                          LelegColors.bg.withValues(alpha: 0.5),
                          Colors.transparent,
                        ],
                        stops: const [0, 0.34, 0.58, 0.92],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      TvUi.contentPadding,
                      14,
                      TvUi.contentPadding,
                      16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        OutlinedButton.icon(
                          onPressed: onBack,
                          icon: const Icon(Icons.arrow_back, size: 18),
                          label: const Text('Serie'),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: tvActionIndex == 0
                                  ? LelegColors.accent
                                  : LelegColors.line,
                              width: tvActionIndex == 0 ? 2 : 1,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          'SERIE',
                          style: TextStyle(
                            color: LelegColors.muted,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w800,
                            fontSize: TvUi.eyebrow,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          show.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: TvUi.heroTitle,
                            fontWeight: FontWeight.w900,
                            height: 1.05,
                          ),
                        ),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: LelegColors.muted,
                              fontWeight: FontWeight.w700,
                              fontSize: TvUi.body,
                            ),
                          ),
                        ],
                        if (loading)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        else if (description.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              description.trim(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: LelegColors.fg.withValues(alpha: 0.88),
                                fontSize: 12,
                                height: 1.35,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: episodes.isEmpty
                  ? const _EmptyState(message: 'Nessun episodio caricato.')
                  : _SeriesSeasonList(
                      episodes: episodes,
                      episodeProgress: episodeProgress,
                      selectedEpisodeIndex: episodeIndex,
                      onPlay: onPlay,
                    ),
            ),
          ],
        ),
      );
    }
    final mobile =
        !Platform.isWindows &&
        _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
    return _PageScaffold(
      title: show.name,
      eyebrow: [
        if (genre.trim().isNotEmpty) genre.trim(),
        '${episodes.length} episodi',
      ].join(' · '),
      child: mobile
          ? ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                  child: Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: onBack,
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Serie'),
                      ),
                      const SizedBox(width: 12),
                      if (canResume && onResume != null)
                        FilledButton.icon(
                          onPressed: onResume,
                          icon: const Icon(Icons.play_circle_outline),
                          label: const Text('Riprendi'),
                        ),
                      if (loading)
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: LelegColors.surface2,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: LelegColors.line),
                    ),
                    child: Text(
                      description.trim().isNotEmpty
                          ? description.trim()
                          : 'Nessuna descrizione disponibile dal provider.',
                      style: const TextStyle(
                        color: LelegColors.muted,
                        fontWeight: FontWeight.w700,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                if (episodes.isEmpty)
                  const _EmptyState(message: 'Nessun episodio caricato.')
                else
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    itemCount: episodes.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, index) => _EpisodeTile(
                      episode: episodes[index],
                      progress: episodeProgress[episodes[index].id],
                      onPlay: onPlay,
                    ),
                  ),
              ],
            )
          : Row(
              children: [
                SizedBox(
                  width: Platform.isWindows ? 520 : 430,
                  child: Platform.isWindows
                      ? _WindowsSeriesDetailPane(
                          show: show,
                          description: description,
                          genre: genre,
                          episodes: episodes,
                          loading: loading,
                          canResume: canResume,
                          onResume: onResume,
                          onBack: onBack,
                          episodeProgress: episodeProgress,
                          onPlay: onPlay,
                        )
                      : Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
                              child: Row(
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: onBack,
                                    icon: const Icon(Icons.arrow_back),
                                    label: const Text('Serie'),
                                  ),
                                  const SizedBox(width: 12),
                                  if (canResume && onResume != null)
                                    FilledButton.icon(
                                      onPressed: onResume,
                                      icon: const Icon(
                                        Icons.play_circle_outline,
                                      ),
                                      label: const Text('Riprendi'),
                                    ),
                                  if (loading)
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: episodes.isEmpty
                                  ? const _EmptyState(
                                      message: 'Nessun episodio caricato.',
                                    )
                                  : ListView.separated(
                                      padding: const EdgeInsets.fromLTRB(
                                        20,
                                        0,
                                        20,
                                        20,
                                      ),
                                      itemCount: episodes.length,
                                      separatorBuilder: (_, _) =>
                                          const SizedBox(height: 8),
                                      itemBuilder: (_, index) => _EpisodeTile(
                                        episode: episodes[index],
                                        progress:
                                            episodeProgress[episodes[index].id],
                                        onPlay: onPlay,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                ),
                const VerticalDivider(width: 1, color: LelegColors.line),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: PlayerCard(
                      title: playerTitle,
                      controller: controller,
                      player: player,
                      appleController: appleController,
                      tizenController: tizenController,
                      rate: rate,
                      labelFor: labelFor,
                      onAudioChanged: onAudioChanged,
                      onSubtitleChanged: onSubtitleChanged,
                      onRateChanged: onRateChanged,
                      onToggleFocusMode: onToggleFocusMode,
                      onPictureInPicture: onPictureInPicture,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class EpgScreen extends StatelessWidget {
  const EpgScreen({
    required this.tvSelectedIndex,
    required this.selectedProgrammeIndex,
    required this.selectedProgramme,
    required this.channels,
    required this.categories,
    required this.selectedCategoryId,
    required this.selectedChannel,
    required this.selectedDayOffset,
    required this.epgByChannel,
    required this.loading,
    required this.canReplayProgramme,
    required this.onCategoryChanged,
    required this.onDayOffsetChanged,
    required this.onRefresh,
    required this.onSelectChannel,
    required this.onWatchProgramme,
    required this.onLoadChannel,
    super.key,
  });

  final int? tvSelectedIndex;
  final int? selectedProgrammeIndex;
  final EpgProgramme? selectedProgramme;
  final List<LiveChannel> channels;
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final LiveChannel? selectedChannel;
  final int selectedDayOffset;
  final Map<int, List<EpgProgramme>> epgByChannel;
  final bool loading;
  final bool Function(LiveChannel channel, EpgProgramme programme)
  canReplayProgramme;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<int> onDayOffsetChanged;
  final VoidCallback onRefresh;
  final ValueChanged<LiveChannel> onSelectChannel;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onWatchProgramme;
  final ValueChanged<LiveChannel> onLoadChannel;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      hideHeader: true,
      title: 'Guida TV',
      child: _TvGuideLayout(
        tvSelectedIndex: tvSelectedIndex,
        selectedProgrammeIndex: selectedProgrammeIndex,
        selectedProgramme: selectedProgramme,
        channels: channels,
        categories: categories,
        selectedCategoryId: selectedCategoryId,
        selectedChannel: selectedChannel,
        selectedDayOffset: selectedDayOffset,
        epgByChannel: epgByChannel,
        loading: loading,
        canReplayProgramme: canReplayProgramme,
        onCategoryChanged: onCategoryChanged,
        onDayOffsetChanged: onDayOffsetChanged,
        onRefresh: onRefresh,
        onSelectChannel: onSelectChannel,
        onWatchProgramme: onWatchProgramme,
        onLoadChannel: onLoadChannel,
      ),
    );
  }
}

class _TvGuideLayout extends StatefulWidget {
  const _TvGuideLayout({
    required this.tvSelectedIndex,
    required this.selectedProgrammeIndex,
    required this.selectedProgramme,
    required this.channels,
    required this.categories,
    required this.selectedCategoryId,
    required this.selectedChannel,
    required this.selectedDayOffset,
    required this.epgByChannel,
    required this.loading,
    required this.canReplayProgramme,
    required this.onCategoryChanged,
    required this.onDayOffsetChanged,
    required this.onRefresh,
    required this.onSelectChannel,
    required this.onWatchProgramme,
    required this.onLoadChannel,
  });

  final int? tvSelectedIndex;
  final int? selectedProgrammeIndex;
  final EpgProgramme? selectedProgramme;
  final List<LiveChannel> channels;
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final LiveChannel? selectedChannel;
  final int selectedDayOffset;
  final Map<int, List<EpgProgramme>> epgByChannel;
  final bool loading;
  final bool Function(LiveChannel channel, EpgProgramme programme)
  canReplayProgramme;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<int> onDayOffsetChanged;
  final VoidCallback onRefresh;
  final ValueChanged<LiveChannel> onSelectChannel;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onWatchProgramme;
  final ValueChanged<LiveChannel> onLoadChannel;

  @override
  State<_TvGuideLayout> createState() => _TvGuideLayoutState();
}

class _TvGuideLayoutState extends State<_TvGuideLayout> {
  final ScrollController _channelScrollController = ScrollController();
  final ScrollController _programmeScrollController = ScrollController();
  final GlobalKey _liveProgrammeKey = GlobalKey();
  Timer? _loadChannelDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToLiveProgramme(),
    );
  }

  @override
  void dispose() {
    _loadChannelDebounce?.cancel();
    _channelScrollController.dispose();
    _programmeScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _TvGuideLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    final channel = widget.selectedChannel;
    if (channel != null && oldWidget.selectedChannel?.id != channel.id) {
      _loadChannelDebounce?.cancel();
      _loadChannelDebounce = Timer(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        widget.onLoadChannel(channel);
      });
    }
    final channelChanged = oldWidget.selectedChannel?.id != channel?.id;
    final dayChanged = oldWidget.selectedDayOffset != widget.selectedDayOffset;
    final programmesChanged =
        oldWidget.epgByChannel != widget.epgByChannel ||
        oldWidget.loading != widget.loading;
    final selectionChanged =
        oldWidget.selectedProgrammeIndex != widget.selectedProgrammeIndex;
    if (channelChanged || dayChanged || programmesChanged || selectionChanged) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToLiveProgramme(),
      );
    }
    if (channel == null) return;
    if (oldWidget.selectedChannel?.id != channel.id ||
        oldWidget.tvSelectedIndex != widget.tvSelectedIndex) {
      final channelIndex = widget.channels.indexWhere(
        (item) => item.id == channel.id,
      );
      if (channelIndex >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_channelScrollController.hasClients) return;
          final offset = (channelIndex * 58.0).clamp(
            0.0,
            _channelScrollController.position.maxScrollExtent,
          );
          _channelScrollController.jumpTo(offset);
        });
      }
    }
  }

  void _scrollToLiveProgramme() {
    if (widget.selectedDayOffset != 0) return;
    final channel = widget.selectedChannel;
    if (channel == null) return;
    final programmes = _dayProgrammes(channel);
    if (programmes.isEmpty || widget.loading) return;
    if (_guideLiveProgrammeIndex(programmes, widget.selectedDayOffset) < 0) {
      return;
    }
    unawaited(_centerLiveProgramme(programmes));
  }

  Future<void> _centerLiveProgramme(List<EpgProgramme> programmes) async {
    final liveIndex = _guideLiveProgrammeIndex(
      programmes,
      widget.selectedDayOffset,
    );
    if (liveIndex < 0) return;
    await _scrollListItemToCenter(
      _programmeScrollController,
      _liveProgrammeKey,
      fallbackIndex: liveIndex,
      fallbackHasMarker: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted || widget.selectedDayOffset != 0) return;
    await _scrollListItemToCenter(
      _programmeScrollController,
      _liveProgrammeKey,
      attempts: 8,
      fallbackIndex: liveIndex,
      fallbackHasMarker: true,
    );
  }

  List<EpgProgramme> _dayProgrammes(LiveChannel channel) {
    final source = widget.epgByChannel[channel.id] ?? const [];
    final dayStart = _guideDayStart(widget.selectedDayOffset);
    final dayEnd = _guideDayEnd(dayStart);
    return _programmesForGuideDay(source, dayStart, dayEnd);
  }

  void _handleProgrammeTap(LiveChannel channel, EpgProgramme programme) {
    final now = DateTime.now();
    final end = programme.end;
    final start = programme.start;
    final isPast = end != null && !end.isAfter(now);
    final isLive =
        start != null && end != null && !start.isAfter(now) && end.isAfter(now);
    final canReplay = widget.canReplayProgramme(channel, programme);
    if (isLive || (isPast && canReplay)) {
      widget.onWatchProgramme(channel, programme);
    }
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.selectedChannel;
    final lookbackDays = _guideDefaultLookbackDays;
    final dayStart = _guideDayStart(widget.selectedDayOffset);
    final dayEnd = _guideDayEnd(dayStart);
    final channelProgrammes = channel == null
        ? const <EpgProgramme>[]
        : (widget.epgByChannel[channel.id] ?? const []);
    final dayProgrammes = channel == null
        ? const <EpgProgramme>[]
        : _programmesForGuideDay(channelProgrammes, dayStart, dayEnd);
    final liveIndex = _guideLiveProgrammeIndex(
      dayProgrammes,
      widget.selectedDayOffset,
    );
    final channelLoading =
        channel != null && channelProgrammes.isEmpty && widget.loading;
    final phoneGuide = !_isHandheldTabletDevice(MediaQuery.sizeOf(context));
    final programmeColumn = _GuideProgrammeColumn(
      controller: _programmeScrollController,
      liveProgrammeKey: _liveProgrammeKey,
      channel: channel,
      programmes: dayProgrammes,
      dayStart: dayStart,
      liveProgrammeIndex: liveIndex,
      selectedDayOffset: widget.selectedDayOffset,
      selectedProgrammeIndex: widget.selectedProgrammeIndex,
      selectedProgramme: widget.selectedProgramme,
      isLoading: channelLoading,
      canReplayProgramme: widget.canReplayProgramme,
      onProgrammeTap: _handleProgrammeTap,
      onRetry: widget.onRefresh,
    );
    final channelColumn = _GuideChannelColumn(
      controller: _channelScrollController,
      channels: widget.channels,
      selectedChannel: channel,
      selectedIndex: widget.tvSelectedIndex,
      onSelect: widget.onSelectChannel,
      compact: phoneGuide,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        phoneGuide ? 12 : 20,
        phoneGuide ? 12 : 18,
        phoneGuide ? 12 : 24,
        16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Guida TV',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
              ),
              const SizedBox(width: 12),
              Text(
                '${widget.channels.length} canali',
                style: const TextStyle(color: LelegColors.muted, fontSize: 14),
              ),
              const Spacer(),
              if (widget.loading)
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Caricamento programmi...',
                      style: TextStyle(color: LelegColors.accent, fontSize: 13),
                    ),
                  ],
                )
              else
                TextButton.icon(
                  onPressed: widget.onRefresh,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Aggiorna'),
                ),
            ],
          ),
          if (widget.categories.isNotEmpty) ...[
            _CatalogToolbar(
              categories: widget.categories,
              selectedCategoryId: widget.selectedCategoryId,
              categoryName: (id) {
                if (id.isEmpty) return 'Tutte le categorie';
                for (final category in widget.categories) {
                  if (category.id == id) return category.name;
                }
                return 'Categoria $id';
              },
              onCategoryChanged: widget.onCategoryChanged,
              narrow: phoneGuide,
            ),
          ],
          const SizedBox(height: 8),
          _GuideDayStrip(
            lookbackDays: lookbackDays,
            selectedDayOffset: widget.selectedDayOffset,
            onSelect: widget.onDayOffsetChanged,
          ),
          const SizedBox(height: 14),
          Expanded(
            child: widget.channels.isEmpty
                ? const _EmptyState(message: 'Nessun canale caricato.')
                : phoneGuide
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: 148, child: channelColumn),
                      const SizedBox(height: 10),
                      Expanded(child: programmeColumn),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: _guideChannelColumnWidth,
                        child: channelColumn,
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: programmeColumn),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _GuideDayStrip extends StatelessWidget {
  const _GuideDayStrip({
    required this.lookbackDays,
    required this.selectedDayOffset,
    required this.onSelect,
  });

  final int lookbackDays;
  final int selectedDayOffset;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final offsets = [
      for (var offset = -lookbackDays; offset <= 1; offset++) offset,
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: LelegColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: LelegColors.line),
      ),
      child: SizedBox(
        height: 58,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          scrollDirection: Axis.horizontal,
          itemCount: offsets.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final offset = offsets[index];
            final selected = offset == selectedDayOffset;
            final width = offset >= -1 && offset <= 1 ? 96.0 : 78.0;
            return SizedBox(
              width: width,
              child: _CategoryChipButton(
                label: _formatGuideDayTab(offset),
                selected: selected,
                onTap: () => onSelect(offset),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _GuideChannelColumn extends StatelessWidget {
  const _GuideChannelColumn({
    required this.controller,
    required this.channels,
    required this.selectedChannel,
    required this.selectedIndex,
    required this.onSelect,
    this.compact = false,
  });

  final ScrollController controller;
  final List<LiveChannel> channels;
  final LiveChannel? selectedChannel;
  final int? selectedIndex;
  final ValueChanged<LiveChannel> onSelect;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: channels.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final channel = channels[index];
          final selected = selectedChannel?.id == channel.id;
          final highlighted = selectedIndex == index;
          return SizedBox(
            width: 168,
            child: Material(
              color: selected || highlighted
                  ? LelegColors.accent.withValues(alpha: 0.14)
                  : LelegColors.surface,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onSelect(channel),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: selected || highlighted
                          ? LelegColors.accent
                          : LelegColors.line,
                      width: selected || highlighted ? 1.5 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _GuideChannelLogo(channel: channel, compact: true),
                      const SizedBox(height: 8),
                      Text(
                        channel.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: selected || highlighted
                              ? LelegColors.fg
                              : LelegColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: LelegColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: LelegColors.line),
      ),
      child: ListView.separated(
        controller: controller,
        padding: const EdgeInsets.all(8),
        itemCount: channels.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final channel = channels[index];
          final selected = selectedChannel?.id == channel.id;
          final highlighted = selectedIndex == index;
          return Material(
            color: selected || highlighted
                ? LelegColors.accent.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onSelect(channel),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected || highlighted
                        ? LelegColors.accent.withValues(alpha: 0.75)
                        : Colors.transparent,
                    width: selected || highlighted ? 1.5 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    _GuideChannelLogo(channel: channel, compact: true),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        channel.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: selected || highlighted
                              ? LelegColors.fg
                              : LelegColors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GuideProgrammeColumn extends StatelessWidget {
  const _GuideProgrammeColumn({
    required this.controller,
    required this.liveProgrammeKey,
    required this.channel,
    required this.programmes,
    required this.dayStart,
    required this.liveProgrammeIndex,
    required this.selectedDayOffset,
    required this.selectedProgrammeIndex,
    required this.selectedProgramme,
    required this.isLoading,
    required this.canReplayProgramme,
    required this.onProgrammeTap,
    required this.onRetry,
  });

  final ScrollController controller;
  final GlobalKey liveProgrammeKey;
  final LiveChannel? channel;
  final List<EpgProgramme> programmes;
  final DateTime dayStart;
  final int liveProgrammeIndex;
  final int selectedDayOffset;
  final int? selectedProgrammeIndex;
  final EpgProgramme? selectedProgramme;
  final bool isLoading;
  final bool Function(LiveChannel channel, EpgProgramme programme)
  canReplayProgramme;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onProgrammeTap;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (channel == null) {
      return const Center(
        child: Text(
          'Seleziona un canale',
          style: TextStyle(color: LelegColors.muted, fontSize: 16),
        ),
      );
    }
    final activeChannel = channel!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    activeChannel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    _formatGuideDayLabel(dayStart),
                    style: const TextStyle(
                      color: LelegColors.accent,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '${programmes.length} programmi',
              style: const TextStyle(color: LelegColors.muted, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: isLoading && programmes.isEmpty
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : programmes.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Nessun programma per ${_formatGuideDayLabel(dayStart)}',
                        style: const TextStyle(
                          color: LelegColors.muted,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton(
                        onPressed: onRetry,
                        child: const Text('Riprova'),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: programmes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final programme = programmes[index];
                    final isCurrentLive =
                        selectedDayOffset == 0 &&
                        liveProgrammeIndex >= 0 &&
                        index == liveProgrammeIndex;
                    final selected =
                        selectedProgrammeIndex != null &&
                        selectedProgrammeIndex == index;
                    return Column(
                      children: [
                        if (isCurrentLive) const _GuideLiveMarker(),
                        KeyedSubtree(
                          key: isCurrentLive ? liveProgrammeKey : null,
                          child: _GuideProgrammeCard(
                            channel: activeChannel,
                            programme: programme,
                            selected: selected || isCurrentLive,
                            isCurrentLive: isCurrentLive,
                            canReplay: canReplayProgramme(
                              activeChannel,
                              programme,
                            ),
                            onTap: () =>
                                onProgrammeTap(activeChannel, programme),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _GuideLiveMarker extends StatelessWidget {
  const _GuideLiveMarker();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Expanded(child: Divider(color: LelegColors.line, height: 1)),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              '▶  IN ONDA ADESSO',
              style: TextStyle(
                color: LelegColors.accent,
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.4,
              ),
            ),
          ),
          const Expanded(child: Divider(color: LelegColors.line, height: 1)),
        ],
      ),
    );
  }
}

class _GuideProgrammeCard extends StatelessWidget {
  const _GuideProgrammeCard({
    required this.channel,
    required this.programme,
    required this.selected,
    required this.isCurrentLive,
    required this.canReplay,
    required this.onTap,
  });

  final LiveChannel channel;
  final EpgProgramme programme;
  final bool selected;
  final bool isCurrentLive;
  final bool canReplay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    final isPast = end != null && !end.isAfter(now);
    final durationMin = start != null && end != null
        ? end.difference(start).inMinutes.clamp(1, 9999)
        : 0;
    final eyebrow = StringBuffer()
      ..write(_formatGuideClock(start))
      ..write(' - ')
      ..write(_formatGuideClock(end));
    if (isCurrentLive) {
      eyebrow.write('  •  LIVE');
    } else if (isPast && canReplay) {
      eyebrow.write('  •  ARCHIVIO');
    } else if (isPast) {
      eyebrow.write('  •  TERMINATO');
    }

    return Material(
      color: isCurrentLive
          ? LelegColors.accent.withValues(alpha: 0.12)
          : LelegColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: (isCurrentLive || canReplay) ? onTap : null,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected || isCurrentLive
                  ? LelegColors.accent.withValues(alpha: 0.85)
                  : LelegColors.line,
              width: selected || isCurrentLive ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _GuideChannelLogo(channel: channel),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      eyebrow.toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrentLive || canReplay
                            ? LelegColors.accent
                            : LelegColors.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      programme.title.trim().isEmpty
                          ? 'Programma senza titolo'
                          : programme.title.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (programme.description.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        programme.description.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LelegColors.muted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    if (isCurrentLive) ...[
                      const SizedBox(height: 8),
                      Builder(
                        builder: (context) {
                          final fraction = _liveProgrammeFraction(programme);
                          if (fraction == null) return const SizedBox.shrink();
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              minHeight: 4,
                              value: fraction,
                              backgroundColor: LelegColors.line,
                              color: LelegColors.accent,
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: LelegColors.surface2,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: LelegColors.line),
                ),
                child: Text(
                  '$durationMin min',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: LelegColors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuideChannelLogo extends StatelessWidget {
  const _GuideChannelLogo({required this.channel, this.compact = false});

  final LiveChannel channel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final logo = channel.logo.trim();
    final width = compact ? 44.0 : 72.0;
    final height = compact ? 30.0 : 48.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 6 : 8),
      child: Container(
        width: width,
        height: height,
        color: LelegColors.surface2,
        child: logo.isEmpty
            ? Icon(
                Icons.live_tv,
                color: LelegColors.muted,
                size: compact ? 16 : 22,
              )
            : Image.network(
                logo,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.live_tv,
                  color: LelegColors.muted,
                  size: compact ? 16 : 22,
                ),
              ),
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    required this.tvSelectedIndex,
    required this.profiles,
    required this.activeProfile,
    required this.titleController,
    required this.serverController,
    required this.userController,
    required this.passController,
    required this.titleFocusNode,
    required this.serverFocusNode,
    required this.userFocusNode,
    required this.passFocusNode,
    required this.liveCount,
    required this.movieCount,
    required this.seriesCount,
    required this.favoriteCount,
    required this.watchLaterCount,
    required this.onSave,
    required this.onReload,
    required this.onSelectProfile,
    required this.onDeleteProfile,
    super.key,
  });

  final int? tvSelectedIndex;
  final List<XtreamProfile> profiles;
  final XtreamProfile? activeProfile;
  final TextEditingController titleController;
  final TextEditingController serverController;
  final TextEditingController userController;
  final TextEditingController passController;
  final FocusNode titleFocusNode;
  final FocusNode serverFocusNode;
  final FocusNode userFocusNode;
  final FocusNode passFocusNode;
  final int liveCount;
  final int movieCount;
  final int seriesCount;
  final int favoriteCount;
  final int watchLaterCount;
  final VoidCallback onSave;
  final VoidCallback onReload;
  final ValueChanged<XtreamProfile> onSelectProfile;
  final ValueChanged<XtreamProfile> onDeleteProfile;

  @override
  Widget build(BuildContext context) {
    final tv = TvUi.isActive(context);
    final mobile = !tv && _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
    final titleSelected = tvSelectedIndex == profiles.length;
    final serverSelected = tvSelectedIndex == profiles.length + 1;
    final userSelected = tvSelectedIndex == profiles.length + 2;
    final passSelected = tvSelectedIndex == profiles.length + 3;
    final saveSelected = tvSelectedIndex == profiles.length + 4;
    final reloadSelected = tvSelectedIndex == profiles.length + 5;

    InputDecoration settingsFieldDecoration({
      required String label,
      required bool selected,
      String? hint,
    }) {
      final borderRadius = BorderRadius.circular(tv ? 10 : 14);
      return InputDecoration(
        isDense: tv,
        labelText: label,
        hintText: hint,
        labelStyle: tv ? const TextStyle(fontSize: TvUi.body) : null,
        hintStyle: tv ? const TextStyle(fontSize: TvUi.caption) : null,
        contentPadding: tv
            ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
            : null,
        enabledBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: BorderSide(
            color: selected ? LelegColors.accent : LelegColors.line,
            width: selected ? 2 : 1,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: borderRadius,
          borderSide: const BorderSide(color: LelegColors.accent, width: 2),
        ),
      );
    }

    final libraryBand = _SettingsBand(
      title: 'Stato libreria',
      compact: tv,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: tv ? 8 : 12,
            runSpacing: tv ? 8 : 12,
            children: [
              _MetricPill(
                label: 'Live TV',
                value: liveCount.toString(),
                compact: tv,
              ),
              _MetricPill(
                label: 'Film',
                value: movieCount.toString(),
                compact: tv,
              ),
              _MetricPill(
                label: 'Serie',
                value: seriesCount.toString(),
                compact: tv,
              ),
              _MetricPill(
                label: 'Preferiti',
                value: favoriteCount.toString(),
                compact: tv,
              ),
              _MetricPill(
                label: 'Da vedere',
                value: watchLaterCount.toString(),
                compact: tv,
              ),
              _MetricPill(label: 'Cache', value: '24h', compact: tv),
              if (!tv)
                const _MetricPill(
                  label: 'Player',
                  value: 'media_kit',
                  compact: true,
                ),
            ],
          ),
          if (tv && activeProfile != null) ...[
            const SizedBox(height: 10),
            _EnsureVisibleWhenSelected(
              selected: reloadSelected,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  minimumSize: const Size(0, 32),
                  textStyle: const TextStyle(
                    fontSize: TvUi.body,
                    fontWeight: FontWeight.w700,
                  ),
                  side: BorderSide(
                    color: reloadSelected
                        ? LelegColors.accent
                        : LelegColors.line,
                    width: reloadSelected ? 2 : 1,
                  ),
                ),
                onPressed: onReload,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Ricarica dal provider'),
              ),
            ),
            const Text(
              'Forza un nuovo download della lista attiva (ignora cache 24h).',
              style: TextStyle(
                color: LelegColors.muted,
                fontSize: TvUi.caption,
              ),
            ),
          ],
        ],
      ),
    );

    final fieldGap = tv ? 8.0 : 12.0;
    final formBand = _SettingsBand(
      title: 'Nuova lista IPTV',
      compact: tv,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (profiles.isNotEmpty) ...[
            ...profiles.map(
              (profile) => _ProfileTile(
                profile: profile,
                active: activeProfile?.id == profile.id,
                selected:
                    tvSelectedIndex != null &&
                    profiles.indexOf(profile) == tvSelectedIndex,
                compact: tv,
                onSelect: () => onSelectProfile(profile),
                onDelete: () => onDeleteProfile(profile),
                onReload: activeProfile?.id == profile.id ? onReload : null,
              ),
            ),
            SizedBox(height: tv ? 10 : 18),
          ] else
            _InlineNotice(
              text: tv
                  ? 'Nessuna lista salvata. Compila i campi sotto e premi Salva e carica.'
                  : 'Nessuna lista salvata. Inserisci un profilo Xtream e premi Salva e carica.',
            ),
          _EnsureVisibleWhenSelected(
            selected: titleSelected,
            child: TextField(
              focusNode: titleFocusNode,
              controller: titleController,
              style: tv ? const TextStyle(fontSize: TvUi.body) : null,
              decoration: settingsFieldDecoration(
                label: 'Nome lista',
                selected: titleSelected,
                hint: tv
                    ? 'Es. Casa, Sport…'
                    : 'Es. Casa, Sport, Provider principale',
              ),
              onSubmitted: (_) => onSave(),
            ),
          ),
          SizedBox(height: fieldGap),
          _EnsureVisibleWhenSelected(
            selected: serverSelected,
            child: TextField(
              focusNode: serverFocusNode,
              controller: serverController,
              style: tv ? const TextStyle(fontSize: TvUi.body) : null,
              decoration: settingsFieldDecoration(
                label: 'Server URL',
                selected: serverSelected,
              ),
              onSubmitted: (_) => onSave(),
            ),
          ),
          SizedBox(height: fieldGap),
          _EnsureVisibleWhenSelected(
            selected: userSelected,
            child: TextField(
              focusNode: userFocusNode,
              controller: userController,
              style: tv ? const TextStyle(fontSize: TvUi.body) : null,
              decoration: settingsFieldDecoration(
                label: 'Username',
                selected: userSelected,
              ),
              onSubmitted: (_) => onSave(),
            ),
          ),
          SizedBox(height: fieldGap),
          _EnsureVisibleWhenSelected(
            selected: passSelected,
            child: TextField(
              focusNode: passFocusNode,
              controller: passController,
              style: tv ? const TextStyle(fontSize: TvUi.body) : null,
              decoration: settingsFieldDecoration(
                label: 'Password',
                selected: passSelected,
              ),
              obscureText: true,
              onSubmitted: (_) => onSave(),
            ),
          ),
          SizedBox(height: tv ? 10 : 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _EnsureVisibleWhenSelected(
                selected: saveSelected,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: tv
                        ? const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          )
                        : null,
                    minimumSize: tv ? const Size(0, 32) : null,
                    textStyle: tv
                        ? const TextStyle(
                            fontSize: TvUi.body,
                            fontWeight: FontWeight.w700,
                          )
                        : null,
                    side: saveSelected
                        ? const BorderSide(color: LelegColors.fg, width: 2)
                        : null,
                  ),
                  onPressed: onSave,
                  icon: Icon(Icons.cloud_sync, size: tv ? 16 : 24),
                  label: const Text('Salva e carica'),
                ),
              ),
              _EnsureVisibleWhenSelected(
                selected: reloadSelected,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: tv
                        ? const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          )
                        : null,
                    minimumSize: tv ? const Size(0, 32) : null,
                    textStyle: tv
                        ? const TextStyle(
                            fontSize: TvUi.body,
                            fontWeight: FontWeight.w700,
                          )
                        : null,
                    side: BorderSide(
                      color: reloadSelected
                          ? LelegColors.accent
                          : LelegColors.line,
                      width: reloadSelected ? 2 : 1,
                    ),
                  ),
                  onPressed: onReload,
                  icon: Icon(Icons.refresh, size: tv ? 16 : 24),
                  label: Text(tv ? 'Ricarica' : 'Ricarica dal provider'),
                ),
              ),
            ],
          ),
          SizedBox(height: tv ? 6 : 10),
          Text(
            tv
                ? 'Cache catalogo 24h. Ricarica forza un nuovo download.'
                : 'Il catalogo viene riusato dalla cache per 24 ore. Ricarica dal provider forza un nuovo download.',
            style: TextStyle(
              color: LelegColors.muted,
              fontSize: tv ? TvUi.caption : 12,
            ),
          ),
        ],
      ),
    );

    if (tv) {
      return _PageScaffold(
        title: '',
        hideHeader: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            TvUi.contentPadding,
            8,
            TvUi.contentPadding,
            20,
          ),
          children: [
            libraryBand,
            const SizedBox(height: TvUi.rowGap),
            formBand,
            const SizedBox(height: TvUi.rowGap),
            const _SettingsAppVersion(),
          ],
        ),
      );
    }

    return _PageScaffold(
      title: 'Impostazioni',
      eyebrow: 'Provider',
      child: ListView(
        padding: EdgeInsets.all(mobile ? 16 : 28),
        children: [
          formBand,
          const SizedBox(height: 18),
          libraryBand,
          const SizedBox(height: 18),
          const _SettingsAppVersion(),
        ],
      ),
    );
  }
}

class _SettingsAppVersion extends StatelessWidget {
  const _SettingsAppVersion();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: PackageInfo.fromPlatform(),
      builder: (context, snapshot) {
        final info = snapshot.data;
        final label = info == null
            ? 'Versione app: …'
            : 'Versione app: ${info.version} (${info.buildNumber})'
                  ' · build ${_buildId.length > 10 ? _buildId.substring(0, 10) : _buildId}';
        return Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: LelegColors.muted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        );
      },
    );
  }
}

enum DownloadStatus { queued, downloading, completed, failed }

class DownloadTask {
  const DownloadTask({
    required this.movie,
    this.status = DownloadStatus.queued,
    this.progress = 0,
    this.filePath,
    this.error,
  });

  final VodMovie movie;
  final DownloadStatus status;
  final double progress;
  final String? filePath;
  final String? error;

  DownloadTask copyWith({
    DownloadStatus? status,
    double? progress,
    String? filePath,
    String? error,
  }) {
    return DownloadTask(
      movie: movie,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      filePath: filePath ?? this.filePath,
      error: error,
    );
  }
}

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({
    required this.tvSelectedIndex,
    required this.movies,
    required this.downloads,
    required this.onPlay,
    required this.onFavorite,
    required this.onWatchLater,
    required this.onDownload,
    required this.onOpenDownloadedFile,
    required this.favorites,
    required this.watchLater,
    super.key,
  });

  final int? tvSelectedIndex;
  final List<VodMovie> movies;
  final Map<int, DownloadTask> downloads;
  final ValueChanged<VodMovie> onPlay;
  final ValueChanged<VodMovie> onFavorite;
  final ValueChanged<VodMovie> onWatchLater;
  final ValueChanged<VodMovie> onDownload;
  final ValueChanged<DownloadTask> onOpenDownloadedFile;
  final Set<int> favorites;
  final Set<int> watchLater;

  @override
  Widget build(BuildContext context) {
    final mobile = _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
    return _PageScaffold(
      title: 'Download',
      eyebrow: 'Offline',
      child: ListView(
        padding: EdgeInsets.all(mobile ? 16 : 28),
        children: [
          _SettingsBand(
            title: 'Download offline',
            child: downloads.isEmpty
                ? const _InlineNotice(
                    text:
                        'Nessun download ancora avviato. Usa il pulsante Download su un film o da questa pagina.',
                  )
                : Column(
                    children: [
                      for (final task in downloads.values) ...[
                        _DownloadTaskTile(
                          task: task,
                          onOpen: () => onOpenDownloadedFile(task),
                        ),
                        if (task != downloads.values.last)
                          const SizedBox(height: 10),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 22),
          Text(
            'Pronti da scaricare',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          if (movies.isEmpty)
            const _EmptyState(
              message: 'Aggiungi film a Da vedere per prepararli al download.',
              icon: Icons.download_outlined,
            )
          else
            GridView.builder(
              itemCount: movies.length,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: mobile ? 170 : 210,
                mainAxisExtent: mobile ? 288 : 332,
                crossAxisSpacing: mobile ? 12 : 18,
                mainAxisSpacing: mobile ? 14 : 20,
              ),
              itemBuilder: (_, index) {
                final movie = movies[index];
                return _MoviePosterCard(
                  movie: movie,
                  onPlay: onPlay,
                  onFavorite: onFavorite,
                  onWatchLater: onWatchLater,
                  onDownload: onDownload,
                  isFavorite: favorites.contains(movie.id),
                  isWatchLater: watchLater.contains(movie.id),
                  selected: tvSelectedIndex == index,
                );
              },
            ),
        ],
      ),
    );
  }
}

class _DownloadTaskTile extends StatelessWidget {
  const _DownloadTaskTile({required this.task, required this.onOpen});

  final DownloadTask task;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final completed = task.status == DownloadStatus.completed;
    final failed = task.status == DownloadStatus.failed;
    final subtitle = switch (task.status) {
      DownloadStatus.queued => 'In coda',
      DownloadStatus.downloading =>
        task.progress <= 0
            ? 'Scaricamento in corso...'
            : '${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%',
      DownloadStatus.completed => task.filePath ?? 'Completato',
      DownloadStatus.failed => task.error ?? 'Errore download',
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: LelegColors.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: failed ? Colors.redAccent : LelegColors.line),
      ),
      child: Row(
        children: [
          _Logo(url: task.movie.logo, fallback: Icons.movie),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.movie.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: failed ? Colors.redAccent : LelegColors.muted,
                    fontSize: 12,
                  ),
                ),
                if (task.status == DownloadStatus.downloading) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: task.progress <= 0
                        ? null
                        : task.progress.clamp(0, 1),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: completed ? onOpen : null,
            icon: const Icon(Icons.folder_open),
            label: const Text('Apri'),
          ),
        ],
      ),
    );
  }
}

class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    required this.title,
    required this.message,
    required this.icon,
    super.key,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: title,
      eyebrow: 'In porting',
      child: _EmptyState(message: message, icon: icon),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.active,
    required this.selected,
    required this.onSelect,
    required this.onDelete,
    this.onReload,
    this.compact = false,
  });

  final XtreamProfile profile;
  final bool active;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onDelete;
  final VoidCallback? onReload;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _EnsureVisibleWhenSelected(
      selected: selected,
      child: Container(
        margin: EdgeInsets.only(bottom: compact ? 6 : 10),
        padding: EdgeInsets.all(compact ? 10 : 14),
        decoration: BoxDecoration(
          color: active || selected ? LelegColors.surface3 : LelegColors.bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? LelegColors.accent
                : active
                ? LelegColors.accent.withValues(alpha: 0.55)
                : LelegColors.line,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              active ? Icons.check_circle : Icons.playlist_play,
              size: compact ? 18 : 24,
              color: active || selected
                  ? LelegColors.accent
                  : LelegColors.muted,
            ),
            SizedBox(width: compact ? 8 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: compact ? TvUi.body : null,
                    ),
                  ),
                  Text(
                    '${profile.baseUrl.replaceFirst(RegExp(r'^https?://'), '')} · ${profile.username}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: LelegColors.muted,
                      fontSize: compact ? TvUi.caption : null,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: compact ? 6 : 10),
            OutlinedButton(
              style: compact
                  ? OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      minimumSize: const Size(0, 28),
                      textStyle: const TextStyle(fontSize: TvUi.caption),
                    )
                  : null,
              onPressed: active ? null : onSelect,
              child: Text(active ? 'Attiva' : 'Usa'),
            ),
            if (active && compact) ...[
              const SizedBox(width: 4),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  minimumSize: const Size(0, 28),
                  textStyle: const TextStyle(fontSize: TvUi.caption),
                ),
                onPressed: onReload,
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Ricarica'),
              ),
            ],
            SizedBox(width: compact ? 4 : 8),
            IconButton(
              onPressed: onDelete,
              tooltip: 'Rimuovi lista',
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: LelegColors.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LelegColors.line),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: LelegColors.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: const TextStyle(color: LelegColors.muted)),
          ),
        ],
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
    required this.label,
    required this.value,
    this.compact = false,
  });

  final String label;
  final String value;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 8 : 12,
      ),
      decoration: BoxDecoration(
        color: LelegColors.bg,
        borderRadius: BorderRadius.circular(compact ? 10 : 14),
        border: Border.all(color: LelegColors.line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              color: LelegColors.accent,
              fontSize: compact ? 14 : 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: compact ? 1 : 2),
          Text(
            label,
            style: TextStyle(
              color: LelegColors.muted,
              fontSize: compact ? TvUi.caption : 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaBadge extends StatelessWidget {
  const _MetaBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: LelegColors.bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: LelegColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: LelegColors.accent),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: LelegColors.fg,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _PageScaffold extends StatelessWidget {
  const _PageScaffold({
    required this.title,
    required this.child,
    this.eyebrow,
    this.hideHeader = false,
  });

  final String title;
  final String? eyebrow;
  final Widget child;
  final bool hideHeader;

  @override
  Widget build(BuildContext context) {
    final tv = TvUi.isActive(context);
    final mobile = MediaQuery.sizeOf(context).width < 760;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tv ? LelegColors.bg : null,
        gradient: tv
            ? null
            : const RadialGradient(
                center: Alignment.topLeft,
                radius: 1.1,
                colors: [Color(0xFF0D2A34), LelegColors.bg],
              ),
      ),
      child: hideHeader
          ? child
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    tv ? TvUi.contentPadding : (mobile ? 16 : 28),
                    tv ? 8 : (mobile ? 14 : 24),
                    tv ? TvUi.contentPadding : (mobile ? 16 : 28),
                    tv ? 2 : (mobile ? 8 : 10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (eyebrow != null)
                        Text(
                          eyebrow!.toUpperCase(),
                          style: TextStyle(
                            color: LelegColors.muted,
                            letterSpacing: tv ? 1.1 : 2,
                            fontWeight: FontWeight.w800,
                            fontSize: tv ? TvUi.eyebrow : null,
                          ),
                        ),
                      if (eyebrow != null) SizedBox(height: tv ? 3 : 6),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: tv ? TvUi.sectionTitle : (mobile ? 38 : 54),
                          fontWeight: FontWeight.w900,
                          height: 0.95,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
    );
  }
}

class _LoadingBand extends StatelessWidget {
  const _LoadingBand({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: LelegColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: LelegColors.accent.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class PlayerCard extends StatefulWidget {
  const PlayerCard({
    required this.title,
    required this.controller,
    required this.player,
    this.appleController,
    this.tizenController,
    required this.rate,
    required this.labelFor,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
    this.focusMode = false,
    this.pinControlsOnFocus = false,
    this.onControlsVisibilityChanged,
    super.key,
  });

  final String title;
  final VideoController? controller;
  final Player? player;
  final vp.VideoPlayerController? appleController;
  final avplay.VideoPlayerController? tizenController;
  final double rate;
  final String Function(dynamic value) labelFor;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;
  final bool focusMode;
  final bool pinControlsOnFocus;
  final ValueChanged<bool>? onControlsVisibilityChanged;

  @override
  State<PlayerCard> createState() => _PlayerCardState();
}

class _PlayerCardState extends State<PlayerCard> {
  bool _showControls = false;
  Timer? _hideControlsTimer;

  bool get _pinControlsInFocusMode =>
      widget.focusMode && widget.pinControlsOnFocus;

  @override
  void didUpdateWidget(PlayerCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusMode &&
        !oldWidget.focusMode &&
        !widget.pinControlsOnFocus) {
      _revealControls();
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    super.dispose();
  }

  void _revealControls() {
    _hideControlsTimer?.cancel();
    if (!_showControls && mounted) {
      setState(() => _showControls = true);
    }
    widget.onControlsVisibilityChanged?.call(true);
    _hideControlsTimer = Timer(
      Duration(
        milliseconds: widget.focusMode && !widget.pinControlsOnFocus
            ? 3000
            : 1100,
      ),
      () {
        if (mounted && !_pinControlsInFocusMode) {
          setState(() => _showControls = false);
          widget.onControlsVisibilityChanged?.call(false);
        }
      },
    );
  }

  void _hideControls() {
    _hideControlsTimer?.cancel();
    if (mounted && !_pinControlsInFocusMode) {
      setState(() => _showControls = false);
      widget.onControlsVisibilityChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tizenController = widget.tizenController;
    final appleController = widget.appleController;
    final mediaController = widget.controller;
    final mediaPlayer = widget.player;
    final controlsVisible = _showControls || _pinControlsInFocusMode;
    final playerBody = ColoredBox(
      color: Colors.black,
      child: Column(
        children: [
          if (!widget.focusMode)
            Container(
              height: 54,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              color: LelegColors.surface,
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: tizenController != null
                      ? _TizenVideoSurface(controller: tizenController)
                      : appleController != null
                      ? _AppleVideoSurface(controller: appleController)
                      : mediaController == null
                      ? const Center(
                          child: Text(
                            'Player non inizializzato',
                            style: TextStyle(color: LelegColors.muted),
                          ),
                        )
                      : Video(
                          key: _lelegMediaKitVideoSurfaceKey,
                          controller: mediaController,
                          controls: NoVideoControls,
                          fit: BoxFit.contain,
                          fill: Colors.black,
                        ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedOpacity(
                    opacity: controlsVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: IgnorePointer(
                      ignoring: !controlsVisible,
                      child: tizenController != null
                          ? _TizenTimelineControls(
                              controller: tizenController,
                              rate: widget.rate,
                              onRateChanged: widget.onRateChanged,
                              focusMode: widget.focusMode,
                              onToggleFocusMode: widget.onToggleFocusMode,
                              onPictureInPicture: widget.onPictureInPicture,
                            )
                          : appleController != null
                          ? _AppleTimelineControls(
                              controller: appleController,
                              rate: widget.rate,
                              onRateChanged: widget.onRateChanged,
                              focusMode: widget.focusMode,
                              onToggleFocusMode: widget.onToggleFocusMode,
                              onPictureInPicture: widget.onPictureInPicture,
                            )
                          : mediaPlayer == null
                          ? const SizedBox.shrink()
                          : _PlayerTimelineControls(
                              player: mediaPlayer,
                              rate: widget.rate,
                              labelFor: widget.labelFor,
                              onAudioChanged: widget.onAudioChanged,
                              onSubtitleChanged: widget.onSubtitleChanged,
                              onRateChanged: widget.onRateChanged,
                              focusMode: widget.focusMode,
                              onToggleFocusMode: widget.onToggleFocusMode,
                              onPictureInPicture: widget.onPictureInPicture,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.focusMode ? _revealControls : widget.onToggleFocusMode,
      onDoubleTap: widget.onToggleFocusMode,
      child: MouseRegion(
        onEnter: (_) => _revealControls(),
        onHover: widget.focusMode && !widget.pinControlsOnFocus
            ? null
            : (_) => _revealControls(),
        onExit: (_) => _hideControls(),
        child: widget.focusMode
            ? playerBody
            : ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: playerBody,
              ),
      ),
    );
  }
}

class _TizenVideoSurface extends StatelessWidget {
  const _TizenVideoSurface({required this.controller});

  final avplay.VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<avplay.VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (value.hasError) {
          return Center(
            child: Text(
              value.errorDescription ?? 'Video non riproducibile',
              textAlign: TextAlign.center,
              style: const TextStyle(color: LelegColors.muted),
            ),
          );
        }
        if (!value.isInitialized) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final aspectRatio = value.aspectRatio <= 0 ? 16 / 9 : value.aspectRatio;
        return Center(
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                avplay.VideoPlayer(controller),
                avplay.ClosedCaption(captions: value.captions),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AppleVideoSurface extends StatelessWidget {
  const _AppleVideoSurface({required this.controller});

  final vp.VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<vp.VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (value.hasError) {
          return Center(
            child: Text(
              value.errorDescription ?? 'Video non riproducibile',
              textAlign: TextAlign.center,
              style: const TextStyle(color: LelegColors.muted),
            ),
          );
        }
        if (!value.isInitialized) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final aspectRatio = value.aspectRatio <= 0 ? 16 / 9 : value.aspectRatio;
        return Center(
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: vp.VideoPlayer(controller),
          ),
        );
      },
    );
  }
}

class _AppleTimelineControls extends StatelessWidget {
  const _AppleTimelineControls({
    required this.controller,
    required this.rate,
    required this.onRateChanged,
    required this.focusMode,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
  });

  final vp.VideoPlayerController controller;
  final double rate;
  final ValueChanged<double> onRateChanged;
  final bool focusMode;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.74),
        border: const Border(top: BorderSide(color: LelegColors.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: ValueListenableBuilder<vp.VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final duration = value.duration;
            final position = value.position;
            final maxMs = duration.inMilliseconds <= 0
                ? 1.0
                : duration.inMilliseconds.toDouble();
            final valueMs = position.inMilliseconds
                .clamp(0, maxMs.toInt())
                .toDouble();
            return LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 760;
                final topRow = Row(
                  children: [
                    IconButton(
                      tooltip: value.isPlaying ? 'Pausa' : 'Play',
                      onPressed: value.isPlaying
                          ? controller.pause
                          : controller.play,
                      icon: Icon(
                        value.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                    ),
                    _SeekIconButton(
                      tooltip: '-10s',
                      icon: Icons.replay_10,
                      onPressed: duration.inMilliseconds <= 0
                          ? null
                          : () => controller.seekTo(
                              position - const Duration(seconds: 10),
                            ),
                    ),
                    _SeekIconButton(
                      tooltip: '+10s',
                      icon: Icons.forward_10,
                      onPressed: duration.inMilliseconds <= 0
                          ? null
                          : () => controller.seekTo(
                              position + const Duration(seconds: 10),
                            ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${_formatDuration(position)} / ${_formatDuration(duration)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                );
                final controlsRow = compact
                    ? Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _AppleVolumeControl(controller: controller),
                          PopupMenuButton<double>(
                            tooltip: 'Velocita',
                            initialValue: rate,
                            onSelected: (next) {
                              controller.setPlaybackSpeed(next);
                              onRateChanged(next);
                            },
                            child: const _PlayerMenuChip(
                              icon: Icons.speed,
                              label: 'Velocita',
                            ),
                            itemBuilder: (_) =>
                                const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                                    .map(
                                      (speed) => PopupMenuItem<double>(
                                        value: speed,
                                        child: Text('${speed}x'),
                                      ),
                                    )
                                    .toList(),
                          ),
                          IconButton(
                            tooltip: focusMode
                                ? 'Esci fullscreen'
                                : 'Fullscreen',
                            onPressed: onToggleFocusMode,
                            icon: Icon(
                              focusMode
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          PopupMenuButton<double>(
                            tooltip: 'Velocita',
                            initialValue: rate,
                            onSelected: (next) {
                              controller.setPlaybackSpeed(next);
                              onRateChanged(next);
                            },
                            child: const _PlayerMenuChip(
                              icon: Icons.speed,
                              label: 'Velocita',
                            ),
                            itemBuilder: (_) =>
                                const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                                    .map(
                                      (speed) => PopupMenuItem<double>(
                                        value: speed,
                                        child: Text('${speed}x'),
                                      ),
                                    )
                                    .toList(),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _AppleVolumeControl(controller: controller),
                          ),
                          IconButton(
                            tooltip: focusMode
                                ? 'Esci fullscreen'
                                : 'Fullscreen',
                            onPressed: onToggleFocusMode,
                            icon: Icon(
                              focusMode
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                            ),
                          ),
                        ],
                      );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    topRow,
                    Slider(
                      value: valueMs,
                      min: 0,
                      max: maxMs,
                      onChanged: duration.inMilliseconds <= 0
                          ? null
                          : (next) => controller.seekTo(
                              Duration(milliseconds: next.round()),
                            ),
                    ),
                    controlsRow,
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _formatDuration(Duration value) {
    if (value == Duration.zero) return '00:00';
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _TizenTimelineControls extends StatelessWidget {
  const _TizenTimelineControls({
    required this.controller,
    required this.rate,
    required this.onRateChanged,
    required this.focusMode,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
  });

  final avplay.VideoPlayerController controller;
  final double rate;
  final ValueChanged<double> onRateChanged;
  final bool focusMode;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.74),
        border: const Border(top: BorderSide(color: LelegColors.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: ValueListenableBuilder<avplay.VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final duration = value.duration.end;
            final position = value.position;
            final maxMs = duration.inMilliseconds <= 0
                ? 1.0
                : duration.inMilliseconds.toDouble();
            final valueMs = position.inMilliseconds
                .clamp(0, maxMs.toInt())
                .toDouble();
            return LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 760;
                final topRow = Row(
                  children: [
                    IconButton(
                      tooltip: value.isPlaying ? 'Pausa' : 'Play',
                      onPressed: value.isPlaying
                          ? controller.pause
                          : controller.play,
                      icon: Icon(
                        value.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                    ),
                    _SeekIconButton(
                      tooltip: '-10s',
                      icon: Icons.replay_10,
                      onPressed: duration.inMilliseconds <= 0
                          ? null
                          : () => controller.seekTo(
                              position - const Duration(seconds: 10),
                            ),
                    ),
                    _SeekIconButton(
                      tooltip: '+10s',
                      icon: Icons.forward_10,
                      onPressed: duration.inMilliseconds <= 0
                          ? null
                          : () => controller.seekTo(
                              position + const Duration(seconds: 10),
                            ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${_formatDuration(position)} / ${_formatDuration(duration)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                );
                final controlsRow = compact
                    ? Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _TizenVolumeControl(controller: controller),
                          PopupMenuButton<double>(
                            tooltip: 'Velocita',
                            initialValue: rate,
                            onSelected: (next) {
                              controller.setPlaybackSpeed(next);
                              onRateChanged(next);
                            },
                            child: const _PlayerMenuChip(
                              icon: Icons.speed,
                              label: 'Velocita',
                            ),
                            itemBuilder: (_) =>
                                const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                                    .map(
                                      (speed) => PopupMenuItem<double>(
                                        value: speed,
                                        child: Text('${speed}x'),
                                      ),
                                    )
                                    .toList(),
                          ),
                          IconButton(
                            tooltip: focusMode
                                ? 'Esci fullscreen'
                                : 'Fullscreen',
                            onPressed: onToggleFocusMode,
                            icon: Icon(
                              focusMode
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          PopupMenuButton<double>(
                            tooltip: 'Velocita',
                            initialValue: rate,
                            onSelected: (next) {
                              controller.setPlaybackSpeed(next);
                              onRateChanged(next);
                            },
                            child: const _PlayerMenuChip(
                              icon: Icons.speed,
                              label: 'Velocita',
                            ),
                            itemBuilder: (_) =>
                                const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                                    .map(
                                      (speed) => PopupMenuItem<double>(
                                        value: speed,
                                        child: Text('${speed}x'),
                                      ),
                                    )
                                    .toList(),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _TizenVolumeControl(controller: controller),
                          ),
                          IconButton(
                            tooltip: focusMode
                                ? 'Esci fullscreen'
                                : 'Fullscreen',
                            onPressed: onToggleFocusMode,
                            icon: Icon(
                              focusMode
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                            ),
                          ),
                        ],
                      );
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    topRow,
                    Slider(
                      value: valueMs,
                      min: 0,
                      max: maxMs,
                      onChanged: duration.inMilliseconds <= 0
                          ? null
                          : (next) => controller.seekTo(
                              Duration(milliseconds: next.round()),
                            ),
                    ),
                    controlsRow,
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _formatDuration(Duration value) {
    if (value == Duration.zero) return '00:00';
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _PlayerTimelineControls extends StatelessWidget {
  const _PlayerTimelineControls({
    required this.player,
    required this.rate,
    required this.labelFor,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    required this.focusMode,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
  });

  final Player player;
  final double rate;
  final String Function(dynamic value) labelFor;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;
  final bool focusMode;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.74),
        border: const Border(top: BorderSide(color: LelegColors.line)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (context, playingSnapshot) {
            final playing = playingSnapshot.data ?? false;
            return StreamBuilder<Duration>(
              stream: player.stream.position,
              initialData: player.state.position,
              builder: (context, positionSnapshot) {
                final position = positionSnapshot.data ?? Duration.zero;
                return StreamBuilder<Duration>(
                  stream: player.stream.duration,
                  initialData: player.state.duration,
                  builder: (context, durationSnapshot) {
                    final duration = durationSnapshot.data ?? Duration.zero;
                    final maxMs = duration.inMilliseconds <= 0
                        ? 1.0
                        : duration.inMilliseconds.toDouble();
                    final valueMs = position.inMilliseconds
                        .clamp(0, maxMs.toInt())
                        .toDouble();
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final compact = constraints.maxWidth < 760;
                        final topRow = Row(
                          children: [
                            IconButton(
                              tooltip: playing ? 'Pausa' : 'Play',
                              onPressed: () =>
                                  playing ? player.pause() : player.play(),
                              icon: Icon(
                                playing ? Icons.pause : Icons.play_arrow,
                              ),
                            ),
                            _SeekIconButton(
                              tooltip: '-10s',
                              icon: Icons.replay_10,
                              onPressed: duration.inMilliseconds <= 0
                                  ? null
                                  : () => player.seek(
                                      position - const Duration(seconds: 10),
                                    ),
                            ),
                            _SeekIconButton(
                              tooltip: '+10s',
                              icon: Icons.forward_10,
                              onPressed: duration.inMilliseconds <= 0
                                  ? null
                                  : () => player.seek(
                                      position + const Duration(seconds: 10),
                                    ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${_formatDuration(position)} / ${_formatDuration(duration)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        );
                        final controlBar = compact
                            ? Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  _CompactTrackControls(
                                    compact: true,
                                    player: player,
                                    rate: rate,
                                    labelFor: labelFor,
                                    onAudioChanged: onAudioChanged,
                                    onSubtitleChanged: onSubtitleChanged,
                                    onRateChanged: onRateChanged,
                                  ),
                                  _VolumeControl(player: player, compact: true),
                                  IconButton(
                                    tooltip: focusMode
                                        ? 'Esci fullscreen'
                                        : 'Fullscreen',
                                    onPressed: onToggleFocusMode,
                                    icon: Icon(
                                      focusMode
                                          ? Icons.fullscreen_exit
                                          : Icons.fullscreen,
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                children: [
                                  _CompactTrackControls(
                                    player: player,
                                    rate: rate,
                                    labelFor: labelFor,
                                    onAudioChanged: onAudioChanged,
                                    onSubtitleChanged: onSubtitleChanged,
                                    onRateChanged: onRateChanged,
                                  ),
                                  _VolumeControl(player: player),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: focusMode
                                        ? 'Esci fullscreen'
                                        : 'Fullscreen',
                                    onPressed: onToggleFocusMode,
                                    icon: Icon(
                                      focusMode
                                          ? Icons.fullscreen_exit
                                          : Icons.fullscreen,
                                    ),
                                  ),
                                ],
                              );
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            topRow,
                            Slider(
                              value: valueMs,
                              min: 0,
                              max: maxMs,
                              onChanged: duration.inMilliseconds <= 0
                                  ? null
                                  : (value) => player.seek(
                                      Duration(milliseconds: value.round()),
                                    ),
                            ),
                            controlBar,
                          ],
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _formatDuration(Duration value) {
    if (value == Duration.zero) return '00:00';
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _VolumeControl extends StatelessWidget {
  const _VolumeControl({required this.player, this.compact = false});

  final Player player;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final volume = player.state.volume.clamp(0, 100).toDouble();
    return SizedBox(
      width: compact ? 110 : 128,
      child: Row(
        children: [
          Icon(volume == 0 ? Icons.volume_off : Icons.volume_up, size: 20),
          Expanded(
            child: Slider(
              value: volume,
              min: 0,
              max: 100,
              onChanged: player.setVolume,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppleVolumeControl extends StatelessWidget {
  const _AppleVolumeControl({required this.controller});

  final vp.VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<vp.VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return SizedBox(
          width: 128,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                value.volume <= 0 ? Icons.volume_off : Icons.volume_up,
                size: 20,
              ),
              Expanded(
                child: Slider(
                  value: value.volume.clamp(0, 1).toDouble(),
                  min: 0,
                  max: 1,
                  onChanged: controller.setVolume,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class TrackControls extends StatelessWidget {
  const TrackControls({
    required this.player,
    required this.rate,
    required this.labelFor,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    super.key,
  });

  final Player player;
  final double rate;
  final String Function(dynamic value) labelFor;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;

  @override
  Widget build(BuildContext context) {
    final tracks = player.state.tracks;
    return Wrap(
      spacing: 18,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _TrackMenu<AudioTrack>(
          label: 'Audio',
          value: player.state.track.audio,
          values: [AudioTrack.auto(), AudioTrack.no(), ...tracks.audio],
          labelFor: labelFor,
          onChanged: onAudioChanged,
        ),
        _TrackMenu<SubtitleTrack>(
          label: 'Sottotitoli',
          value: player.state.track.subtitle,
          values: [
            SubtitleTrack.no(),
            SubtitleTrack.auto(),
            ...tracks.subtitle,
          ],
          labelFor: labelFor,
          onChanged: onSubtitleChanged,
        ),
        _RateMenu(value: rate, onChanged: onRateChanged),
      ],
    );
  }
}

class _CompactTrackControls extends StatelessWidget {
  const _CompactTrackControls({
    required this.player,
    required this.rate,
    required this.labelFor,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    this.compact = false,
  });

  final Player player;
  final double rate;
  final String Function(dynamic value) labelFor;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tracks = player.state.tracks;
    return Wrap(
      spacing: compact ? 8 : 0,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _CompactMenu<AudioTrack>(
          icon: Icons.audiotrack,
          label: 'Audio',
          tooltip: 'Cambia traccia audio',
          value: player.state.track.audio,
          values: [AudioTrack.auto(), AudioTrack.no(), ...tracks.audio],
          labelFor: labelFor,
          onChanged: onAudioChanged,
        ),
        _CompactMenu<SubtitleTrack>(
          icon: Icons.subtitles,
          label: 'Sub',
          tooltip: 'Sottotitoli',
          value: player.state.track.subtitle,
          values: [
            SubtitleTrack.no(),
            SubtitleTrack.auto(),
            ...tracks.subtitle,
          ],
          labelFor: labelFor,
          onChanged: onSubtitleChanged,
        ),
        PopupMenuButton<double>(
          tooltip: 'Velocita',
          initialValue: rate,
          onSelected: onRateChanged,
          child: const _PlayerMenuChip(icon: Icons.speed, label: 'Velocita'),
          itemBuilder: (_) => const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
              .map(
                (value) => PopupMenuItem<double>(
                  value: value,
                  child: Text('${value}x'),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _TizenVolumeControl extends StatelessWidget {
  const _TizenVolumeControl({required this.controller});

  final avplay.VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<avplay.VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return SizedBox(
          width: 128,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                value.volume <= 0 ? Icons.volume_off : Icons.volume_up,
                size: 20,
              ),
              Expanded(
                child: Slider(
                  value: value.volume.clamp(0, 1).toDouble(),
                  min: 0,
                  max: 1,
                  onChanged: controller.setVolume,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SeekIconButton extends StatelessWidget {
  const _SeekIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _CompactMenu<T> extends StatelessWidget {
  const _CompactMenu({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.value,
    required this.values,
    required this.labelFor,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final T value;
  final List<T> values;
  final String Function(T value) labelFor;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = <T>{...values}.toList();
    final selected = items.contains(value) ? value : items.first;
    return PopupMenuButton<T>(
      tooltip: tooltip,
      initialValue: selected,
      onSelected: onChanged,
      child: _PlayerMenuChip(icon: icon, label: label),
      itemBuilder: (_) => [
        for (final item in items)
          PopupMenuItem<T>(value: item, child: Text(labelFor(item))),
      ],
    );
  }
}

class _PlayerMenuChip extends StatelessWidget {
  const _PlayerMenuChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogToolbar extends StatelessWidget {
  const _CatalogToolbar({
    required this.categories,
    required this.selectedCategoryId,
    required this.categoryName,
    required this.onCategoryChanged,
    this.categoryLabel,
    this.sort,
    this.onSortChanged,
    this.narrow = false,
  });

  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final String Function(String id) categoryName;
  final ValueChanged<String> onCategoryChanged;
  final String Function(String id)? categoryLabel;
  final String? sort;
  final ValueChanged<String>? onSortChanged;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final mobile = narrow || MediaQuery.sizeOf(context).width < 760;
    final categoryIds = ['', ...categories.map((item) => item.id)];
    final selected = categoryIds.contains(selectedCategoryId)
        ? selectedCategoryId
        : '';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        mobile ? 12 : 20,
        narrow ? 4 : 8,
        mobile ? 12 : 20,
        narrow ? 8 : 18,
      ),
      child: mobile
          ? Column(
              children: [
                _ToolbarSelect<String>(
                  label: 'Categoria',
                  value: selected,
                  items: categoryIds,
                  itemLabel: categoryLabel ?? categoryName,
                  onChanged: onCategoryChanged,
                ),
                if (sort != null && onSortChanged != null) ...[
                  const SizedBox(height: 12),
                  _ToolbarSelect<String>(
                    label: 'Ordina',
                    value: sort!,
                    items: const ['default', 'az', 'rating', 'recommended'],
                    itemLabel: _catalogSortLabel,
                    onChanged: onSortChanged!,
                  ),
                ],
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: _ToolbarSelect<String>(
                    label: 'Categoria',
                    value: selected,
                    items: categoryIds,
                    itemLabel: categoryLabel ?? categoryName,
                    onChanged: onCategoryChanged,
                  ),
                ),
                if (sort != null && onSortChanged != null) ...[
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 210,
                    child: _ToolbarSelect<String>(
                      label: 'Ordina',
                      value: sort!,
                      items: const ['default', 'az', 'rating', 'recommended'],
                      itemLabel: _catalogSortLabel,
                      onChanged: onSortChanged!,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

String _catalogSortLabel(String value) => switch (value) {
  'az' => 'Titolo A-Z',
  'rating' => 'Punteggio',
  'recommended' => 'Consigliati per te',
  _ => 'Più recenti',
};

class _ToolbarSelect<T> extends StatelessWidget {
  const _ToolbarSelect({
    required this.label,
    required this.value,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> items;
  final String Function(T value) itemLabel;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          items: [
            for (final item in items)
              DropdownMenuItem<T>(
                value: item,
                child: Text(itemLabel(item), overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (item) {
            if (item != null) onChanged(item);
          },
        ),
      ),
    );
  }
}

class _QuickCategoryStrip extends StatelessWidget {
  const _QuickCategoryStrip({
    required this.categories,
    required this.selectedCategoryId,
    required this.onCategoryChanged,
    this.categoryLabel,
  });

  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final ValueChanged<String> onCategoryChanged;
  final String Function(String id)? categoryLabel;

  @override
  Widget build(BuildContext context) {
    final visibleCategories = categories.take(12).toList();
    return SizedBox(
      height: 50,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _CategoryChipButton(
              label: categoryLabel?.call('') ?? 'Tutte',
              selected: selectedCategoryId.isEmpty,
              onTap: () => onCategoryChanged(''),
            ),
          ),
          for (final category in visibleCategories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _CategoryChipButton(
                label: categoryLabel?.call(category.id) ?? category.name,
                selected: category.id == selectedCategoryId,
                onTap: () => onCategoryChanged(category.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryChipButton extends StatelessWidget {
  const _CategoryChipButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? LelegColors.accent.withValues(alpha: 0.16)
          : LelegColors.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? LelegColors.accent : LelegColors.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? LelegColors.fg : LelegColors.muted,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveNowProgrammePreview extends StatelessWidget {
  const _LiveNowProgrammePreview({
    required this.programmes,
    required this.loading,
    required this.channel,
    required this.onWatch,
    this.onOpenGuide,
  });

  final List<EpgProgramme> programmes;
  final bool loading;
  final LiveChannel? channel;
  final void Function(LiveChannel channel, EpgProgramme programme) onWatch;
  final VoidCallback? onOpenGuide;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        height: 72,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (channel == null || programmes.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Guida non disponibile',
            style: TextStyle(
              color: LelegColors.muted,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (onOpenGuide != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onOpenGuide,
              icon: const Icon(Icons.calendar_month_outlined, size: 18),
              label: const Text('Apri Guida TV'),
            ),
          ],
        ],
      );
    }

    final liveIndex = programmes.indexWhere(_epgIsLiveNow);
    final live = liveIndex >= 0 ? programmes[liveIndex] : null;
    final activeChannel = channel!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (live != null)
          Material(
            color: LelegColors.surface3,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => onWatch(activeChannel, live),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: LelegColors.accent.withValues(alpha: 0.55),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LIVE ${_formatGuideClock(live.start)} - ${_formatGuideClock(live.end)}',
                      style: const TextStyle(
                        color: LelegColors.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      live.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          const Text(
            'Nessun programma in onda',
            style: TextStyle(
              color: LelegColors.muted,
              fontWeight: FontWeight.w700,
            ),
          ),
        if (onOpenGuide != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onOpenGuide,
            icon: const Icon(Icons.calendar_month_outlined, size: 18),
            label: const Text('Apri Guida TV completa'),
          ),
        ],
      ],
    );
  }
}

class _TrackMenu<T> extends StatelessWidget {
  const _TrackMenu({
    required this.label,
    required this.value,
    required this.values,
    required this.labelFor,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> values;
  final String Function(T value) labelFor;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = <T>{...values}.toList();
    final selected = items.contains(value) ? value : items.first;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        DropdownButton<T>(
          value: selected,
          items: [
            for (final item in items)
              DropdownMenuItem<T>(value: item, child: Text(labelFor(item))),
          ],
          onChanged: (item) {
            if (item != null) onChanged(item);
          },
        ),
      ],
    );
  }
}

class _RateMenu extends StatelessWidget {
  const _RateMenu({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Velocita', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(width: 8),
        DropdownButton<double>(
          value: value,
          items: [
            for (final rate in rates)
              DropdownMenuItem<double>(
                value: rate,
                child: Text('${rate.toStringAsFixed(2)}x'),
              ),
          ],
          onChanged: (rate) {
            if (rate != null) onChanged(rate);
          },
        ),
      ],
    );
  }
}

class _TvCategorySidebar extends StatelessWidget {
  const _TvCategorySidebar({
    required this.categories,
    required this.selectedCategoryId,
    required this.onCategoryChanged,
    this.categoryLabel,
  });

  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final ValueChanged<String> onCategoryChanged;
  final String Function(String id)? categoryLabel;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _TvCategoryItem(
          label: categoryLabel?.call('') ?? 'Tutte',
          selected: selectedCategoryId.isEmpty,
          onTap: () => onCategoryChanged(''),
        ),
        for (final category in categories)
          _TvCategoryItem(
            label: categoryLabel?.call(category.id) ?? category.name,
            selected: selectedCategoryId == category.id,
            onTap: () => onCategoryChanged(category.id),
          ),
      ],
    );
  }
}

class _TvCategoryItem extends StatelessWidget {
  const _TvCategoryItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? LelegColors.surface3 : Colors.transparent,
      child: _RemoteActivate(
        onActivate: onTap,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: selected ? LelegColors.accent : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                color: selected ? LelegColors.fg : LelegColors.muted,
                fontSize: TvUi.body,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TvLandscapeCard extends StatelessWidget {
  const _TvLandscapeCard({
    required this.title,
    required this.image,
    required this.onTap,
  });

  final String title;
  final String image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _RemoteActivate(
      onActivate: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: TvUi.cardWidth,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _BackdropImage(url: image, alignment: Alignment.center),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.78),
                            Colors.transparent,
                          ],
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: TvUi.caption,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.onOpen,
    required this.onPlay,
    this.category,
    this.liveProgramme,
    this.selected = false,
    this.compact = false,
    this.playOnTap = false,
    this.showPlayButton = true,
  });

  final LiveChannel channel;
  final ValueChanged<LiveChannel> onOpen;
  final ValueChanged<LiveChannel> onPlay;
  final String? category;
  final String? liveProgramme;
  final bool selected;
  final bool compact;
  final bool playOnTap;
  final bool showPlayButton;

  @override
  Widget build(BuildContext context) {
    final subtitle = liveProgramme != null
        ? (liveProgramme!.isEmpty || liveProgramme == '…'
              ? 'In onda: …'
              : 'In onda: $liveProgramme')
        : (category == null || category!.isEmpty
              ? '#${channel.id}'
              : '$category · #${channel.id}');
    return _EnsureVisibleWhenSelected(
      selected: selected,
      child: Material(
        color: selected ? LelegColors.surface3 : LelegColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: _RemoteActivate(
          onActivate: () => playOnTap ? onPlay(channel) : onOpen(channel),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? LelegColors.accent : Colors.transparent,
                width: selected ? 2 : 1,
              ),
            ),
            child: ListTile(
              dense: compact,
              visualDensity: compact
                  ? VisualDensity.compact
                  : VisualDensity.standard,
              contentPadding: compact
                  ? const EdgeInsets.symmetric(horizontal: 10, vertical: 0)
                  : null,
              leading: _Logo(
                url: channel.logo,
                fallback: Icons.live_tv,
                size: compact ? 24 : 48,
              ),
              title: Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? TvUi.body : null,
                  fontWeight: compact ? FontWeight.w700 : null,
                ),
              ),
              subtitle: Text(
                subtitle,
                maxLines: liveProgramme != null ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: liveProgramme != null && liveProgramme!.isNotEmpty
                      ? LelegColors.fg
                      : LelegColors.muted,
                  fontWeight: liveProgramme != null && liveProgramme!.isNotEmpty
                      ? FontWeight.w600
                      : null,
                ),
              ),
              trailing: compact || !showPlayButton
                  ? null
                  : IconButton.filledTonal(
                      onPressed: () => onPlay(channel),
                      icon: const Icon(Icons.play_arrow),
                    ),
              onTap: () => playOnTap ? onPlay(channel) : onOpen(channel),
            ),
          ),
        ),
      ),
    );
  }
}

class _MoviePosterCard extends StatelessWidget {
  const _MoviePosterCard({
    required this.movie,
    required this.onPlay,
    this.category,
    this.watchProgress,
    this.onFavorite,
    this.onWatchLater,
    this.onDownload,
    this.isFavorite = false,
    this.isWatchLater = false,
    this.selected = false,
  });

  final VodMovie movie;
  final ValueChanged<VodMovie> onPlay;
  final String? category;
  final PlaybackProgress? watchProgress;
  final ValueChanged<VodMovie>? onFavorite;
  final ValueChanged<VodMovie>? onWatchLater;
  final ValueChanged<VodMovie>? onDownload;
  final bool isFavorite;
  final bool isWatchLater;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return _EnsureVisibleWhenSelected(
      selected: selected,
      child: Material(
        color: selected ? LelegColors.surface3 : LelegColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: _RemoteActivate(
          onActivate: () => onPlay(movie),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => onPlay(movie),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected ? LelegColors.accent : LelegColors.line,
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final metaHeight =
                      (onFavorite != null ? 36.0 : 0) +
                      (onWatchLater != null ? 36.0 : 0) +
                      (onDownload != null ? 36.0 : 0) +
                      72;
                  final posterHeight = constraints.maxHeight.isFinite
                      ? (constraints.maxHeight - metaHeight).clamp(120.0, 400.0)
                      : 220.0;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: posterHeight,
                        width: double.infinity,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _Poster(url: movie.logo),
                            if (watchProgress != null &&
                                watchProgress!.fraction > 0)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: _WatchProgressBar(
                                  progress: watchProgress!,
                                  compact: true,
                                ),
                              ),
                            if (watchProgress?.canResume == true)
                              Positioned(
                                left: 8,
                                bottom: 8,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: LelegColors.accent.withValues(
                                      alpha: 0.92,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 3,
                                    ),
                                    child: Text(
                                      'RIPRENDI',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Positioned(
                              right: 8,
                              top: 8,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.58),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 5,
                                  ),
                                  child: Text(
                                    movie.rating.isEmpty
                                        ? 'MOVIE'
                                        : movie.rating,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              movie.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (category != null && category!.isNotEmpty) ...[
                              const SizedBox(height: 5),
                              Text(
                                category!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: LelegColors.muted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 0,
                              runSpacing: 0,
                              children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  constraints: const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 36,
                                  ),
                                  onPressed: () => onPlay(movie),
                                  icon: const Icon(
                                    Icons.chevron_right,
                                    size: 22,
                                  ),
                                  tooltip: 'Dettagli',
                                ),
                                if (onFavorite != null)
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 36,
                                    ),
                                    onPressed: () => onFavorite!(movie),
                                    icon: Icon(
                                      isFavorite
                                          ? Icons.star
                                          : Icons.star_border,
                                      size: 22,
                                    ),
                                    tooltip: 'Preferiti',
                                  ),
                                if (onWatchLater != null)
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 36,
                                    ),
                                    onPressed: () => onWatchLater!(movie),
                                    icon: Icon(
                                      isWatchLater
                                          ? Icons.bookmark
                                          : Icons.bookmark_border,
                                      size: 22,
                                    ),
                                    tooltip: 'Da vedere',
                                  ),
                                if (onDownload != null)
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 36,
                                    ),
                                    onPressed: () => onDownload!(movie),
                                    icon: const Icon(
                                      Icons.download_outlined,
                                      size: 22,
                                    ),
                                    tooltip: 'Download',
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SeriesPosterCard extends StatelessWidget {
  const _SeriesPosterCard({
    required this.show,
    required this.category,
    required this.onOpen,
    this.watchProgress,
    this.onFavorite,
    this.onDownload,
    this.isFavorite = false,
    this.selected = false,
  });

  final SeriesShow show;
  final String category;
  final ValueChanged<SeriesShow> onOpen;
  final PlaybackProgress? watchProgress;
  final ValueChanged<SeriesShow>? onFavorite;
  final ValueChanged<SeriesShow>? onDownload;
  final bool isFavorite;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return _EnsureVisibleWhenSelected(
      selected: selected,
      child: Material(
        color: selected ? LelegColors.surface3 : LelegColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: _RemoteActivate(
          onActivate: () => onOpen(show),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => onOpen(show),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected ? LelegColors.accent : LelegColors.line,
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final metaHeight =
                      (onFavorite != null ? 36.0 : 0) +
                      (onDownload != null ? 36.0 : 0) +
                      72;
                  final posterHeight = constraints.maxHeight.isFinite
                      ? (constraints.maxHeight - metaHeight).clamp(120.0, 400.0)
                      : 220.0;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: posterHeight,
                        width: double.infinity,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _Poster(url: show.logo),
                            if (watchProgress != null &&
                                watchProgress!.fraction > 0)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: _WatchProgressBar(
                                  progress: watchProgress!,
                                  compact: true,
                                ),
                              ),
                            if (watchProgress?.canResume == true)
                              Positioned(
                                left: 8,
                                bottom: 8,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: LelegColors.accent.withValues(
                                      alpha: 0.92,
                                    ),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 3,
                                    ),
                                    child: Text(
                                      'RIPRENDI',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Positioned(
                              right: 8,
                              top: 8,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.58),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 5,
                                  ),
                                  child: Text(
                                    show.rating.isEmpty ? 'SERIE' : show.rating,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              show.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              [
                                if (show.year.isNotEmpty) show.year,
                                if (category.isNotEmpty) category,
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: LelegColors.muted,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 0,
                              runSpacing: 0,
                              children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  constraints: const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 36,
                                  ),
                                  onPressed: () => onOpen(show),
                                  icon: const Icon(
                                    Icons.chevron_right,
                                    size: 22,
                                  ),
                                  tooltip: 'Apri episodi',
                                ),
                                if (onFavorite != null)
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 36,
                                    ),
                                    onPressed: () => onFavorite!(show),
                                    icon: Icon(
                                      isFavorite
                                          ? Icons.star
                                          : Icons.star_border,
                                      size: 22,
                                    ),
                                    tooltip: 'Preferiti',
                                  ),
                                if (onDownload != null)
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 36,
                                    ),
                                    onPressed: () => onDownload!(show),
                                    icon: const Icon(
                                      Icons.download_outlined,
                                      size: 22,
                                    ),
                                    tooltip: 'Download',
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SeriesSeasonList extends StatelessWidget {
  const _SeriesSeasonList({
    required this.episodes,
    required this.episodeProgress,
    required this.selectedEpisodeIndex,
    required this.onPlay,
  });

  final List<SeriesEpisode> episodes;
  final Map<int, PlaybackProgress> episodeProgress;
  final int? selectedEpisodeIndex;
  final ValueChanged<SeriesEpisode> onPlay;

  @override
  Widget build(BuildContext context) {
    final grouped = <int, List<SeriesEpisode>>{};
    for (final episode in episodes) {
      final season = episode.season > 0 ? episode.season : 1;
      grouped.putIfAbsent(season, () => []).add(episode);
    }
    final seasons = grouped.keys.toList()..sort();
    var flatIndex = 0;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        TvUi.contentPadding,
        8,
        TvUi.contentPadding,
        16,
      ),
      children: [
        for (final season in seasons) ...[
          Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6),
            child: Text(
              'Stagione $season',
              style: TextStyle(
                fontSize: TvUi.font(14),
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
          for (final episode in grouped[season]!)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _EpisodeTile(
                episode: episode,
                progress: episodeProgress[episode.id],
                onPlay: onPlay,
                selected: selectedEpisodeIndex == flatIndex++,
                compact: true,
              ),
            ),
        ],
      ],
    );
  }
}

class _WindowsSeriesDetailPane extends StatelessWidget {
  const _WindowsSeriesDetailPane({
    required this.show,
    required this.description,
    required this.genre,
    required this.episodes,
    required this.loading,
    required this.canResume,
    required this.onResume,
    required this.onBack,
    required this.episodeProgress,
    required this.onPlay,
  });

  final SeriesShow show;
  final String description;
  final String genre;
  final List<SeriesEpisode> episodes;
  final bool loading;
  final bool canResume;
  final VoidCallback? onResume;
  final VoidCallback onBack;
  final Map<int, PlaybackProgress> episodeProgress;
  final ValueChanged<SeriesEpisode> onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Serie'),
              ),
              const SizedBox(width: 12),
              if (canResume && onResume != null)
                FilledButton.icon(
                  onPressed: onResume,
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Riprendi'),
                ),
              if (loading) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Container(
            height: 156,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: LelegColors.surface2,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: LelegColors.line),
            ),
            child: Row(
              children: [
                SizedBox(width: 112, child: _Poster(url: show.logo)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          show.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 7),
                        if (genre.trim().isNotEmpty) ...[
                          Text(
                            genre.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LelegColors.accent,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 5),
                        ],
                        Expanded(
                          child: Text(
                            description.trim().isEmpty
                                ? 'Nessuna descrizione disponibile dal provider.'
                                : description.trim(),
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LelegColors.muted,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: episodes.isEmpty
              ? const _EmptyState(message: 'Nessun episodio caricato.')
              : _SeriesSeasonList(
                  episodes: episodes,
                  episodeProgress: episodeProgress,
                  selectedEpisodeIndex: null,
                  onPlay: onPlay,
                ),
        ),
      ],
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.episode,
    required this.onPlay,
    this.progress,
    this.selected = false,
    this.compact = false,
  });

  final SeriesEpisode episode;
  final ValueChanged<SeriesEpisode> onPlay;
  final PlaybackProgress? progress;
  final bool selected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final seasonCode = episode.season > 0
        ? 'S${episode.season.toString().padLeft(2, '0')}'
        : '';
    final episodeCode = episode.episode > 0
        ? 'E${episode.episode.toString().padLeft(2, '0')}'
        : '';
    final code = compact
        ? [seasonCode, episodeCode].where((item) => item.isNotEmpty).join('\n')
        : '$seasonCode$episodeCode';
    final leadingSize = compact ? 36.0 : 48.0;
    final watched = progress != null && progress!.fraction > 0;
    final progressLabel = progress == null
        ? ''
        : progress!.isCompleted
        ? 'Visto'
        : '${(progress!.fraction * 100).round()}%';
    return _EnsureVisibleWhenSelected(
      selected: selected,
      child: Material(
        color: selected ? LelegColors.surface3 : LelegColors.surface,
        borderRadius: BorderRadius.circular(compact ? 10 : 14),
        child: _RemoteActivate(
          onActivate: () => onPlay(episode),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(compact ? 10 : 14),
              border: Border.all(
                color: selected ? LelegColors.accent : Colors.transparent,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  dense: compact,
                  visualDensity: compact
                      ? VisualDensity.compact
                      : VisualDensity.standard,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: compact ? 10 : 16,
                    vertical: compact ? 2 : 0,
                  ),
                  minLeadingWidth: leadingSize,
                  leading: SizedBox(
                    width: leadingSize,
                    height: leadingSize,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: LelegColors.surface3,
                            shape: BoxShape.circle,
                            border: watched
                                ? Border.all(
                                    color: progress!.isCompleted
                                        ? LelegColors.accent
                                        : LelegColors.line,
                                    width: 2,
                                  )
                                : null,
                          ),
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Padding(
                                padding: const EdgeInsets.all(5),
                                child: Text(
                                  code.isEmpty ? 'EP' : code,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: compact ? 8 : 11,
                                    height: compact ? 1.05 : 1.2,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (progress?.isCompleted == true)
                          const Icon(
                            Icons.check_circle,
                            color: LelegColors.accent,
                            size: 14,
                          ),
                      ],
                    ),
                  ),
                  title: Text(
                    episode.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 12 : null,
                      fontWeight: compact ? FontWeight.w700 : null,
                    ),
                  ),
                  subtitle: Text(
                    [
                      if (episode.duration.isNotEmpty) episode.duration,
                      episode.containerExtension.toUpperCase(),
                      if (progressLabel.isNotEmpty) progressLabel,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: LelegColors.muted),
                  ),
                  trailing: compact
                      ? null
                      : IconButton.filledTonal(
                          onPressed: () => onPlay(episode),
                          icon: const Icon(Icons.play_arrow),
                        ),
                  onTap: () => onPlay(episode),
                ),
                if (watched && progress!.isCompleted != true)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      compact ? 10 : 16,
                      0,
                      compact ? 10 : 16,
                      compact ? 6 : 8,
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        value: progress!.fraction,
                        backgroundColor: LelegColors.line,
                        color: LelegColors.accent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EpgProgrammeList extends StatefulWidget {
  const _EpgProgrammeList({
    required this.programmes,
    required this.loading,
    required this.emptyMessage,
    required this.channel,
    required this.onWatch,
  });

  final List<EpgProgramme> programmes;
  final bool loading;
  final String emptyMessage;
  final LiveChannel? channel;
  final void Function(LiveChannel channel, EpgProgramme programme) onWatch;

  @override
  State<_EpgProgrammeList> createState() => _EpgProgrammeListState();
}

class _TvVodToolbar extends StatelessWidget {
  const _TvVodToolbar({
    required this.focusIndex,
    required this.playing,
    required this.audioLabel,
    required this.subtitleLabel,
  });

  final int focusIndex;
  final bool playing;
  final String audioLabel;
  final String subtitleLabel;

  static const _items = [
    (Icons.play_arrow, 'Play'),
    (Icons.replay_10, '-10s'),
    (Icons.forward_10, '+10s'),
    (Icons.audiotrack, 'Audio'),
    (Icons.subtitles, 'Sottotitoli'),
    (Icons.fullscreen_exit, 'Esci'),
  ];

  @override
  Widget build(BuildContext context) {
    final labels = [
      playing ? 'Pausa' : 'Play',
      '-10s',
      '+10s',
      audioLabel,
      subtitleLabel,
      'Esci',
    ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: LelegColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              focusIndex >= 0
                  ? 'Toolbar attiva — Sin/Des seleziona, OK attiva, Su esci'
                  : 'Giù apre toolbar · OK play/pausa · Su/Giu audio/sottotitoli',
              style: const TextStyle(
                color: LelegColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var index = 0; index < _items.length; index++) ...[
                    if (index > 0) const SizedBox(width: 10),
                    _TvToolbarChip(
                      icon: index == 0 && playing
                          ? Icons.pause
                          : _items[index].$1,
                      label: labels[index],
                      selected: focusIndex == index,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvToolbarChip extends StatelessWidget {
  const _TvToolbarChip({
    required this.icon,
    required this.label,
    required this.selected,
  });

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: selected
            ? LelegColors.accent.withValues(alpha: 0.22)
            : LelegColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? LelegColors.accent : LelegColors.line,
          width: selected ? 2 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: selected ? LelegColors.accent : null),
          const SizedBox(width: 8),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: selected ? LelegColors.fg : LelegColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _FullscreenLiveOverlay extends StatefulWidget {
  const _FullscreenLiveOverlay({
    required this.channel,
    required this.programmes,
    required this.loading,
    required this.selectedIndex,
    required this.onPreviousChannel,
    required this.onNextChannel,
    required this.onWatchProgramme,
  });

  final LiveChannel? channel;
  final List<EpgProgramme> programmes;
  final bool loading;
  final int selectedIndex;
  final VoidCallback onPreviousChannel;
  final VoidCallback onNextChannel;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onWatchProgramme;

  @override
  State<_FullscreenLiveOverlay> createState() => _FullscreenLiveOverlayState();
}

class _FullscreenLiveOverlayState extends State<_FullscreenLiveOverlay> {
  static const _chipWidth = 230.0;
  static const _separator = 10.0;

  final ScrollController _scrollController = ScrollController();
  int? _lastScrollTarget;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocus());
  }

  @override
  void didUpdateWidget(covariant _FullscreenLiveOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.programmes != widget.programmes ||
        oldWidget.channel?.id != widget.channel?.id ||
        oldWidget.selectedIndex != widget.selectedIndex) {
      _lastScrollTarget = null;
      _scrollToFocus();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToFocus() {
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToFocusAttempt(0),
    );
  }

  void _scrollToFocusAttempt(int attempt) {
    if (!mounted || attempt > 10) return;
    final ordered = _orderedProgrammes(widget.channel);
    if (ordered.isEmpty) return;
    final liveIndex = ordered.indexWhere(_isLive);
    final targetIndex = liveIndex >= 0 ? liveIndex : widget.selectedIndex;
    final safeIndex = targetIndex.clamp(0, ordered.length - 1);
    if (_lastScrollTarget == safeIndex && attempt > 0) return;

    if (!_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToFocusAttempt(attempt + 1),
      );
      return;
    }

    _lastScrollTarget = safeIndex;
    final viewport = _scrollController.position.viewportDimension;
    final target =
        (safeIndex * (_chipWidth + _separator)) - ((viewport - _chipWidth) / 2);
    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent).toDouble(),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentChannel = widget.channel;
    final ordered = _orderedProgrammes(currentChannel);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: LelegColors.line),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.34),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.loading)
              const LinearProgressIndicator(minHeight: 3)
            else if (currentChannel == null || ordered.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Guida non disponibile per questo canale.',
                  style: TextStyle(
                    color: LelegColors.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              SizedBox(
                height: 106,
                child: ListView.separated(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: ordered.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, index) {
                    final programme = ordered[index];
                    final live = _isLive(programme);
                    final replay = _canReplay(currentChannel, programme);
                    final hasLive = ordered.any(_isLive);
                    final safeSelectedIndex = widget.selectedIndex.clamp(
                      0,
                      ordered.length - 1,
                    );
                    return _FullscreenEpgChip(
                      programme: programme,
                      live: live,
                      replay: replay,
                      selected:
                          live || (!hasLive && index == safeSelectedIndex),
                      onTap: live || replay
                          ? () => widget.onWatchProgramme(
                              currentChannel,
                              programme,
                            )
                          : null,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<EpgProgramme> _orderedProgrammes(LiveChannel? currentChannel) {
    if (currentChannel == null) return const [];
    return _contextualEpgWindowForChannel(currentChannel, widget.programmes);
  }

  bool _isLive(EpgProgramme programme) {
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    return start != null &&
        end != null &&
        !start.isAfter(now) &&
        end.isAfter(now);
  }

  bool _canReplay(LiveChannel channel, EpgProgramme programme) {
    return Catchup.canReplayProgramme(channel, programme);
  }

  String _timeRange(EpgProgramme programme) {
    String fmt(DateTime? value) {
      if (value == null) return '--:--';
      return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    }

    return '${fmt(programme.start)} - ${fmt(programme.end)}';
  }
}

class _FullscreenEpgChip extends StatelessWidget {
  const _FullscreenEpgChip({
    required this.programme,
    required this.live,
    required this.replay,
    this.selected = false,
    required this.onTap,
  });

  final EpgProgramme programme;
  final bool live;
  final bool replay;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = live || replay;
    return Material(
      color: live
          ? LelegColors.accent.withValues(alpha: 0.22)
          : LelegColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 230,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? LelegColors.fg
                  : active
                  ? LelegColors.accent.withValues(alpha: 0.72)
                  : LelegColors.line,
              width: selected ? 2.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                [
                  if (live) 'LIVE',
                  if (!live && replay) 'REC',
                  _timeRange(programme),
                ].join('  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: active ? LelegColors.accent : LelegColors.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                programme.title.trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              if (programme.description.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  programme.description.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LelegColors.muted,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _timeRange(EpgProgramme programme) {
    String fmt(DateTime? value) {
      if (value == null) return '--:--';
      return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    }

    return '${fmt(programme.start)} - ${fmt(programme.end)}';
  }
}

class _EpgProgrammeListState extends State<_EpgProgrammeList> {
  final ScrollController _controller = ScrollController();
  final GlobalKey _liveTileKey = GlobalKey();
  int? _scrolledToIndex;

  @override
  void initState() {
    super.initState();
    _scheduleScrollToLive();
  }

  @override
  void didUpdateWidget(covariant _EpgProgrammeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.programmes != widget.programmes ||
        oldWidget.channel?.id != widget.channel?.id ||
        oldWidget.loading != widget.loading) {
      _scrolledToIndex = null;
      _scheduleScrollToLive();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (widget.programmes.isEmpty) {
      return _EmptyState(
        message: widget.emptyMessage,
        icon: Icons.calendar_month,
      );
    }
    final orderedProgrammes = widget.programmes;
    final liveIndex = _epgLiveOrNextIndex(orderedProgrammes);
    return ListView.separated(
      controller: _controller,
      itemCount: orderedProgrammes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, index) {
        final programme = orderedProgrammes[index];
        final isLive = _epgIsLiveNow(programme);
        final highlight = index == liveIndex && isLive;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (highlight) const _GuideLiveMarker(),
            KeyedSubtree(
              key: highlight ? _liveTileKey : null,
              child: _programmeTile(
                programme,
                highlight: highlight,
                isLive: isLive,
              ),
            ),
          ],
        );
      },
    );
  }

  void _scheduleScrollToLive() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLive(0));
  }

  void _scrollToLive(int attempt) {
    if (!mounted || widget.loading) return;
    if (attempt > 16) return;

    final items = widget.programmes;
    if (items.isEmpty) return;

    final targetIndex = _epgLiveOrNextIndex(items);
    final isLive = targetIndex >= 0 && targetIndex < items.length
        ? _epgIsLiveNow(items[targetIndex])
        : false;
    if (!isLive) return;
    if (_scrolledToIndex == targetIndex && attempt > 0) return;

    if (!_controller.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToLive(attempt + 1),
      );
      return;
    }

    _scrolledToIndex = targetIndex;
    unawaited(
      _scrollListItemToCenter(
        _controller,
        _liveTileKey,
        fallbackIndex: targetIndex,
        fallbackHasMarker: true,
      ),
    );
  }

  bool _canInteract(EpgProgramme programme) {
    return widget.channel != null &&
        (_isLive(programme) || _canReplay(programme));
  }

  Widget _programmeTile(
    EpgProgramme programme, {
    required bool highlight,
    required bool isLive,
  }) {
    final liveFraction = isLive ? _liveProgrammeFraction(programme) : null;
    return Container(
      constraints: const BoxConstraints(minHeight: 100),
      decoration: BoxDecoration(
        color: highlight
            ? LelegColors.accent.withValues(alpha: 0.12)
            : LelegColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlight
              ? LelegColors.accent.withValues(alpha: 0.85)
              : LelegColors.line,
          width: highlight ? 1.5 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _canInteract(programme)
              ? () => widget.onWatch(widget.channel!, programme)
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (_isLive(programme) || _canReplay(programme)) ...[
                      Text(
                        _isLive(programme) ? 'LIVE' : 'REC',
                        style: const TextStyle(
                          color: LelegColors.accent,
                          fontWeight: FontWeight.w900,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      _timeRange(programme),
                      style: const TextStyle(
                        color: LelegColors.accent,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  programme.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                if (programme.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    programme.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LelegColors.muted,
                      fontSize: 13,
                    ),
                  ),
                ],
                if (liveFraction != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 4,
                      value: liveFraction,
                      backgroundColor: LelegColors.line,
                      color: LelegColors.accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _isLive(EpgProgramme programme) => _epgIsLiveNow(programme);

  bool _canReplay(EpgProgramme programme) {
    final currentChannel = widget.channel;
    if (currentChannel == null) return false;
    return Catchup.canReplayProgramme(currentChannel, programme);
  }

  String _timeRange(EpgProgramme programme) {
    String format(DateTime? value) {
      if (value == null) return '--:--';
      return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    }

    return '${format(programme.start)} - ${format(programme.end)}';
  }
}

class _BackdropImage extends StatelessWidget {
  const _BackdropImage({
    required this.url,
    this.alignment = const Alignment(0.65, -0.15),
    super.key,
  });

  final String url;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return const ColoredBox(
        color: LelegColors.surface2,
        child: Center(
          child: Icon(Icons.movie, size: 44, color: LelegColors.muted),
        ),
      );
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      alignment: alignment,
      width: double.infinity,
      height: double.infinity,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => const ColoredBox(
        color: LelegColors.surface2,
        child: Center(
          child: Icon(Icons.movie, size: 44, color: LelegColors.muted),
        ),
      ),
    );
  }
}

class _WatchProgressBar extends StatelessWidget {
  const _WatchProgressBar({required this.progress, this.compact = false});

  final PlaybackProgress progress;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (progress.fraction <= 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        minHeight: compact ? 3 : 4,
        value: progress.isCompleted ? 1 : progress.fraction,
        backgroundColor: compact
            ? Colors.black.withValues(alpha: 0.35)
            : LelegColors.line,
        color: LelegColors.accent,
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return const ColoredBox(
        color: LelegColors.surface2,
        child: Icon(Icons.movie, size: 44, color: LelegColors.muted),
      );
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const ColoredBox(
        color: LelegColors.surface2,
        child: Icon(Icons.movie, size: 44, color: LelegColors.muted),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.url, required this.fallback, this.size = 48});

  final String url;
  final IconData fallback;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return CircleAvatar(
        radius: size / 2,
        backgroundColor: LelegColors.surface3,
        child: Icon(fallback, color: LelegColors.accent, size: size * 0.55),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => CircleAvatar(
          radius: size / 2,
          backgroundColor: LelegColors.surface3,
          child: Icon(fallback, color: LelegColors.accent, size: size * 0.55),
        ),
      ),
    );
  }
}

class _SettingsBand extends StatelessWidget {
  const _SettingsBand({
    required this.title,
    required this.child,
    this.compact = false,
  });

  final String title;
  final Widget child;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 20),
      decoration: BoxDecoration(
        color: LelegColors.surface,
        borderRadius: BorderRadius.circular(compact ? 12 : 18),
        border: Border.all(color: LelegColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: compact ? TvUi.sectionTitle : 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          SizedBox(height: compact ? 8 : 16),
          child,
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, this.icon = Icons.inbox_outlined});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: LelegColors.muted),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: LelegColors.muted, fontSize: 16),
          ),
        ],
      ),
    );
  }
}
