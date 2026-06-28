import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart' as vp;
import 'package:video_player_avplay/video_player.dart' as avplay;
import 'package:video_player_avplay/video_player_platform_interface.dart'
    as avplay_platform;
import 'package:window_manager/window_manager.dart';

import 'domain/xtream_client.dart';

const MethodChannel _storageChannel = MethodChannel(
  'com.lelegiptv.native/storage',
);

const bool kAndroidTvBuild = bool.fromEnvironment('LELEG_ANDROID_TV');

/// Preserves [Video] state when [PlayerCard] moves between inline and fullscreen.
final GlobalKey _lelegMediaKitVideoSurfaceKey =
    GlobalKey(debugLabel: 'Leleg media_kit video surface');

/// True on Tizen, Android TV flavor, or Android TV hardware at runtime.
bool lelegTvShellActive = kAndroidTvBuild;

Future<bool> _resolveAndroidTvShell() async {
  if (kAndroidTvBuild || isTizenRuntime) {
    debugPrint('[leleg-tv] shell=compile-time (kAndroidTvBuild=$kAndroidTvBuild)');
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
      debugPrint('[leleg-tv] shell=miss attempt=$attempt tvFlavor=$tvFlavor isTv=$isTv');
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
      RegExp(r'/live/').hasMatch(target)) {
    return _iptvUaHls;
  }
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
  final urls = <String>[XtreamClient(profile).vodUrl(movie)];
  final ext = movie.containerExtension.trim().replaceAll('.', '').toLowerCase();
  if (ext.isNotEmpty && ext != 'mp4') {
    urls.add(
      '${profile.baseUrl}/movie/${Uri.encodeComponent(profile.username)}/'
      '${Uri.encodeComponent(profile.password)}/${movie.id}.mp4',
    );
  }
  return urls.toSet().toList(growable: false);
}

bool _useCompactAdaptiveLayout(Size size, {double phoneShortestSide = 700}) {
  if (lelegTvShellActive || isTizenRuntime) return false;
  return size.shortestSide < phoneShortestSide;
}

/// Portrait lock only on narrow phones. Tablets (even 7" / head unit ~530dp) stay rotatable.
const double _phonePortraitLockShortestSide = 480;

bool _shouldLockPortraitOnPhone(Size size) {
  return size.shortestSide < _phonePortraitLockShortestSide;
}

List<DeviceOrientation> _defaultOrientationsForSize(Size size) {
  if (_shouldLockPortraitOnPhone(size)) {
    return const [DeviceOrientation.portraitUp];
  }
  return const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];
}

bool _useCompactAdaptiveConstraints(
  BoxConstraints constraints, {
  double phoneShortestSide = 700,
}) {
  final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 1280.0;
  final height = constraints.maxHeight.isFinite ? constraints.maxHeight : 720.0;
  return _useCompactAdaptiveLayout(
    Size(width, height),
    phoneShortestSide: phoneShortestSide,
  );
}

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

class _LelegNativeShellState extends State<LelegNativeShell> {
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
  static const _watchLaterMoviesPrefix = 'leleg.native.watch_later_movies.';
  static const _catalogCacheTtl = Duration(days: 1);
  static const _catalogCacheVersion = 3;
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
  bool _remoteMenuMode = true;
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
  List<VodMovie> _movies = const [];
  VodMovie? _selectedMovie;
  String _selectedMovieDescription = '';
  String _browseHeroDescription = '';
  bool _browseHeroLoading = false;
  bool _browseHeroActionSelected = false;
  int? _browseHeroItemId;
  final Map<int, String> _movieDescriptionCache = {};
  final Map<int, String> _seriesDescriptionCache = {};
  List<SeriesShow> _series = const [];
  SeriesShow? _selectedSeries;
  String _selectedSeriesDescription = '';
  List<SeriesEpisode> _seriesEpisodes = const [];
  final Set<int> _favoriteMovieIds = {};
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
  bool _playerFocusMode = false;
  bool _isAndroidTv = false;
  bool _livePlayerActive = false;
  bool _fullscreenOverlayVisible = true;
  bool _remoteSearchSelected = false;  // campo di testo aperto
  bool _remoteSearchIconFocused = false; // solo l'icona cerca è evidenziata
  bool _tvSearchEditing = false;
  bool _remotePassthroughActive = false;
  int _epgProgrammeIndex = 0;
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
        : Player(configuration: const PlayerConfiguration(title: 'Leleg IPTV'));
    _player = mediaPlayer;
    _videoController = mediaPlayer == null
        ? null
        : VideoController(
            mediaPlayer,
            configuration: const VideoControllerConfiguration(
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
      lelegTvShellActive = true;
      unawaited(_applyAndroidTvChrome());
    } else if (Platform.isAndroid) {
      unawaited(_bootstrapAndroidShell());
    }
    FocusManager.instance.addListener(_onGlobalFocusChanged);
    _restoreState();
  }

  Future<void> _bootstrapAndroidShell() async {
    try {
      final tvFlavor = await _storageChannel.invokeMethod<bool>('isTvFlavor');
      if (tvFlavor == true) {
        await _applyAndroidTvChrome();
        return;
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
      'ITALIA1': XtreamProfile(
        title: 'ITALIA1',
        serverUrl: 'http://muti14.fonsecatemp.com',
        username: 'notv_w7cehc',
        password: 'ffhuax4a',
      ),
      'ITALIA2': XtreamProfile(
        title: 'ITALIA2',
        serverUrl: 'http://muti14.fonsecatemp.com',
        username: 'notv_71d762',
        password: 'qgjjhnty',
      ),
      'ITALIA3': XtreamProfile(
        title: 'ITALIA3',
        serverUrl: 'http://muti14.fonsecatemp.com',
        username: 'notv_93me22',
        password: 'x7g35zhh',
      ),
      'MONDO1': XtreamProfile(
        title: 'MONDO1',
        serverUrl: 'http://watchtivo-4k.com',
        username: 'S8eLtOiTtE',
        password: 'ut6YxwMG6X',
      ),
      'MONDO2': XtreamProfile(
        title: 'MONDO2',
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
      if (savedProfiles.isEmpty) return;
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
      _browseHeroDescription = '';
      _browseHeroLoading = false;
      _browseHeroItemId = null;
      _browseHeroActionSelected = false;
      if (section != AppSection.series) {
        _selectedSeries = null;
        _selectedSeriesDescription = '';
        _seriesEpisodes = const [];
      }
      _playerTitle = 'Scegli qualcosa da guardare.';
    });
    if (section == AppSection.epg) {
      unawaited(_loadEpgPage());
    }
    if (section == AppSection.live) {
      _previewLiveChannelAt(0);
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
    await prefs.setStringList(
      key,
      ids.map((id) => id.toString()).toList(),
    );
  }

  List<int> _dedupeRecentId(List<int> current, int id) {
    return [id, ...current.where((item) => item != id)]
        .take(_recentHistoryMax)
        .toList();
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

  int get _movieDetailTvActionCount =>
      _selectedMovie != null && _isAndroidTv && _movieCanResume(_selectedMovie!.id)
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
          final progress =
              episodeId == null ? null : _episodeProgress[episodeId];
          return TvHomeHeroTarget(
            eyebrow: 'CONTINUA A GUARDARE',
            title: show.name,
            imageUrl: show.logo,
            actionLabel:
                progress?.canResume == true && episodeId != null
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
      final description = await XtreamClient(profile).vodDescription(movie);
      _movieDescriptionCache[movie.id] = description;
      if (!mounted || _browseHeroItemId != movie.id) return;
      setState(() {
        _browseHeroDescription = description;
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
    final enabled =
        _tvSearchEditing || _isEditingText || !_remoteMenuMode;
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
      _remoteSearchSelected = true;      // apre il campo TextField
      _remoteSearchIconFocused = false;  // icona non più solo evidenziata
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
    _revealFullscreenOverlay();
    if (_livePlayerActive) {
      if (key == LogicalKeyboardKey.arrowUp) {
        unawaited(_playAdjacentLiveChannel(-1));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        unawaited(_playAdjacentLiveChannel(1));
        return KeyEventResult.handled;
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
          final movie =
              movies[_tvContentIndex.clamp(0, movies.length - 1)];
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
      AppSection.movies => _selectedMovie == null
          ? (_isAndroidTv ? 1 : _catalogGridColumns)
          : 1,
      AppSection.series => _selectedSeries == null
          ? (_isAndroidTv ? 1 : _catalogGridColumns)
          : 1,
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
      AppSection.movies => _selectedMovie == null
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
      AppSection.home => _homeTargets.isEmpty
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
    _previewLiveChannelAt(0);
  }

  void _setEpgCategory(String id) {
    setState(() {
      _liveCategoryId = id;
      _tvContentIndex = 0;
      _selectedLiveEpg = const [];
    });
    _previewEpgChannelAt(0);
    unawaited(_loadEpgPage(force: true));
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
    if (_filteredLive.isEmpty) return;
    final channel = _filteredLive[index.clamp(0, _filteredLive.length - 1)];
    if (_selectedLiveChannel?.id == channel.id && _selectedLiveEpg.isNotEmpty) {
      return;
    }
    setState(() {
      _selectedLiveChannel = channel;
      _playerTitle = channel.name;
      _status = 'Canale selezionato: ${channel.name}';
    });
    unawaited(_recordRecentLiveChannel(channel.id));
    unawaited(_loadShortEpg(channel));
  }

  void _previewEpgChannelAt(int index) {
    if (_epgChannels.isEmpty) return;
    final channel = _epgChannels[index.clamp(0, _epgChannels.length - 1)];
    if (_selectedLiveChannel?.id == channel.id && _selectedLiveEpg.isNotEmpty) {
      return;
    }
    setState(() {
      _selectedLiveChannel = channel;
      _epgProgrammeIndex = 0;
      _status = 'Guida TV: ${channel.name}';
    });
    unawaited(_loadShortEpg(channel));
  }

  int _channelIndexOf(List<LiveChannel> channels, LiveChannel channel) {
    final index = channels.indexWhere((item) => item.id == channel.id);
    return index < 0 ? 0 : index;
  }

  void _moveEpgProgrammeSelection(int delta) {
    final channel = _selectedLiveChannel;
    if (channel == null) return;
    final programmes = _fullscreenOverlayProgrammes(channel);
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
    final now = DateTime.now();
    final items = source
        .where(
          (programme) =>
              _isLiveProgramme(programme) ||
              _canReplayProgramme(channel, programme) ||
              (programme.start?.isAfter(now) ?? false),
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
    if (items.length <= 12) return items;
    final liveIndex = items.indexWhere(_isLiveProgramme);
    if (liveIndex < 0) return items.take(12).toList();
    final start = (liveIndex - 4).clamp(0, items.length - 12).toInt();
    return items.skip(start).take(12).toList();
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
    final programmes = _fullscreenOverlayProgrammes(channel);
    if (programmes.isEmpty) return null;
    return programmes[_epgProgrammeIndex.clamp(0, programmes.length - 1)];
  }

  bool _isLiveProgramme(EpgProgramme programme) => _epgIsLiveNow(programme);

  bool _canReplayProgramme(LiveChannel channel, EpgProgramme programme) {
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    if (!channel.hasCatchup || start == null || end == null) return false;
    if (end.isAfter(now) || !end.isAfter(start)) return false;
    final days = channel.catchupDays > 0 ? channel.catchupDays : 7;
    return start.isAfter(now.subtract(Duration(days: days)));
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
          await _loadShortEpg(channel);
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

  String _watchLaterMoviesKey(XtreamProfile profile) =>
      '$_watchLaterMoviesPrefix${profile.id}';

  Future<void> _loadUserLists(XtreamProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    final favorites = prefs
        .getStringList(_favoriteMoviesKey(profile))
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
      _watchLaterMoviesKey(profile),
      _watchLaterMovieIds.map((id) => id.toString()).toList()..sort(),
    );
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
    _epgByChannel.clear();
    _movies = const [];
    _selectedMovie = null;
    _selectedMovieDescription = '';
    _series = const [];
    _selectedSeries = null;
    _selectedSeriesDescription = '';
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
    _traceTv('play live channel=${channel.name} id=${channel.id}');
    setState(() {
      _selectedLiveChannel = channel;
      _livePlayerActive = true;
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

    if (Platform.isAndroid && !isTizenRuntime) {
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
      );
      if (opened) {
        _enterFullscreenOnPhonePlayback(force: Platform.isIOS);
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
    if (!opened && mounted) {
      setState(
        () => _status = 'Riproduzione live non riuscita: ${channel.name}',
      );
    }
    unawaited(_loadShortEpg(channel));
  }

  Future<void> _playProgramme(
    LiveChannel channel,
    EpgProgramme programme,
  ) async {
    final profile = _profile;
    if (profile == null) return;
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    if (start != null &&
        end != null &&
        start.isBefore(now) &&
        end.isAfter(now)) {
      await _playLive(channel);
      return;
    }
    final catchupUrl = XtreamClient(profile).catchupUrl(channel, programme);
    if (catchupUrl == null) {
      setState(() {
        _status = 'Registrato non disponibile per ${programme.title}.';
      });
      return;
    }
    setState(() {
      _selectedLiveChannel = channel;
      _livePlayerActive = true;
    });
    unawaited(_recordRecentLiveChannel(channel.id));
    final opened = await _openMedia(
      catchupUrl,
      '${channel.name} - ${programme.title}',
      preferApple: Platform.isIOS,
    );
    if (opened) {
      _enterFullscreenOnPhonePlayback(force: Platform.isIOS);
    }
  }

  Future<void> _openLiveProgrammeFromGuide(
    LiveChannel channel,
    EpgProgramme programme,
  ) async {
    setState(() {
      _section = AppSection.live;
      _selectedLiveChannel = channel;
      _selectedLiveEpg = _epgByChannel[channel.id] ?? const [];
    });
    await _playProgramme(channel, programme);
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
    final opened = await _openMedia(
      XtreamClient(profile).vodUrl(movie),
      movie.name,
      startAt: startAt,
    );
    if (opened) {
      _enterFullscreenOnPhonePlayback(force: Platform.isIOS);
      unawaited(_recordRecentMovie(movie.id));
    } else {
      await _endPlaybackTracking();
    }
    if (!opened && mounted) {
      setState(() => _status = 'Riproduzione film non riuscita: ${movie.name}');
    }
  }

  Future<void> _downloadMovie(VodMovie movie) async {
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
    final url = XtreamClient(profile).vodUrl(movie);
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
    final width = MediaQuery.maybeOf(context)?.size.width ?? 1200;
    if (width >= 900) return;
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
      _playerTitle = movie.name;
      _status = 'Dettaglio film: ${movie.name}';
    });
    if (profile == null) return;
    if (_selectedMovieDescription.trim().isNotEmpty) return;
    try {
      final description = await XtreamClient(profile).vodDescription(movie);
      _movieDescriptionCache[movie.id] = description;
      if (!mounted || _selectedMovie?.id != movie.id) return;
      setState(() => _selectedMovieDescription = description);
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
      _seriesEpisodes = const [];
      _seriesDetailLoading = true;
      _status = 'Caricamento episodi: ${show.name}';
    });
    try {
      final detail = await XtreamClient(profile).seriesDetail(show);
      _seriesDescriptionCache[show.id] = detail.description;
      if (!mounted) return;
      setState(() {
        _selectedSeriesDescription = detail.description;
        _seriesEpisodes = detail.episodes;
        _status = 'Episodi caricati: ${show.name} (${detail.episodes.length})';
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'Episodi non caricati: $error');
    } finally {
      if (mounted) setState(() => _seriesDetailLoading = false);
    }
  }

  Future<void> _playEpisode(SeriesEpisode episode, {bool fromStart = false}) async {
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
      unawaited(
        _setLastVodEpisode(seriesId: show.id, episodeId: episode.id),
      );
    }
    final opened = await _openMedia(
      XtreamClient(profile).episodeUrl(episode),
      show == null ? episode.title : '${show.name} - ${episode.title}',
      startAt: startAt,
    );
    if (opened) {
      _enterFullscreenOnPhonePlayback();
    } else {
      await _endPlaybackTracking();
    }
    if (!opened && mounted) {
      setState(
        () => _status = 'Riproduzione episodio non riuscita: ${episode.title}',
      );
    }
  }

  bool get _shouldUsePhoneFullscreenPlayback {
    if (!mounted || !(Platform.isAndroid || Platform.isIOS)) {
      return false;
    }
    final mediaQuery = MediaQuery.maybeOf(context);
    final shortestSide = mediaQuery?.size.shortestSide ?? 9999;
    return shortestSide < 700;
  }

  void _enterFullscreenOnPhonePlayback({bool force = false}) {
    if ((!force && !_shouldUsePhoneFullscreenPlayback) || _playerFocusMode) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _playerFocusMode ||
          (!force && !_shouldUsePhoneFullscreenPlayback)) {
        return;
      }
      _togglePlayerFocusMode();
    });
  }

  Future<bool> _openMedia(
    String url,
    String title, {
    bool preferApple = false,
    Duration? startAt,
  }) async {
    setState(() {
      _playerTitle = title;
      _status = 'Apertura: $title';
    });
    if (preferApple || _useAppleVideoBackend) {
      final opened = await _openAppleMedia(url, title, startAt: startAt);
      if (opened) return true;
      if (preferApple && !_useAppleVideoBackend) {
        return _openMediaKitMedia(url, startAt: startAt);
      }
      return false;
    }
    if (isTizenRuntime) {
      for (final candidate in _tizenMediaCandidates(url)) {
        final opened = await _openTizenMedia(candidate, title, startAt: startAt);
        if (opened) return true;
      }
      return false;
    }
    return _openMediaKitMedia(url, startAt: startAt);
  }

  Future<bool> _openMediaKitMedia(String url, {Duration? startAt}) async {
    final appleController = _appleVideoController;
    _appleVideoController = null;
    if (mounted && appleController != null) setState(() {});
    try {
      await appleController?.pause();
    } catch (_) {}
    await appleController?.dispose();

    final mediaPlayer = _player;
    if (mediaPlayer == null) return false;
    final isLive = _isLivePlaybackUrl(url);
    await mediaPlayer.open(
      Media(
        url,
        httpHeaders: _profile == null
            ? const {}
            : _mediaHttpHeaders(url, _profile),
      ),
      play: true,
    );
    if (startAt != null && startAt.inMilliseconds > 0) {
      await mediaPlayer.seek(startAt);
    }
    if (Platform.isAndroid && isLive) {
      final hasVideo = await _waitForMediaKitVideoFrame(mediaPlayer);
      if (!hasVideo) {
        try {
          await mediaPlayer.stop();
        } catch (_) {}
        return false;
      }
      _syncMediaKitSurfaceAfterLayoutChange();
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

  Future<void> _loadShortEpg(LiveChannel channel) async {
    final profile = _profile;
    if (profile == null) return;
    setState(() {
      _epgLoading = true;
      _selectedLiveEpg = const [];
    });
    try {
      final client = XtreamClient(profile);
      var epg = const <EpgProgramme>[];
      Object? shortEpgError;
      try {
        epg = await client.shortEpg(channel, limit: 16);
      } catch (error) {
        shortEpgError = error;
      }
      try {
        final xmltv = await client.xmlTvEpgForChannels([channel], limit: 32);
        final xmltvEpg = xmltv[channel.id] ?? const <EpgProgramme>[];
        if (xmltvEpg.isNotEmpty) {
          epg = _mergeProgrammes(epg, xmltvEpg);
        }
      } catch (_) {
        // Keep get_short_epg results: contextual EPG should still be usable.
      }
      if (!mounted) return;
      final guideItems = _guideProgrammesFrom(channel, epg);
      setState(() {
        _selectedLiveEpg = epg;
        _epgByChannel[channel.id] = epg;
        _epgProgrammeIndex = _defaultProgrammeIndex(guideItems);
        if (epg.isEmpty && shortEpgError != null) {
          _status = 'EPG non caricato: $shortEpgError';
        }
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'EPG non caricato: $error');
    } finally {
      if (mounted) setState(() => _epgLoading = false);
    }
  }

  Future<void> _loadEpgPage({bool force = false}) async {
    final profile = _profile;
    if (profile == null || _liveChannels.isEmpty) return;
    setState(() {
      _epgLoading = true;
      _status = 'Caricamento guida TV...';
    });
    final client = XtreamClient(profile);
    final channels = _epgChannels.take(80).toList();
    if (channels.isEmpty) {
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
    setState(() => _status = 'Guida TV: caricamento XMLTV...');
    try {
      final xmlTvProgrammes = await client.xmlTvEpgForChannels(
        channels,
        limit: 48,
      );
      if (!mounted) return;
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
      if (mounted) {
        setState(() => _status = 'XMLTV non caricato: $error');
      }
    }

    final missingChannels = channels
        .where((channel) => (_epgByChannel[channel.id] ?? const []).isEmpty)
        .take(12)
        .toList();
    if (missingChannels.isNotEmpty) {
      var loaded = channels.length - missingChannels.length;
      var fallbackLoaded = 0;
      var fallback429Count = 0;
      for (final channel in missingChannels) {
        if (!mounted) return;
        try {
          final programmes = await client.shortEpg(channel, limit: 12);
          if (!mounted) return;
          setState(() {
            if (programmes.isNotEmpty) {
              final existing =
                  _epgByChannel[channel.id] ?? const <EpgProgramme>[];
              _epgByChannel[channel.id] = _mergeProgrammes(
                existing,
                programmes,
              );
              fallbackLoaded += 1;
            } else {
              _epgByChannel[channel.id] = const [];
            }
            loaded += 1;
            _status =
                'Guida TV fallback: $loaded/${channels.length} canali '
                '($fallbackLoaded da get_short_epg)';
          });
        } catch (error) {
          if (!mounted) return;
          if (error.toString().contains('HTTP 429')) {
            fallback429Count += 1;
          }
          setState(() {
            _epgByChannel[channel.id] = const [];
            _status =
                'Guida TV fallback limitato'
                '${fallback429Count > 0 ? ' ($fallback429Count rate limit)' : ''}: $error';
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    if (mounted) {
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
    for (final programme in [...primary, ...secondary]) {
      final key =
          '${programme.start?.millisecondsSinceEpoch ?? 0}|'
          '${programme.end?.millisecondsSinceEpoch ?? 0}|'
          '${programme.title.toLowerCase()}';
      byKey[key] = programme;
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
            milliseconds: next.inMilliseconds.clamp(
              0,
              duration.inMilliseconds,
            ),
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
              .then((_) => _syncMediaKitSurfaceAfterLayoutChange())
              .catchError((error) {
            if (mounted) {
              setState(() => _status = 'Fullscreen non disponibile: $error');
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

  void _revealFullscreenOverlay() {
    if (!_playerFocusMode) return;
    _fullscreenOverlayTimer?.cancel();
    if (!_fullscreenOverlayVisible && mounted) {
      setState(() => _fullscreenOverlayVisible = true);
    }
    _scheduleFullscreenOverlayHide();
  }

  void _scheduleFullscreenOverlayHide() {
    _fullscreenOverlayTimer?.cancel();
    if (_vodToolbarIndex >= 0) return;
    _fullscreenOverlayTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playerFocusMode && _vodToolbarIndex < 0) {
        setState(() => _fullscreenOverlayVisible = false);
      }
    });
  }

  Future<void> _playAdjacentLiveChannel(int direction) async {
    final current = _selectedLiveChannel;
    if (current == null) return;
    final channels = _filteredLive.isNotEmpty
        ? _filteredLive
        : _playableLiveChannels;
    if (channels.isEmpty) return;
    final currentIndex = channels.indexWhere((item) => item.id == current.id);
    final base = currentIndex < 0 ? 0 : currentIndex;
    final nextIndex = (base + direction).clamp(0, channels.length - 1).toInt();
    if (nextIndex == base && currentIndex >= 0) return;
    final next = channels[nextIndex];
    _traceTv('fullscreen channel switch ${current.name} -> ${next.name}');
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
    return _sortMovies(source, _movieSort).take(350).toList();
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
    return _sortSeries(source, _seriesSort).take(350).toList();
  }

  List<VodMovie> _sortMovies(List<VodMovie> movies, String sort) {
    final copy = [...movies];
    if (sort == 'az') {
      copy.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return copy;
  }

  List<SeriesShow> _sortSeries(List<SeriesShow> shows, String sort) {
    final copy = [...shows];
    if (sort == 'az') {
      copy.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return copy;
  }

  String _categoryName(List<XtreamCategory> categories, String id) {
    if (id.isEmpty) return 'Tutte le categorie';
    for (final category in categories) {
      if (category.id == id) return category.name;
    }
    return 'Categoria $id';
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

  @override
  Widget build(BuildContext context) {
    final compactLayout = !(_isAndroidTv || lelegTvShellActive) &&
        _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
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
                      opacity: (_fullscreenOverlayVisible || _vodToolbarIndex >= 0)
                          ? 1
                          : 0,
                      duration: const Duration(milliseconds: 180),
                      child: IgnorePointer(
                        ignoring:
                            !(_fullscreenOverlayVisible || _vodToolbarIndex >= 0),
                        child: _TvVodToolbar(
                          focusIndex: _vodToolbarIndex,
                          playing: _player?.state.playing ?? false,
                          audioLabel: _player == null
                              ? 'Auto'
                              : _trackLabel(_player!.state.track.audio),
                          subtitleLabel: _player == null
                              ? 'Off'
                              : _trackLabel(_player!.state.track.subtitle),
                        ),
                      ),
                    ),
                  ),
                if (_livePlayerActive)
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
      child: compactLayout
          ? Scaffold(
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
                          border: Border(
                            bottom: BorderSide(color: LelegColors.line),
                          ),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () =>
                                  Scaffold.of(context).openDrawer(),
                              icon: const Icon(Icons.menu),
                              tooltip: 'Menu',
                            ),
                            const SizedBox(width: 6),
                            const Expanded(child: _Brand(compact: true)),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: FocusTraversalGroup(
                        policy: ReadingOrderTraversalPolicy(),
                        child: FocusScope(
                          node: _contentFocusScopeNode,
                          descendantsAreFocusable: !_remoteMenuMode,
                          child: _buildSection(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : (_isAndroidTv || lelegTvShellActive)
          ? Scaffold(
              backgroundColor: LelegColors.bg,
              body: _TvUiScope(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TvTopNavigation(
                        section: _section,
                        remoteSection:
                            _remoteMenuMode ? _remoteSection : null,
                        remoteSearchSelected: _remoteSearchSelected,
                        remoteSearchIconFocused: _remoteSearchIconFocused,
                        sections: _remoteSections,
                        sectionLabel: _sectionLabel,
                        queryController: _searchController,
                        searchFocusNode: _searchFocusNode,
                        profile: _profile,
                        status: _status,
                        loading: _loading ||
                            _epgLoading ||
                            _seriesDetailLoading,
                        onQueryChanged: (value) =>
                            setState(() => _query = value),
                        onResetSearch: _clearSearchAndReturnHome,
                        onSectionChanged: (section) =>
                            unawaited(_changeSection(section)),
                        onOpenSettings: () => unawaited(
                          _changeSection(AppSection.settings),
                        ),
                        onOpenSearch: () =>
                            unawaited(_enterTvSearchEditing()),
                      ),
                      Expanded(
                        child: FocusTraversalGroup(
                          policy: ReadingOrderTraversalPolicy(),
                          child: FocusScope(
                            node: _contentFocusScopeNode,
                            descendantsAreFocusable: !_remoteMenuMode,
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
                        descendantsAreFocusable: !_remoteMenuMode,
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
            : _guideProgrammesFrom(_selectedLiveChannel!, _selectedLiveEpg),
        epgLoading: _epgLoading,
        selectedChannel: _selectedLiveChannel,
        onSelectChannel: (channel) =>
            _previewLiveChannelAt(_channelIndexOf(_filteredLive, channel)),
        onWatchProgramme: _playProgramme,
      ),
      AppSection.movies =>
        _selectedMovie == null
            ? (_isAndroidTv
                  ? TvFeaturedBrowseScreen<VodMovie>(
                      kindLabel: 'FILM',
                      rowTitle: _movieCategoryId.isEmpty
                          ? 'Catalogo film'
                          : _categoryName(
                              _movieCategories,
                              _movieCategoryId,
                            ),
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
                      onCategoryChanged: _setMovieCategory,
                      onOpen: _openMovie,
                      isFavorite: (movie) =>
                          _favoriteMovieIds.contains(movie.id),
                      onToggleFavorite: _toggleFavoriteMovie,
                      heroActionSelected: _browseHeroActionSelected,
                    )
                  : (_movieCategoryId.isEmpty
                        ? CatalogCategoryRowsScreen(
                            title: 'Film',
                            categories: _movieCategories,
                            items: _movies,
                            categoryName: (id) =>
                                _categoryName(_movieCategories, id),
                            onPlay: _openMovie,
                          )
                        : MoviesScreen(
                            tvSelectedIndex:
                                _remoteMenuMode ? null : _tvContentIndex,
                            movies: _filteredMovies,
                            allCount: _movies.length,
                            categories: _movieCategories,
                            selectedCategoryId: _movieCategoryId,
                            sort: _movieSort,
                            categoryName: (id) =>
                                _categoryName(_movieCategories, id),
                            onCategoryChanged: _setMovieCategory,
                            onSortChanged: (sort) =>
                                setState(() => _movieSort = sort),
                            onPlay: _openMovie,
                            onFavorite: _toggleFavoriteMovie,
                            onWatchLater: _toggleWatchLaterMovie,
                            onDownload: _isAndroidTv ? null : _downloadMovie,
                            favorites: _favoriteMovieIds,
                            watchLater: _watchLaterMovieIds,
                          )))
            : MovieDetailScreen(
                movie: _selectedMovie!,
                description: _selectedMovieDescription,
                category: _categoryName(
                  _movieCategories,
                  _selectedMovie!.categoryId,
                ),
                isFavorite: _favoriteMovieIds.contains(_selectedMovie!.id),
                onToggleFavorite: () =>
                    _toggleFavoriteMovie(_selectedMovie!),
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
      AppSection.favorites => _isAndroidTv
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
                          : _categoryName(
                              _seriesCategories,
                              _seriesCategoryId,
                            ),
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
                      onCategoryChanged: _setSeriesCategory,
                      onOpen: _openSeries,
                    )
                  : (_seriesCategoryId.isEmpty
                        ? SeriesCategoryRowsScreen(
                            title: 'Serie',
                            categories: _seriesCategories,
                            items: _series,
                            categoryName: (id) =>
                                _categoryName(_seriesCategories, id),
                            onOpen: _openSeries,
                          )
                        : SeriesScreen(
                            tvSelectedIndex:
                                _remoteMenuMode ? null : _tvContentIndex,
                            shows: _filteredSeries,
                            allCount: _series.length,
                            categories: _seriesCategories,
                            selectedCategoryId: _seriesCategoryId,
                            sort: _seriesSort,
                            categoryName: (id) =>
                                _categoryName(_seriesCategories, id),
                            onCategoryChanged: _setSeriesCategory,
                            onSortChanged: (sort) =>
                                setState(() => _seriesSort = sort),
                            onOpen: _openSeries,
                          )))
            : SeriesDetailScreen(
                show: _selectedSeries!,
                description: _selectedSeriesDescription,
                episodes: _seriesEpisodes,
                loading: _seriesDetailLoading,
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
        selectedProgrammeIndex: _remoteMenuMode ? null : _epgProgrammeIndex,
        selectedProgramme: _selectedLiveChannel == null
            ? null
            : _selectedGuideProgrammeFor(_selectedLiveChannel!),
        channels: _epgChannels,
        categories: _liveCategories,
        selectedCategoryId: _liveCategoryId,
        categoryName: (id) => _categoryName(_liveCategories, id),
        selectedChannel: _selectedLiveChannel,
        epgByChannel: _epgByChannel,
        loading: _epgLoading,
        onCategoryChanged: _setEpgCategory,
        onRefresh: () => unawaited(_loadEpgPage(force: true)),
        onSelectChannel: (channel) =>
            _previewEpgChannelAt(_channelIndexOf(_epgChannels, channel)),
        onWatchProgramme: _openLiveProgrammeFromGuide,
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
      padding: const EdgeInsets.fromLTRB(TvUi.contentPadding, 0, TvUi.contentPadding, 0),
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
                    color: selected ? LelegColors.accent : LelegColors.accent.withValues(alpha: 0.5),
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
    final mobile = !isTv && _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
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
        final compact = _useCompactAdaptiveConstraints(constraints);
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
        'Timeline e archivio',
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
    final cardHeight = tv ? (TvUi.cardWidth * 9 / 16) : (mobile ? 240.0 : 290.0);
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
                  : _MoviePosterCard(
                      movie: movies[index],
                      onPlay: onPlayMovie,
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
    required this.selectedChannel,
    required this.onSelectChannel,
    required this.onWatchProgramme,
    super.key,
  });

  final int? tvSelectedIndex;
  final List<LiveChannel> channels;
  final int allCount;
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final String Function(String id) categoryName;
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
  final LiveChannel? selectedChannel;
  final ValueChanged<LiveChannel> onSelectChannel;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onWatchProgramme;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'Live TV',
      eyebrow: '${channels.length} di $allCount canali',
      hideHeader: preferTvLayout,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mobile =
              !preferTvLayout && _useCompactAdaptiveConstraints(constraints);
          final channelList = channels.isEmpty
              ? const _EmptyState(message: 'Nessun canale caricato.')
              : ListView.separated(
                  padding: EdgeInsets.fromLTRB(
                    preferTvLayout ? 8 : (mobile ? 16 : 20),
                    0,
                    preferTvLayout ? 8 : (mobile ? 16 : 20),
                    preferTvLayout ? 8 : (mobile ? 16 : 20),
                  ),
                  itemCount: channels.length,
                  separatorBuilder: (_, _) =>
                      SizedBox(height: preferTvLayout ? 4 : 8),
                  itemBuilder: (_, index) {
                    final channel = channels[index];
                    return _ChannelTile(
                      channel: channel,
                      onOpen: onSelectChannel,
                      onPlay: onPlay,
                      category: categoryName(channel.categoryId),
                      selected: tvSelectedIndex == index,
                      compact: preferTvLayout,
                    );
                  },
                );
          final playerPane = Padding(
            padding: EdgeInsets.all(preferTvLayout ? 10 : (mobile ? 16 : 24)),
            child: mobile
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 240,
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
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 280,
                        child: _EpgProgrammeList(
                          programmes: epg,
                          loading: epgLoading,
                          emptyMessage:
                              'Seleziona un canale per vedere la guida.',
                          channel: selectedChannel,
                          onWatch: onWatchProgramme,
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(
                        flex: 5,
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
                      const SizedBox(height: 14),
                      Expanded(
                        flex: 3,
                        child: _EpgProgrammeList(
                          programmes: epg,
                          loading: epgLoading,
                          emptyMessage:
                              'Seleziona un canale per vedere la guida.',
                          channel: selectedChannel,
                          onWatch: onWatchProgramme,
                        ),
                      ),
                    ],
                  ),
          );
          if (mobile) {
            final selectedInfo = selectedChannel == null
                ? const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: _InlineNotice(
                      text:
                          'Tocca un canale per aprire il player in orizzontale e vedere qui la guida estesa.',
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: LelegColors.surface2,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: LelegColors.line),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selectedChannel!.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            categoryName(selectedChannel!.categoryId),
                            style: const TextStyle(
                              color: LelegColors.muted,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () => onPlay(selectedChannel!),
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                              ),
                              icon: const Icon(Icons.play_arrow),
                              label: const Text(
                                'Apri player',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 112,
                            child: _CompactEpgRail(
                              programmes: epg,
                              loading: epgLoading,
                              channel: selectedChannel,
                              onWatch: onWatchProgramme,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
            return Column(
              children: [
                _CatalogToolbar(
                  categories: categories,
                  selectedCategoryId: selectedCategoryId,
                  categoryName: categoryName,
                  onCategoryChanged: onCategoryChanged,
                ),
                _QuickCategoryStrip(
                  categories: categories,
                  selectedCategoryId: selectedCategoryId,
                  onCategoryChanged: onCategoryChanged,
                ),
                selectedInfo,
                const SizedBox(height: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: LelegColors.surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: LelegColors.line),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: channelList,
                      ),
                    ),
                  ),
                ),
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
          return Row(
            children: [
              SizedBox(
                width: 390,
                child: Column(
                  children: [
                    _CatalogToolbar(
                      categories: categories,
                      selectedCategoryId: selectedCategoryId,
                      categoryName: categoryName,
                      onCategoryChanged: onCategoryChanged,
                    ),
                    if (categories.isNotEmpty)
                      _QuickCategoryStrip(
                        categories: categories,
                        selectedCategoryId: selectedCategoryId,
                        onCategoryChanged: onCategoryChanged,
                      ),
                    Expanded(child: channelList),
                  ],
                ),
              ),
              const VerticalDivider(width: 1, color: LelegColors.line),
              Expanded(child: playerPane),
            ],
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
                  isFavorite: isFavorite == null
                      ? null
                      : isFavorite!(selected),
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
                        categories.isNotEmpty)
                      _QuickCategoryStrip(
                        categories: categories,
                        selectedCategoryId: selectedCategoryId,
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
                          color: isFavorite == true
                              ? LelegColors.accent
                              : null,
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
              separatorBuilder: (_, _) => SizedBox(
                height: TvUi.isActive(context) ? TvUi.rowGap : 24,
              ),
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
    super.key,
  });

  final String title;
  final List<XtreamCategory> categories;
  final List<SeriesShow> items;
  final String Function(String id) categoryName;
  final ValueChanged<SeriesShow> onOpen;

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
              separatorBuilder: (_, _) => SizedBox(
                height: TvUi.isActive(context) ? TvUi.rowGap : 24,
              ),
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
                          return _SeriesPosterCard(
                            show: show,
                            category: categoryName(show.categoryId),
                            onOpen: onOpen,
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
    this.onDownload,
    this.title = 'Film',
    this.allCount,
    this.categories = const [],
    this.selectedCategoryId = '',
    this.sort = 'default',
    this.categoryName,
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
  final ValueChanged<String>? onCategoryChanged;
  final ValueChanged<String>? onSortChanged;
  final ValueChanged<VodMovie> onPlay;
  final ValueChanged<VodMovie> onFavorite;
  final ValueChanged<VodMovie> onWatchLater;
  final ValueChanged<VodMovie>? onDownload;
  final Set<int> favorites;
  final Set<int> watchLater;

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
              onCategoryChanged: onCategoryChanged!,
              sort: sort,
              onSortChanged: onSortChanged,
            ),
          if (onCategoryChanged != null && categories.isNotEmpty)
            _QuickCategoryStrip(
              categories: categories,
              selectedCategoryId: selectedCategoryId,
              onCategoryChanged: onCategoryChanged!,
            ),
          Expanded(
            child: movies.isEmpty
                ? const _EmptyState(message: 'Nessun titolo da mostrare.')
                : GridView.builder(
                    padding: EdgeInsets.all(mobile ? 16 : 28),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: mobile ? 170 : 210,
                      mainAxisExtent: mobile ? 288 : 332,
                      crossAxisSpacing: mobile ? 12 : 18,
                      mainAxisSpacing: mobile ? 14 : 20,
                    ),
                    itemCount: movies.length,
                    itemBuilder: (_, index) {
                      final movie = movies[index];
                      return _MoviePosterCard(
                        movie: movie,
                        category: categoryName?.call(movie.categoryId),
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
                            color: tvActionIndex ==
                                    (canResume ? 3 : 2)
                                ? LelegColors.accent
                                : LelegColors.line,
                            width: tvActionIndex == (canResume ? 3 : 2)
                                ? 2
                                : 1,
                          ),
                        ),
                      ),
                      if (canResume && onResume != null && onRestart != null) ...[
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
                          label: Text(
                            isFavorite ? 'Preferito' : 'Preferiti',
                          ),
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
    final mobile = _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
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
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
                if (onDownload != null)
                  OutlinedButton.icon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download),
                    label: const Text('Download'),
                  ),
              ],
            ),
            const SizedBox(height: 18),
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
                                    label: category.isEmpty ? 'Film' : category,
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
    required this.onCategoryChanged,
    required this.onSortChanged,
    required this.onOpen,
    super.key,
  });

  final int? tvSelectedIndex;
  final List<SeriesShow> shows;
  final int allCount;
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final String sort;
  final String Function(String id) categoryName;
  final ValueChanged<String> onCategoryChanged;
  final ValueChanged<String> onSortChanged;
  final ValueChanged<SeriesShow> onOpen;

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
            onCategoryChanged: onCategoryChanged,
            sort: sort,
            onSortChanged: onSortChanged,
          ),
          if (categories.isNotEmpty)
            _QuickCategoryStrip(
              categories: categories,
              selectedCategoryId: selectedCategoryId,
              onCategoryChanged: onCategoryChanged,
            ),
          Expanded(
            child: shows.isEmpty
                ? const _EmptyState(message: 'Nessuna serie da mostrare.')
                : GridView.builder(
                    padding: EdgeInsets.all(mobile ? 16 : 28),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: mobile ? 170 : 210,
                      mainAxisExtent: mobile ? 280 : 320,
                      crossAxisSpacing: mobile ? 12 : 18,
                      mainAxisSpacing: mobile ? 14 : 20,
                    ),
                    itemCount: shows.length,
                    itemBuilder: (_, index) => _SeriesPosterCard(
                      show: shows[index],
                      category: categoryName(shows[index].categoryId),
                      onOpen: onOpen,
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
              height: MediaQuery.sizeOf(context).height * TvUi.seriesHeroFraction,
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
    final mobile = _useCompactAdaptiveLayout(MediaQuery.sizeOf(context));
    return _PageScaffold(
      title: show.name,
      eyebrow: '${episodes.length} episodi',
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
                    itemBuilder: (_, index) =>
                        _EpisodeTile(episode: episodes[index], onPlay: onPlay),
                  ),
              ],
            )
          : Row(
              children: [
                SizedBox(
                  width: 430,
                  child: Column(
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
    required this.categoryName,
    required this.selectedChannel,
    required this.epgByChannel,
    required this.loading,
    required this.onCategoryChanged,
    required this.onRefresh,
    required this.onSelectChannel,
    required this.onWatchProgramme,
    super.key,
  });

  final int? tvSelectedIndex;
  final int? selectedProgrammeIndex;
  final EpgProgramme? selectedProgramme;
  final List<LiveChannel> channels;
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final String Function(String id) categoryName;
  final LiveChannel? selectedChannel;
  final Map<int, List<EpgProgramme>> epgByChannel;
  final bool loading;
  final ValueChanged<String> onCategoryChanged;
  final VoidCallback onRefresh;
  final ValueChanged<LiveChannel> onSelectChannel;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onWatchProgramme;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'Guida TV',
      eyebrow: loading
          ? 'Caricamento programmi...'
          : '${channels.length} canali',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 16),
            child: Row(
              children: [
                Expanded(
                  child: _ToolbarSelect<String>(
                    label: 'Categoria',
                    value:
                        [
                          '',
                          ...categories.map((item) => item.id),
                        ].contains(selectedCategoryId)
                        ? selectedCategoryId
                        : '',
                    items: ['', ...categories.map((item) => item.id)],
                    itemLabel: categoryName,
                    onChanged: onCategoryChanged,
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Aggiorna'),
                ),
              ],
            ),
          ),
          Expanded(
            child: channels.isEmpty
                ? const _EmptyState(message: 'Nessun canale caricato.')
                : _EpgGrid(
                    channels: channels.take(80).toList(),
                    selectedChannel: selectedChannel,
                    epgByChannel: epgByChannel,
                    onSelectChannel: onSelectChannel,
                    onWatchProgramme: onWatchProgramme,
                    loading: loading,
                    selectedIndex: tvSelectedIndex,
                    selectedProgrammeIndex: selectedProgrammeIndex,
                    selectedProgramme: selectedProgramme,
                  ),
          ),
        ],
      ),
    );
  }
}

class _EpgGrid extends StatefulWidget {
  const _EpgGrid({
    required this.channels,
    required this.selectedChannel,
    required this.epgByChannel,
    required this.onSelectChannel,
    required this.onWatchProgramme,
    required this.loading,
    required this.selectedIndex,
    required this.selectedProgrammeIndex,
    required this.selectedProgramme,
  });

  final List<LiveChannel> channels;
  final LiveChannel? selectedChannel;
  final Map<int, List<EpgProgramme>> epgByChannel;
  final ValueChanged<LiveChannel> onSelectChannel;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onWatchProgramme;
  final bool loading;
  final int? selectedIndex;
  final int? selectedProgrammeIndex;
  final EpgProgramme? selectedProgramme;

  @override
  State<_EpgGrid> createState() => _EpgGridState();
}

class _EpgGridState extends State<_EpgGrid> {
  late DateTime _viewStart;

  @override
  void initState() {
    super.initState();
    _viewStart = _defaultViewStart();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const horizontalPadding = 56.0;
        final available = (constraints.maxWidth - horizontalPadding)
            .clamp(760.0, double.infinity)
            .toDouble();
        final channelWidth = (available * 0.24).clamp(210.0, 300.0).toDouble();
        const visibleHours = 8;
        final hourWidth = (available - channelWidth) / visibleHours;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _shiftWindow(-4),
                    icon: const Icon(Icons.chevron_left),
                    label: const Text('4h'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () =>
                        setState(() => _viewStart = _defaultViewStart()),
                    child: const Text('Ora'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _shiftWindow(4),
                    icon: const Icon(Icons.chevron_right),
                    label: const Text('4h'),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    _windowLabel(visibleHours),
                    style: const TextStyle(
                      color: LelegColors.muted,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 8),
              child: _EpgTimelineHeader(
                viewStart: _viewStart,
                channelWidth: channelWidth,
                hourWidth: hourWidth,
                visibleHours: visibleHours,
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                itemCount: widget.channels.length + (widget.loading ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, index) {
                  if (widget.loading && index == 0) {
                    return const _LoadingBand(
                      status: 'Caricamento guida TV...',
                    );
                  }
                  final channel =
                      widget.channels[index - (widget.loading ? 1 : 0)];
                  final channelIndex = index - (widget.loading ? 1 : 0);
                  return _EpgTimelineRow(
                    channel: channel,
                    programmes:
                        widget.epgByChannel[channel.id] ??
                        const <EpgProgramme>[],
                    active:
                        widget.selectedChannel?.id == channel.id ||
                        widget.selectedIndex == channelIndex,
                    selectedProgrammeIndex: widget.selectedIndex == channelIndex
                        ? widget.selectedProgrammeIndex
                        : null,
                    selectedProgramme: widget.selectedIndex == channelIndex
                        ? widget.selectedProgramme
                        : null,
                    viewStart: _viewStart,
                    channelWidth: channelWidth,
                    hourWidth: hourWidth,
                    visibleHours: visibleHours,
                    onSelectChannel: widget.onSelectChannel,
                    onWatchProgramme: widget.onWatchProgramme,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  DateTime _defaultViewStart() {
    return DateTime.now()
        .subtract(const Duration(hours: 2))
        .copyWith(minute: 0, second: 0, millisecond: 0, microsecond: 0);
  }

  void _shiftWindow(int hours) {
    setState(() => _viewStart = _viewStart.add(Duration(hours: hours)));
  }

  String _windowLabel(int visibleHours) {
    String fmt(DateTime value) => '${value.hour.toString().padLeft(2, '0')}:00';
    final end = _viewStart.add(Duration(hours: visibleHours));
    return '${fmt(_viewStart)} - ${fmt(end)}';
  }
}

class _EpgTimelineHeader extends StatelessWidget {
  const _EpgTimelineHeader({
    required this.viewStart,
    required this.channelWidth,
    required this.hourWidth,
    required this.visibleHours,
  });

  final DateTime viewStart;
  final double channelWidth;
  final double hourWidth;
  final int visibleHours;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: LelegColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LelegColors.line),
      ),
      child: Row(
        children: [
          SizedBox(
            width: channelWidth,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Canale',
                  style: TextStyle(
                    color: LelegColors.muted,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
          const VerticalDivider(width: 1, color: LelegColors.line),
          SizedBox(
            width: hourWidth * visibleHours,
            child: Row(
              children: [
                for (var i = 0; i < visibleHours; i++)
                  SizedBox(
                    width: hourWidth,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _formatHour(viewStart.add(Duration(hours: i))),
                          style: const TextStyle(
                            color: LelegColors.muted,
                            fontWeight: FontWeight.w800,
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
    );
  }

  String _formatHour(DateTime value) {
    return '${value.hour.toString().padLeft(2, '0')}:00';
  }
}

class _EpgTimelineRow extends StatelessWidget {
  const _EpgTimelineRow({
    required this.channel,
    required this.programmes,
    required this.active,
    required this.selectedProgrammeIndex,
    required this.selectedProgramme,
    required this.viewStart,
    required this.channelWidth,
    required this.hourWidth,
    required this.visibleHours,
    required this.onSelectChannel,
    required this.onWatchProgramme,
  });

  static const double rowHeight = 96;

  final LiveChannel channel;
  final List<EpgProgramme> programmes;
  final bool active;
  final int? selectedProgrammeIndex;
  final EpgProgramme? selectedProgramme;
  final DateTime viewStart;
  final double channelWidth;
  final double hourWidth;
  final int visibleHours;
  final ValueChanged<LiveChannel> onSelectChannel;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onWatchProgramme;

  @override
  Widget build(BuildContext context) {
    final visibleEnd = viewStart.add(Duration(hours: visibleHours));
    final visibleProgrammes = _withoutVisualOverlaps(
      programmes.where((programme) {
        final start = programme.start;
        final end = programme.end;
        final title = _cleanTitle(programme.title);
        if (title.isEmpty) return false;
        final duration = end == null || start == null
            ? Duration.zero
            : end.difference(start);
        final isImportant =
            _isLive(programme) || _canReplay(channel, programme);
        if (start == null || end == null) return false;
        final visibleStart = start.isBefore(viewStart) ? viewStart : start;
        final visibleStop = end.isAfter(visibleEnd) ? visibleEnd : end;
        final visibleMinutes = visibleStop.difference(visibleStart).inMinutes;
        final visibleWidth = (visibleMinutes / 60) * hourWidth;
        return (duration.inMinutes >= 8 || isImportant) &&
            (visibleWidth >= 54 || isImportant) &&
            end.isAfter(viewStart) &&
            start.isBefore(visibleEnd);
      }).toList(),
    );
    return Container(
      height: rowHeight,
      decoration: BoxDecoration(
        color: active ? LelegColors.surface3 : LelegColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active
              ? LelegColors.accent.withValues(alpha: 0.65)
              : LelegColors.line,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          InkWell(
            onTap: () => onSelectChannel(channel),
            child: SizedBox(
              width: channelWidth,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    _Logo(url: channel.logo, fallback: Icons.live_tv),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          if (channel.hasCatchup)
                            const Text(
                              'Archivio disponibile',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: LelegColors.accent,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
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
          const VerticalDivider(width: 1, color: LelegColors.line),
          SizedBox(
            width: hourWidth * visibleHours,
            height: rowHeight,
            child: Stack(
              children: [
                for (var i = 1; i <= visibleHours * 2; i++)
                  Positioned(
                    left: (i * 30 * hourWidth) / 60,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 1,
                      color: LelegColors.line.withValues(
                        alpha: i.isEven ? 0.8 : 0.35,
                      ),
                    ),
                  ),
                if (visibleProgrammes.isEmpty)
                  const Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.all(14),
                        child: Text(
                          'Nessun programma in questa finestra.',
                          style: TextStyle(color: LelegColors.muted),
                        ),
                      ),
                    ),
                  ),
                for (var i = 0; i < visibleProgrammes.length; i++)
                  _TimelineProgrammeCell(
                    channel: channel,
                    programme: visibleProgrammes[i],
                    selected:
                        active &&
                        (_sameProgramme(
                              visibleProgrammes[i],
                              selectedProgramme,
                            ) ||
                            selectedProgrammeIndex == i),
                    viewStart: viewStart,
                    hourWidth: hourWidth,
                    visibleHours: visibleHours,
                    onWatch: onWatchProgramme,
                  ),
                _NowLine(
                  viewStart: viewStart,
                  hourWidth: hourWidth,
                  visibleHours: visibleHours,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<EpgProgramme> _withoutVisualOverlaps(List<EpgProgramme> source) {
    final sorted = [...source]..sort((a, b) => a.start!.compareTo(b.start!));
    final result = <EpgProgramme>[];
    DateTime? lastEnd;
    for (final programme in sorted) {
      final start = programme.start!;
      final end = programme.end!;
      if (lastEnd != null && start.isBefore(lastEnd)) {
        final previous = result.isEmpty ? null : result.last;
        final previousEnd = previous?.end;
        if (previous != null &&
            previousEnd != null &&
            end.difference(start) > previousEnd.difference(previous.start!)) {
          result[result.length - 1] = programme;
          lastEnd = end;
        }
        continue;
      }
      result.add(programme);
      lastEnd = end;
    }
    return result;
  }

  bool _sameProgramme(EpgProgramme programme, EpgProgramme? selected) {
    if (selected == null) return false;
    return programme.title == selected.title &&
        programme.start == selected.start &&
        programme.end == selected.end;
  }

  String _cleanTitle(String value) {
    final title = value.trim();
    if (title.isEmpty) return '';
    final normalized = title.replaceAll(RegExp(r'[\s.·-]+'), '');
    if (normalized.length < 2) return '';
    return title;
  }

  bool _isLive(EpgProgramme programme) {
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    return start != null &&
        end != null &&
        start.isBefore(now) &&
        end.isAfter(now);
  }

  bool _canReplay(LiveChannel channel, EpgProgramme programme) {
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    if (!channel.hasCatchup || start == null || end == null) return false;
    if (end.isAfter(now) || !end.isAfter(start)) return false;
    final days = channel.catchupDays > 0 ? channel.catchupDays : 7;
    return start.isAfter(now.subtract(Duration(days: days)));
  }
}

class _TimelineProgrammeCell extends StatelessWidget {
  const _TimelineProgrammeCell({
    required this.channel,
    required this.programme,
    required this.selected,
    required this.viewStart,
    required this.hourWidth,
    required this.visibleHours,
    required this.onWatch,
  });

  final LiveChannel channel;
  final EpgProgramme programme;
  final bool selected;
  final DateTime viewStart;
  final double hourWidth;
  final int visibleHours;
  final void Function(LiveChannel channel, EpgProgramme programme) onWatch;

  @override
  Widget build(BuildContext context) {
    final start = programme.start!;
    final end = programme.end!;
    final viewEnd = viewStart.add(Duration(hours: visibleHours));
    final left = _offsetFor(start.isBefore(viewStart) ? viewStart : start);
    final right = _offsetFor(end.isAfter(viewEnd) ? viewEnd : end);
    final width = (right - left)
        .clamp(44.0, hourWidth * visibleHours)
        .toDouble();
    final live = _isLive(programme);
    final replayable = _canReplay(channel, programme);
    final color = live || replayable
        ? LelegColors.accent.withValues(alpha: 0.18)
        : LelegColors.bg;
    final borderColor = selected
        ? Colors.white.withValues(alpha: 0.92)
        : live || replayable
        ? LelegColors.accent.withValues(alpha: 0.55)
        : LelegColors.line;
    return Positioned(
      left: left,
      top: 8,
      width: width,
      height: _EpgTimelineRow.rowHeight - 18,
      child: Tooltip(
        richMessage: WidgetSpan(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  programme.title.trim(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _timeRange(programme),
                  style: const TextStyle(color: LelegColors.accent),
                ),
                if (programme.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    programme.description.trim(),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: LelegColors.muted),
                  ),
                ],
              ],
            ),
          ),
        ),
        waitDuration: const Duration(milliseconds: 250),
        child: Material(
          color: color,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: live || replayable
                ? () => onWatch(channel, programme)
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor, width: selected ? 2 : 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [
                      if (live) 'LIVE',
                      if (!live && replayable) 'REC',
                      _timeRange(programme),
                    ].join('  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: live || replayable
                          ? LelegColors.accent
                          : LelegColors.muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    programme.title.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
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

  double _offsetFor(DateTime value) {
    final minutes = value.difference(viewStart).inMinutes;
    return (minutes / 60) * hourWidth;
  }

  String _timeRange(EpgProgramme programme) {
    String format(DateTime? value) {
      if (value == null) return '--:--';
      return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    }

    return '${format(programme.start)} - ${format(programme.end)}';
  }

  bool _isLive(EpgProgramme programme) {
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    return start != null &&
        end != null &&
        start.isBefore(now) &&
        end.isAfter(now);
  }

  bool _canReplay(LiveChannel channel, EpgProgramme programme) {
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    if (!channel.hasCatchup || start == null || end == null) return false;
    if (end.isAfter(now) || !end.isAfter(start)) return false;
    final days = channel.catchupDays > 0 ? channel.catchupDays : 7;
    return start.isAfter(now.subtract(Duration(days: days)));
  }
}

class _NowLine extends StatelessWidget {
  const _NowLine({
    required this.viewStart,
    required this.hourWidth,
    required this.visibleHours,
  });

  final DateTime viewStart;
  final double hourWidth;
  final int visibleHours;

  @override
  Widget build(BuildContext context) {
    final minutes = DateTime.now().difference(viewStart).inMinutes;
    final left = (minutes / 60) * hourWidth;
    if (left < 0 || left > hourWidth * visibleHours) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      child: Container(width: 2, color: LelegColors.accent),
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
      child: Wrap(
        spacing: tv ? 8 : 12,
        runSpacing: tv ? 8 : 12,
        children: [
          _MetricPill(label: 'Live TV', value: liveCount.toString(), compact: tv),
          _MetricPill(label: 'Film', value: movieCount.toString(), compact: tv),
          _MetricPill(label: 'Serie', value: seriesCount.toString(), compact: tv),
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
          const _MetricPill(label: 'Cache', value: '24h', compact: true),
          const _MetricPill(label: 'Player', value: 'media_kit', compact: true),
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
                hint: tv ? 'Es. Casa, Sport…' : 'Es. Casa, Sport, Provider principale',
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
                        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
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
                        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
                        : null,
                    minimumSize: tv ? const Size(0, 32) : null,
                    textStyle: tv
                        ? const TextStyle(
                            fontSize: TvUi.body,
                            fontWeight: FontWeight.w700,
                          )
                        : null,
                    side: BorderSide(
                      color: reloadSelected ? LelegColors.accent : LelegColors.line,
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
        ],
      ),
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
    this.compact = false,
  });

  final XtreamProfile profile;
  final bool active;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onDelete;
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

  @override
  State<PlayerCard> createState() => _PlayerCardState();
}

class _PlayerCardState extends State<PlayerCard> {
  bool _showControls = false;
  Timer? _hideControlsTimer;

  bool get _pinControlsInFocusMode {
    if (!widget.focusMode) return false;
    if (widget.pinControlsOnFocus) return true;
    return !(Platform.isAndroid || Platform.isIOS);
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
    _hideControlsTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted && !_pinControlsInFocusMode) {
        setState(() => _showControls = false);
      }
    });
  }

  void _hideControls() {
    _hideControlsTimer?.cancel();
    if (mounted && !_pinControlsInFocusMode) {
      setState(() => _showControls = false);
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
      onTap: _revealControls,
      onDoubleTap: widget.onToggleFocusMode,
      child: MouseRegion(
        onEnter: (_) => _revealControls(),
        onHover: (_) => _revealControls(),
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
                          IconButton(
                            tooltip: 'Picture-in-Picture non disponibile',
                            onPressed: onPictureInPicture,
                            icon: const Icon(Icons.picture_in_picture_alt),
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
                          IconButton(
                            tooltip: 'Picture-in-Picture non disponibile',
                            onPressed: onPictureInPicture,
                            icon: const Icon(Icons.picture_in_picture_alt),
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
                          IconButton(
                            tooltip: 'Picture-in-Picture non disponibile',
                            onPressed: onPictureInPicture,
                            icon: const Icon(Icons.picture_in_picture_alt),
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
                          IconButton(
                            tooltip: 'Picture-in-Picture non disponibile',
                            onPressed: onPictureInPicture,
                            icon: const Icon(Icons.picture_in_picture_alt),
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
                                  IconButton(
                                    tooltip:
                                        'Picture-in-Picture non disponibile',
                                    onPressed: onPictureInPicture,
                                    icon: const Icon(
                                      Icons.picture_in_picture_alt,
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
                                  IconButton(
                                    tooltip:
                                        'Picture-in-Picture non disponibile',
                                    onPressed: onPictureInPicture,
                                    icon: const Icon(
                                      Icons.picture_in_picture_alt,
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
    this.sort,
    this.onSortChanged,
  });

  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final String Function(String id) categoryName;
  final ValueChanged<String> onCategoryChanged;
  final String? sort;
  final ValueChanged<String>? onSortChanged;

  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 760;
    final categoryIds = ['', ...categories.map((item) => item.id)];
    final selected = categoryIds.contains(selectedCategoryId)
        ? selectedCategoryId
        : '';
    return Padding(
      padding: EdgeInsets.fromLTRB(mobile ? 16 : 20, 8, mobile ? 16 : 20, 18),
      child: mobile
          ? Column(
              children: [
                _ToolbarSelect<String>(
                  label: 'Categoria',
                  value: selected,
                  items: categoryIds,
                  itemLabel: categoryName,
                  onChanged: onCategoryChanged,
                ),
                if (sort != null && onSortChanged != null) ...[
                  const SizedBox(height: 12),
                  _ToolbarSelect<String>(
                    label: 'Ordina',
                    value: sort!,
                    items: const ['default', 'az'],
                    itemLabel: (value) => value == 'az' ? 'A-Z' : 'Recenti',
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
                    itemLabel: categoryName,
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
                      items: const ['default', 'az'],
                      itemLabel: (value) => value == 'az' ? 'A-Z' : 'Recenti',
                      onChanged: onSortChanged!,
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

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
  });

  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final ValueChanged<String> onCategoryChanged;

  @override
  Widget build(BuildContext context) {
    final visibleCategories = categories.take(12).toList();
    return SizedBox(
      height: 58,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        scrollDirection: Axis.horizontal,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _CategoryChipButton(
              label: 'Tutte',
              selected: selectedCategoryId.isEmpty,
              onTap: () => onCategoryChanged(''),
            ),
          ),
          for (final category in visibleCategories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _CategoryChipButton(
                label: category.name,
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
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactEpgRail extends StatefulWidget {
  const _CompactEpgRail({
    required this.programmes,
    required this.loading,
    required this.channel,
    required this.onWatch,
  });

  final List<EpgProgramme> programmes;
  final bool loading;
  final LiveChannel? channel;
  final void Function(LiveChannel channel, EpgProgramme programme) onWatch;

  @override
  State<_CompactEpgRail> createState() => _CompactEpgRailState();
}

class _CompactEpgRailState extends State<_CompactEpgRail> {
  static const _chipWidth = 190.0;
  static const _separator = 10.0;

  final ScrollController _controller = ScrollController();
  int? _lastScrollTarget;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLive());
  }

  @override
  void didUpdateWidget(covariant _CompactEpgRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.programmes != widget.programmes ||
        oldWidget.channel?.id != widget.channel?.id ||
        (oldWidget.loading && !widget.loading)) {
      _lastScrollTarget = null;
      _scrollToLive();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scrollToLive() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLiveAttempt(0));
  }

  void _scrollToLiveAttempt(int attempt) {
    if (!mounted || attempt > 10) return;
    final items = _sortedProgrammes();
    final liveIndex = items.indexWhere(_programmeIsLive);
    if (liveIndex < 0) return;
    if (_lastScrollTarget == liveIndex && attempt > 0) return;

    if (!_controller.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToLiveAttempt(attempt + 1),
      );
      return;
    }

    _lastScrollTarget = liveIndex;
    final viewport = _controller.position.viewportDimension;
    final target =
        (liveIndex * (_chipWidth + _separator)) -
        ((viewport - _chipWidth) / 2);
    _controller.animateTo(
      target.clamp(0.0, _controller.position.maxScrollExtent).toDouble(),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  List<EpgProgramme> _sortedProgrammes() {
    final items = [...widget.programmes]
      ..sort((a, b) {
        final aStart = a.start;
        final bStart = b.start;
        if (aStart == null && bStart == null) return 0;
        if (aStart == null) return 1;
        if (bStart == null) return -1;
        return aStart.compareTo(bStart);
      });
    return items;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (widget.channel == null || widget.programmes.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Guida non disponibile',
          style: TextStyle(
            color: LelegColors.muted,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }
    final items = _sortedProgrammes();
    return ListView.separated(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(width: 10),
      itemBuilder: (_, index) {
        final programme = items[index];
        final live = _programmeIsLive(programme);
        final replay = _programmeCanReplay(widget.channel!, programme);
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: (live || replay)
              ? () => widget.onWatch(widget.channel!, programme)
              : null,
          child: Container(
            width: _chipWidth,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: live ? LelegColors.surface3 : LelegColors.bg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: live || replay
                    ? LelegColors.accent.withValues(alpha: 0.5)
                    : LelegColors.line,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${live
                          ? 'LIVE'
                          : replay
                          ? 'REC'
                          : ''} ${_programmeTimeRange(programme)}'
                      .trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LelegColors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  programme.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                if (programme.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    programme.description.trim(),
                    maxLines: 2,
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
        );
      },
    );
  }

  bool _programmeIsLive(EpgProgramme programme) => _epgIsLiveNow(programme);

  bool _programmeCanReplay(LiveChannel channel, EpgProgramme programme) {
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    if (!channel.hasCatchup || start == null || end == null) return false;
    if (end.isAfter(now) || !end.isAfter(start)) return false;
    final days = channel.catchupDays > 0 ? channel.catchupDays : 7;
    return start.isAfter(now.subtract(Duration(days: days)));
  }

  String _programmeTimeRange(EpgProgramme programme) {
    String fmt(DateTime? value) {
      if (value == null) return '--:--';
      return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    }

    return '${fmt(programme.start)} - ${fmt(programme.end)}';
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
  });

  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final ValueChanged<String> onCategoryChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _TvCategoryItem(
          label: 'Tutte',
          selected: selectedCategoryId.isEmpty,
          onTap: () => onCategoryChanged(''),
        ),
        for (final category in categories)
          _TvCategoryItem(
            label: category.name,
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
    this.selected = false,
    this.compact = false,
  });

  final LiveChannel channel;
  final ValueChanged<LiveChannel> onOpen;
  final ValueChanged<LiveChannel> onPlay;
  final String? category;
  final bool selected;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _EnsureVisibleWhenSelected(
      selected: selected,
      child: Material(
        color: selected ? LelegColors.surface3 : LelegColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: _RemoteActivate(
          onActivate: () => onOpen(channel),
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
              visualDensity:
                  compact ? VisualDensity.compact : VisualDensity.standard,
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
              subtitle: compact
                  ? null
                  : Text(
                      category == null || category!.isEmpty
                          ? '#${channel.id}'
                          : '$category · #${channel.id}',
                      style: const TextStyle(color: LelegColors.muted),
                    ),
              trailing: compact
                  ? null
                  : IconButton.filledTonal(
                      onPressed: () => onPlay(channel),
                      icon: const Icon(Icons.play_arrow),
                    ),
              onTap: () => onOpen(channel),
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
              width: 190,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected ? LelegColors.accent : LelegColors.line,
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _Poster(url: movie.logo),
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
                                movie.rating.isEmpty ? 'MOVIE' : movie.rating,
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
                          style: const TextStyle(fontWeight: FontWeight.w800),
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
                          spacing: 2,
                          runSpacing: 2,
                          children: [
                            IconButton.filledTonal(
                              onPressed: () => onPlay(movie),
                              icon: const Icon(Icons.chevron_right),
                              tooltip: 'Dettagli',
                            ),
                            if (onFavorite != null)
                              IconButton(
                                onPressed: () => onFavorite!(movie),
                                icon: Icon(
                                  isFavorite ? Icons.star : Icons.star_border,
                                ),
                                tooltip: 'Preferiti',
                              ),
                            if (onWatchLater != null)
                              IconButton(
                                onPressed: () => onWatchLater!(movie),
                                icon: Icon(
                                  isWatchLater
                                      ? Icons.bookmark
                                      : Icons.bookmark_border,
                                ),
                                tooltip: 'Da vedere',
                              ),
                            if (onDownload != null)
                              IconButton(
                                onPressed: () => onDownload!(movie),
                                icon: const Icon(Icons.download_outlined),
                                tooltip: 'Download',
                              ),
                          ],
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

class _SeriesPosterCard extends StatelessWidget {
  const _SeriesPosterCard({
    required this.show,
    required this.category,
    required this.onOpen,
    this.selected = false,
  });

  final SeriesShow show;
  final String category;
  final ValueChanged<SeriesShow> onOpen;
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _Poster(url: show.logo),
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
                          style: const TextStyle(fontWeight: FontWeight.w800),
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
                        Row(
                          children: [
                            const Icon(Icons.layers_outlined, size: 18),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Apri episodi',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: LelegColors.muted),
                              ),
                            ),
                            IconButton.filledTonal(
                              onPressed: () => onOpen(show),
                              icon: const Icon(Icons.chevron_right),
                              tooltip: 'Apri',
                            ),
                          ],
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
                  visualDensity:
                      compact ? VisualDensity.compact : VisualDensity.standard,
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToFocusAttempt(0));
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
        (safeIndex * (_chipWidth + _separator)) -
        ((viewport - _chipWidth) / 2);
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
    final liveProgramme = _firstWhereOrNull(ordered, _isLive);
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
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: 'Canale precedente',
                  onPressed: widget.onPreviousChannel,
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currentChannel?.name ?? 'Live TV',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        liveProgramme == null
                            ? 'Su/Giu canale · Sin/Des guida · OK riproduci'
                            : '${_timeRange(liveProgramme)}  ${liveProgramme.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LelegColors.muted,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  tooltip: 'Canale successivo',
                  onPressed: widget.onNextChannel,
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
              ],
            ),
            const SizedBox(height: 12),
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
                    return _FullscreenEpgChip(
                      programme: programme,
                      live: live,
                      replay: replay,
                      selected: index == widget.selectedIndex,
                      onTap: live || replay
                          ? () =>
                                widget.onWatchProgramme(currentChannel, programme)
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
    final now = DateTime.now();
    final items = widget.programmes
        .where(
          (programme) =>
              _isLive(programme) ||
              _canReplay(currentChannel, programme) ||
              (programme.start?.isAfter(now) ?? false),
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
    if (items.length <= 12) return items;
    final liveIndex = items.indexWhere(_isLive);
    if (liveIndex < 0) return items.take(12).toList();
    final start = (liveIndex - 4).clamp(0, items.length - 12).toInt();
    return items.skip(start).take(12).toList();
  }

  EpgProgramme? _firstWhereOrNull(
    List<EpgProgramme> source,
    bool Function(EpgProgramme programme) test,
  ) {
    for (final programme in source) {
      if (test(programme)) return programme;
    }
    return null;
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
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    if (!channel.hasCatchup || start == null || end == null) return false;
    if (end.isAfter(now) || !end.isAfter(start)) return false;
    final days = channel.catchupDays > 0 ? channel.catchupDays : 7;
    return start.isAfter(now.subtract(Duration(days: days)));
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
  static const _rowExtent = 104.0;

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
        (oldWidget.loading && !widget.loading)) {
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
    return ListView.separated(
      controller: _controller,
      itemCount: orderedProgrammes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, index) {
        final programme = orderedProgrammes[index];
        final live = _isLive(programme);
        return KeyedSubtree(
          key: live ? _liveTileKey : null,
          child: _programmeTile(programme, highlight: live),
        );
      },
    );
  }

  void _scheduleScrollToLive() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLive(0));
  }

  void _scrollToLive(int attempt) {
    if (!mounted || widget.loading) return;
    if (attempt > 12) return;

    final items = widget.programmes;
    if (items.isEmpty) return;

    final targetIndex = _epgLiveOrNextIndex(items);
    if (_scrolledToIndex == targetIndex && attempt > 0) return;

    if (!_controller.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToLive(attempt + 1),
      );
      return;
    }

    _scrolledToIndex = targetIndex;
    final offset = (targetIndex * _rowExtent - _rowExtent * 0.65)
        .clamp(0.0, _controller.position.maxScrollExtent);
    if ((_controller.offset - offset).abs() > 2) {
      _controller.jumpTo(offset);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final liveContext = _liveTileKey.currentContext;
      if (liveContext != null) {
        Scrollable.ensureVisible(
          liveContext,
          alignment: 0.28,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      if (attempt < 8) {
        _scrolledToIndex = null;
        _scrollToLive(attempt + 1);
      }
    });
  }

  bool _canInteract(EpgProgramme programme) {
    return widget.channel != null &&
        (_isLive(programme) || _canReplay(programme));
  }

  Widget _programmeTile(EpgProgramme programme, {required bool highlight}) {
    return SizedBox(
      height: 94,
      child: Container(
        decoration: BoxDecoration(
          color: highlight ? LelegColors.surface3 : LelegColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: LelegColors.line),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _canInteract(programme)
                ? () => widget.onWatch(widget.channel!, programme)
                : null,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                    const SizedBox(height: 6),
                    Text(
                      programme.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: LelegColors.muted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _isLive(EpgProgramme programme) => _epgIsLiveNow(programme);

  bool _canReplay(EpgProgramme programme) {
    final currentChannel = widget.channel;
    final now = DateTime.now();
    final start = programme.start;
    final end = programme.end;
    if (currentChannel == null ||
        !currentChannel.hasCatchup ||
        start == null ||
        end == null) {
      return false;
    }
    if (end.isAfter(now) || !end.isAfter(start)) return false;
    final days = currentChannel.catchupDays > 0
        ? currentChannel.catchupDays
        : 7;
    return start.isAfter(now.subtract(Duration(days: days)));
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
