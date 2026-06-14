import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'domain/xtream_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const LelegIptvNativeApp());
}

class LelegIptvNativeApp extends StatelessWidget {
  const LelegIptvNativeApp({super.key});

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
      home: const LelegNativeShell(),
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

class LelegNativeShell extends StatefulWidget {
  const LelegNativeShell({super.key});

  @override
  State<LelegNativeShell> createState() => _LelegNativeShellState();
}

class _LelegNativeShellState extends State<LelegNativeShell> {
  static const _profileKey = 'leleg.native.profile';
  static const _profilesKey = 'leleg.native.profiles';
  static const _activeProfileIdKey = 'leleg.native.active_profile_id';
  static const _lastUrlKey = 'leleg.native.prototype.last_url';
  static const _sampleUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
  static const _catalogCacheTtl = Duration(days: 1);
  static const _catalogCacheVersion = 3;

  late final Player _player;
  late final VideoController _videoController;
  late final TextEditingController _titleController;
  late final TextEditingController _serverController;
  late final TextEditingController _userController;
  late final TextEditingController _passController;
  late final TextEditingController _manualUrlController;
  late final TextEditingController _searchController;
  late final List<StreamSubscription> _subscriptions;

  AppSection _section = AppSection.home;
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
  List<SeriesShow> _series = const [];
  SeriesShow? _selectedSeries;
  List<SeriesEpisode> _seriesEpisodes = const [];
  final Set<int> _favoriteMovieIds = {};
  final Set<int> _watchLaterMovieIds = {};
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

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: const PlayerConfiguration(title: 'Leleg IPTV'),
    );
    _videoController = VideoController(_player);
    _titleController = TextEditingController();
    _serverController = TextEditingController();
    _userController = TextEditingController();
    _passController = TextEditingController();
    _manualUrlController = TextEditingController(text: _sampleUrl);
    _searchController = TextEditingController();
    _subscriptions = [
      _player.stream.error.listen((error) {
        if (mounted) setState(() => _status = 'Player error: $error');
      }),
      _player.stream.playing.listen((playing) {
        if (mounted) {
          setState(() => _status = playing ? 'In riproduzione' : 'In pausa');
        }
      }),
    ];
    _restoreState();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _serverController.dispose();
    _titleController.dispose();
    _userController.dispose();
    _passController.dispose();
    _manualUrlController.dispose();
    _searchController.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _restoreState() async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = _readProfiles(prefs);
    final activeProfileId = prefs.getString(_activeProfileIdKey) ?? '';
    final rawProfile = prefs.getString(_profileKey);
    final lastUrl = prefs.getString(_lastUrlKey);
    if (lastUrl != null && lastUrl.trim().isNotEmpty) {
      _manualUrlController.text = lastUrl;
    }
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
      _titleController.text = profile.title;
      _serverController.text = profile.serverUrl;
      _userController.text = profile.username;
      _passController.text = profile.password;
      setState(() {
        _profiles = savedProfiles;
        _profile = profile;
      });
      await _loadCatalog(profile: profile);
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'Profilo salvato non valido: $error');
      }
    }
  }

  XtreamProfile _readProfileFromForm() => XtreamProfile(
    title: _titleController.text.trim(),
    serverUrl: _serverController.text.trim(),
    username: _userController.text.trim(),
    password: _passController.text,
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

  Future<void> _saveAndLoadProfile({bool forceRefresh = true}) async {
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
    });
    await _loadCatalog(profile: profile, forceRefresh: forceRefresh);
  }

  Future<void> _selectProfile(XtreamProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeProfileIdKey, profile.id);
    await prefs.setString(_profileKey, jsonEncode(profile.toJson()));
    _titleController.text = profile.title;
    _serverController.text = profile.serverUrl;
    _userController.text = profile.username;
    _passController.text = profile.password;
    setState(() {
      _profile = profile;
      _resetProfileScopedState();
      _status = 'Cambio lista: ${profile.displayName}';
    });
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
    if (section == _section) {
      if (section == AppSection.epg) {
        unawaited(_loadEpgPage(force: true));
      }
      return;
    }
    if (_player.state.playlist.medias.isNotEmpty) {
      await _player.stop();
    }
    if (_playerFocusMode) {
      setState(() => _playerFocusMode = false);
      unawaited(windowManager.setFullScreen(false));
    }
    setState(() {
      _section = section;
      _selectedMovie = null;
      if (section != AppSection.series) {
        _selectedSeries = null;
        _seriesEpisodes = const [];
      }
      _playerTitle = 'Scegli qualcosa da guardare.';
      _status = 'Navigazione: ${_sectionLabel(section)}';
    });
    if (section == AppSection.epg) {
      unawaited(_loadEpgPage());
    }
  }

  Future<void> _loadCatalog({
    XtreamProfile? profile,
    bool forceRefresh = false,
  }) async {
    final activeProfile = profile ?? _profile;
    if (activeProfile == null || !activeProfile.isComplete) return;
    if (!forceRefresh && await _restoreCatalogCache(activeProfile)) {
      if (_section == AppSection.epg) {
        unawaited(_loadEpgPage(force: true));
      }
      return;
    }
    setState(() {
      _loading = true;
      _status = 'Caricamento account...';
      _resetProfileScopedState();
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
    _series = const [];
    _selectedSeries = null;
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

  Future<void> _openManualUrl() async {
    final url = _manualUrlController.text.trim();
    if (url.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastUrlKey, url);
    await _openMedia(url, 'Stream manuale');
  }

  Future<void> _playLive(LiveChannel channel) async {
    final profile = _profile;
    if (profile == null) return;
    setState(() => _selectedLiveChannel = channel);
    await _openMedia(XtreamClient(profile).liveUrl(channel), channel.name);
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
    setState(() => _selectedLiveChannel = channel);
    await _openMedia(catchupUrl, '${channel.name} - ${programme.title}');
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

  Future<void> _playMovie(VodMovie movie) async {
    final profile = _profile;
    if (profile == null) return;
    await _openMedia(XtreamClient(profile).vodUrl(movie), movie.name);
  }

  Future<void> _openMovie(VodMovie movie) async {
    setState(() {
      _section = AppSection.movies;
      _selectedMovie = movie;
    });
    await _playMovie(movie);
  }

  Future<void> _openSeries(SeriesShow show) async {
    final profile = _profile;
    if (profile == null) return;
    setState(() {
      _selectedSeries = show;
      _seriesEpisodes = const [];
      _seriesDetailLoading = true;
      _status = 'Caricamento episodi: ${show.name}';
    });
    try {
      final episodes = await XtreamClient(profile).seriesEpisodes(show);
      if (!mounted) return;
      setState(() {
        _seriesEpisodes = episodes;
        _status = 'Episodi caricati: ${show.name} (${episodes.length})';
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'Episodi non caricati: $error');
    } finally {
      if (mounted) setState(() => _seriesDetailLoading = false);
    }
  }

  Future<void> _playEpisode(SeriesEpisode episode) async {
    final profile = _profile;
    final show = _selectedSeries;
    if (profile == null) return;
    await _openMedia(
      XtreamClient(profile).episodeUrl(episode),
      show == null ? episode.title : '${show.name} - ${episode.title}',
    );
  }

  Future<void> _openMedia(String url, String title) async {
    setState(() {
      _playerTitle = title;
      _status = 'Apertura: $title';
    });
    await _player.open(
      Media(
        url,
        httpHeaders: _profile == null
            ? const {}
            : {
                'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
                'Referer': '${_profile!.baseUrl}/',
              },
      ),
      play: true,
    );
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
      setState(() {
        _selectedLiveEpg = epg;
        _epgByChannel[channel.id] = epg;
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
        .take(8)
        .toList();
    if (missingChannels.isNotEmpty && xmlTvProgrammesCount == 0) {
      var loaded = channels.length - missingChannels.length;
      for (final channel in missingChannels) {
        if (!mounted) return;
        try {
          final programmes = await client.shortEpg(channel, limit: 12);
          if (!mounted) return;
          setState(() {
            _epgByChannel[channel.id] = programmes;
            loaded += 1;
            _status = 'Guida TV fallback: $loaded/${channels.length} canali';
          });
        } catch (error) {
          if (!mounted) return;
          setState(() {
            _epgByChannel[channel.id] = const [];
            _status = 'Guida TV fallback limitato: $error';
          });
          break;
        }
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
    await _player.setAudioTrack(track);
    if (mounted) setState(() => _status = 'Audio: ${_trackLabel(track)}');
  }

  Future<void> _selectSubtitleTrack(SubtitleTrack track) async {
    await _player.setSubtitleTrack(track);
    if (mounted) setState(() => _status = 'Sottotitoli: ${_trackLabel(track)}');
  }

  Future<void> _setRate(double value) async {
    await _player.setRate(value);
    if (!mounted) return;
    setState(() {
      _rate = value;
      _status = 'Velocita: ${value.toStringAsFixed(2)}x';
    });
  }

  void _togglePlayerFocusMode() {
    final next = !_playerFocusMode;
    setState(() => _playerFocusMode = next);
    unawaited(
      windowManager.setFullScreen(next).catchError((error) {
        if (mounted) {
          setState(() => _status = 'Fullscreen non disponibile: $error');
        }
      }),
    );
  }

  void _showPictureInPictureUnavailable() {
    setState(
      () => _status =
          'Picture-in-Picture nativo non disponibile in questa build Flutter/macOS.',
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
        ? _liveChannels
        : _liveChannels
              .where((item) => item.categoryId == activeCategoryId)
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
        ? _liveChannels
        : _liveChannels
              .where((item) => item.categoryId == activeCategoryId)
              .toList();
    return byCategory;
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

  @override
  Widget build(BuildContext context) {
    if (_playerFocusMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: PlayerCard(
              title: _playerTitle,
              controller: _videoController,
              player: _player,
              rate: _rate,
              labelFor: _trackLabel,
              onAudioChanged: _selectAudioTrack,
              onSubtitleChanged: _selectSubtitleTrack,
              onRateChanged: _setRate,
              focusMode: true,
              onToggleFocusMode: _togglePlayerFocusMode,
              onPictureInPicture: _showPictureInPictureUnavailable,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      body: Row(
        children: [
          LelegSidebar(
            section: _section,
            queryController: _searchController,
            accountInfo: _accountInfo,
            profile: _profile,
            onQueryChanged: (value) => setState(() => _query = value),
            onSectionChanged: (section) => unawaited(_changeSection(section)),
          ),
          Expanded(
            child: Column(
              children: [
                _TopStatusBar(status: _status, loading: _loading),
                Expanded(child: _buildSection()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection() {
    if (_query.trim().isNotEmpty && _section == AppSection.home) {
      return SearchResultsScreen(
        query: _query,
        liveChannels: _filteredLive,
        movies: _filteredMovies,
        series: _filteredSeries,
        onOpenLive: (channel) async {
          await _changeSection(AppSection.live);
          await _playLive(channel);
        },
        onOpenMovie: _openMovie,
        onOpenSeries: (show) async {
          await _changeSection(AppSection.series);
          await _openSeries(show);
        },
      );
    }
    return switch (_section) {
      AppSection.home => HomeScreen(
        liveCount: _liveChannels.length,
        movieCount: _movies.length,
        seriesCount: _series.length,
        loading: _loading,
        status: _status,
        recentMovies: _movies.take(12).toList(),
        onOpenLive: () => unawaited(_changeSection(AppSection.live)),
        onOpenMovies: () => unawaited(_changeSection(AppSection.movies)),
        onOpenSeries: () => unawaited(_changeSection(AppSection.series)),
        onOpenSettings: () => unawaited(_changeSection(AppSection.settings)),
        onPlayMovie: _openMovie,
      ),
      AppSection.live => LiveScreen(
        channels: _filteredLive,
        allCount: _liveChannels.length,
        categories: _liveCategories,
        selectedCategoryId: _liveCategoryId,
        categoryName: (id) => _categoryName(_liveCategories, id),
        playerTitle: _playerTitle,
        controller: _videoController,
        player: _player,
        rate: _rate,
        labelFor: _trackLabel,
        onPlay: _playLive,
        onAudioChanged: _selectAudioTrack,
        onSubtitleChanged: _selectSubtitleTrack,
        onRateChanged: _setRate,
        onCategoryChanged: (id) => setState(() => _liveCategoryId = id),
        onToggleFocusMode: _togglePlayerFocusMode,
        onPictureInPicture: _showPictureInPictureUnavailable,
        epg: _selectedLiveEpg,
        epgLoading: _epgLoading,
        selectedChannel: _selectedLiveChannel,
        onWatchProgramme: _playProgramme,
      ),
      AppSection.movies =>
        _selectedMovie == null
            ? MoviesScreen(
                movies: _filteredMovies,
                allCount: _movies.length,
                categories: _movieCategories,
                selectedCategoryId: _movieCategoryId,
                sort: _movieSort,
                categoryName: (id) => _categoryName(_movieCategories, id),
                onCategoryChanged: (id) =>
                    setState(() => _movieCategoryId = id),
                onSortChanged: (sort) => setState(() => _movieSort = sort),
                onPlay: _openMovie,
                onFavorite: (movie) => setState(() {
                  _favoriteMovieIds.contains(movie.id)
                      ? _favoriteMovieIds.remove(movie.id)
                      : _favoriteMovieIds.add(movie.id);
                }),
                onWatchLater: (movie) => setState(() {
                  _watchLaterMovieIds.contains(movie.id)
                      ? _watchLaterMovieIds.remove(movie.id)
                      : _watchLaterMovieIds.add(movie.id);
                }),
                favorites: _favoriteMovieIds,
                watchLater: _watchLaterMovieIds,
              )
            : MovieDetailScreen(
                movie: _selectedMovie!,
                category: _categoryName(
                  _movieCategories,
                  _selectedMovie!.categoryId,
                ),
                controller: _videoController,
                player: _player,
                playerTitle: _playerTitle,
                rate: _rate,
                labelFor: _trackLabel,
                onBack: () => setState(() => _selectedMovie = null),
                onPlay: () => _playMovie(_selectedMovie!),
                onAudioChanged: _selectAudioTrack,
                onSubtitleChanged: _selectSubtitleTrack,
                onRateChanged: _setRate,
                onToggleFocusMode: _togglePlayerFocusMode,
                onPictureInPicture: _showPictureInPictureUnavailable,
              ),
      AppSection.favorites => MoviesScreen(
        title: 'Preferiti',
        movies: _movies
            .where((movie) => _favoriteMovieIds.contains(movie.id))
            .toList(),
        onPlay: _openMovie,
        onFavorite: (movie) =>
            setState(() => _favoriteMovieIds.remove(movie.id)),
        onWatchLater: (movie) =>
            setState(() => _watchLaterMovieIds.add(movie.id)),
        favorites: _favoriteMovieIds,
        watchLater: _watchLaterMovieIds,
      ),
      AppSection.watchLater => MoviesScreen(
        title: 'Da vedere',
        movies: _movies
            .where((movie) => _watchLaterMovieIds.contains(movie.id))
            .toList(),
        onPlay: _openMovie,
        onFavorite: (movie) => setState(() => _favoriteMovieIds.add(movie.id)),
        onWatchLater: (movie) =>
            setState(() => _watchLaterMovieIds.remove(movie.id)),
        favorites: _favoriteMovieIds,
        watchLater: _watchLaterMovieIds,
      ),
      AppSection.recentlyAdded => MoviesScreen(
        title: 'Aggiunti di recente',
        movies: _movies.take(350).toList(),
        onPlay: _openMovie,
        onFavorite: (movie) => setState(() => _favoriteMovieIds.add(movie.id)),
        onWatchLater: (movie) =>
            setState(() => _watchLaterMovieIds.add(movie.id)),
        favorites: _favoriteMovieIds,
        watchLater: _watchLaterMovieIds,
      ),
      AppSection.settings => SettingsScreen(
        profiles: _profiles,
        activeProfile: _profile,
        titleController: _titleController,
        serverController: _serverController,
        userController: _userController,
        passController: _passController,
        manualUrlController: _manualUrlController,
        onSave: () => _saveAndLoadProfile(),
        onReload: () => _loadCatalog(forceRefresh: true),
        onSelectProfile: _selectProfile,
        onDeleteProfile: _deleteProfile,
        onOpenManualUrl: _openManualUrl,
      ),
      AppSection.series =>
        _selectedSeries == null
            ? SeriesScreen(
                shows: _filteredSeries,
                allCount: _series.length,
                categories: _seriesCategories,
                selectedCategoryId: _seriesCategoryId,
                sort: _seriesSort,
                categoryName: (id) => _categoryName(_seriesCategories, id),
                onCategoryChanged: (id) =>
                    setState(() => _seriesCategoryId = id),
                onSortChanged: (sort) => setState(() => _seriesSort = sort),
                onOpen: _openSeries,
              )
            : SeriesDetailScreen(
                show: _selectedSeries!,
                episodes: _seriesEpisodes,
                loading: _seriesDetailLoading,
                controller: _videoController,
                player: _player,
                playerTitle: _playerTitle,
                rate: _rate,
                labelFor: _trackLabel,
                onBack: () => setState(() {
                  _selectedSeries = null;
                  _seriesEpisodes = const [];
                }),
                onPlay: _playEpisode,
                onAudioChanged: _selectAudioTrack,
                onSubtitleChanged: _selectSubtitleTrack,
                onRateChanged: _setRate,
                onToggleFocusMode: _togglePlayerFocusMode,
                onPictureInPicture: _showPictureInPictureUnavailable,
              ),
      AppSection.epg => EpgScreen(
        channels: _epgChannels,
        categories: _liveCategories,
        selectedCategoryId: _liveCategoryId,
        categoryName: (id) => _categoryName(_liveCategories, id),
        selectedChannel: _selectedLiveChannel,
        epgByChannel: _epgByChannel,
        loading: _epgLoading,
        onCategoryChanged: (id) {
          setState(() => _liveCategoryId = id);
          unawaited(_loadEpgPage(force: true));
        },
        onRefresh: () => unawaited(_loadEpgPage(force: true)),
        onSelectChannel: (channel) {
          setState(() => _selectedLiveChannel = channel);
          unawaited(_loadShortEpg(channel));
        },
        onWatchProgramme: _openLiveProgrammeFromGuide,
      ),
      AppSection.downloads => const PlaceholderScreen(
        title: 'Download',
        message: 'Download offline da portare dopo resume/progressi.',
        icon: Icons.download,
      ),
    };
  }
}

class LelegSidebar extends StatelessWidget {
  const LelegSidebar({
    required this.section,
    required this.queryController,
    required this.accountInfo,
    required this.profile,
    required this.onQueryChanged,
    required this.onSectionChanged,
    super.key,
  });

  final AppSection section;
  final TextEditingController queryController;
  final XtreamAccountInfo? accountInfo;
  final XtreamProfile? profile;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<AppSection> onSectionChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      decoration: const BoxDecoration(
        color: LelegColors.sidebar,
        border: Border(right: BorderSide(color: LelegColors.line)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Brand(),
          const SizedBox(height: 28),
          TextField(
            controller: queryController,
            decoration: const InputDecoration(
              labelText: 'Cerca',
              prefixIcon: Icon(Icons.search),
              suffixIcon: Padding(
                padding: EdgeInsets.only(right: 10),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    'Ctrl K',
                    style: TextStyle(fontSize: 11, color: LelegColors.muted),
                  ),
                ),
              ),
            ),
            onChanged: onQueryChanged,
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
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.live_tv_outlined,
                  'Live TV',
                  AppSection.live,
                  section,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.movie_outlined,
                  'Film',
                  AppSection.movies,
                  section,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.layers_outlined,
                  'Serie',
                  AppSection.series,
                  section,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.star_border,
                  'Preferiti',
                  AppSection.favorites,
                  section,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.bookmark_border,
                  'Da vedere',
                  AppSection.watchLater,
                  section,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.auto_awesome,
                  'Aggiunti di recente',
                  AppSection.recentlyAdded,
                  section,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.calendar_month_outlined,
                  'Guida TV',
                  AppSection.epg,
                  section,
                  onSectionChanged,
                ),
                _NavItem(
                  Icons.download_outlined,
                  'Download',
                  AppSection.downloads,
                  section,
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
          OutlinedButton.icon(
            onPressed: () => onSectionChanged(AppSection.settings),
            icon: const Icon(Icons.settings_outlined),
            label: Text(
              profile?.baseUrl.replaceFirst(RegExp(r'^https?://'), '') ??
                  'Impostazioni',
            ),
            style: OutlinedButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Icon(Icons.all_inclusive, color: LelegColors.accent, size: 42),
        SizedBox(width: 12),
        Text(
          'Leleg',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        Text(
          ' IPTV',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: LelegColors.accent,
          ),
        ),
      ],
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem(this.icon, this.label, this.value, this.current, this.onTap);

  final IconData icon;
  final String label;
  final AppSection value;
  final AppSection current;
  final ValueChanged<AppSection> onTap;

  @override
  Widget build(BuildContext context) {
    final active = value == current;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: active ? LelegColors.surface3 : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onTap(value),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: active
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: LelegColors.accent.withValues(alpha: 0.45),
                    ),
                  )
                : null,
            child: Row(
              children: [
                Icon(
                  icon,
                  color: active ? LelegColors.accent : LelegColors.muted,
                  size: 22,
                ),
                const SizedBox(width: 14),
                Text(
                  label,
                  style: TextStyle(
                    color: active ? LelegColors.fg : LelegColors.muted,
                    fontWeight: FontWeight.w600,
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

class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({required this.status, required this.loading});

  final String status;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: const BoxDecoration(
        color: LelegColors.bg,
        border: Border(bottom: BorderSide(color: LelegColors.line)),
      ),
      child: Row(
        children: [
          if (loading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (loading) const SizedBox(width: 12),
          Expanded(
            child: Text(
              status,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LelegColors.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.liveCount,
    required this.movieCount,
    required this.seriesCount,
    required this.loading,
    required this.status,
    required this.recentMovies,
    required this.onOpenLive,
    required this.onOpenMovies,
    required this.onOpenSeries,
    required this.onOpenSettings,
    required this.onPlayMovie,
    super.key,
  });

  final int liveCount;
  final int movieCount;
  final int seriesCount;
  final bool loading;
  final String status;
  final List<VodMovie> recentMovies;
  final VoidCallback onOpenLive;
  final VoidCallback onOpenMovies;
  final VoidCallback onOpenSeries;
  final VoidCallback onOpenSettings;
  final ValueChanged<VodMovie> onPlayMovie;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      eyebrow: 'BUONANOTTE',
      title: 'Leleg IPTV',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              _HeroCard(
                title: 'TV in diretta',
                subtitle: '$liveCount canali',
                icon: Icons.live_tv,
                onTap: onOpenLive,
              ),
              _HeroCard(
                title: 'Film',
                subtitle: '$movieCount titoli',
                icon: Icons.movie,
                onTap: onOpenMovies,
              ),
              _HeroCard(
                title: 'Serie',
                subtitle: '$seriesCount serie',
                icon: Icons.layers,
                onTap: onOpenSeries,
              ),
              _HeroCard(
                title: 'Impostazioni',
                subtitle: 'Provider e player',
                icon: Icons.settings,
                onTap: onOpenSettings,
              ),
            ],
          ),
          if (loading) ...[
            const SizedBox(height: 18),
            _LoadingBand(status: status),
          ],
          const SizedBox(height: 28),
          const Text(
            'Aggiunti di recente',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 14),
          if (recentMovies.isEmpty)
            const _EmptyState(message: 'Carica una playlist in Impostazioni.')
          else
            SizedBox(
              height: 290,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: recentMovies.length,
                separatorBuilder: (_, _) => const SizedBox(width: 14),
                itemBuilder: (_, index) => _MoviePosterCard(
                  movie: recentMovies[index],
                  onPlay: onPlayMovie,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class LiveScreen extends StatelessWidget {
  const LiveScreen({
    required this.channels,
    required this.allCount,
    required this.categories,
    required this.selectedCategoryId,
    required this.categoryName,
    required this.playerTitle,
    required this.controller,
    required this.player,
    required this.rate,
    required this.labelFor,
    required this.onPlay,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    required this.onCategoryChanged,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
    required this.epg,
    required this.epgLoading,
    required this.selectedChannel,
    required this.onWatchProgramme,
    super.key,
  });

  final List<LiveChannel> channels;
  final int allCount;
  final List<XtreamCategory> categories;
  final String selectedCategoryId;
  final String Function(String id) categoryName;
  final String playerTitle;
  final VideoController controller;
  final Player player;
  final double rate;
  final String Function(dynamic value) labelFor;
  final ValueChanged<LiveChannel> onPlay;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;
  final ValueChanged<String> onCategoryChanged;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;
  final List<EpgProgramme> epg;
  final bool epgLoading;
  final LiveChannel? selectedChannel;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onWatchProgramme;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'Live TV',
      eyebrow: '${channels.length} di $allCount canali',
      child: Row(
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
                Expanded(
                  child: channels.isEmpty
                      ? const _EmptyState(message: 'Nessun canale caricato.')
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                          itemCount: channels.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, index) {
                            final channel = channels[index];
                            return _ChannelTile(
                              channel: channel,
                              onPlay: onPlay,
                              category: categoryName(channel.categoryId),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1, color: LelegColors.line),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Flexible(
                    flex: 5,
                    child: PlayerCard(
                      title: playerTitle,
                      controller: controller,
                      player: player,
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
                  Flexible(
                    flex: 2,
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
            ),
          ),
        ],
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
            itemBuilder: (channel) =>
                _ChannelTile(channel: channel, onPlay: onOpenLive),
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
    );
  }
}

class MoviesScreen extends StatelessWidget {
  const MoviesScreen({
    required this.movies,
    required this.onPlay,
    required this.onFavorite,
    required this.onWatchLater,
    required this.favorites,
    required this.watchLater,
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
  final Set<int> favorites;
  final Set<int> watchLater;

  @override
  Widget build(BuildContext context) {
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
          Expanded(
            child: movies.isEmpty
                ? const _EmptyState(message: 'Nessun titolo da mostrare.')
                : GridView.builder(
                    padding: const EdgeInsets.all(28),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 210,
                          mainAxisExtent: 332,
                          crossAxisSpacing: 18,
                          mainAxisSpacing: 20,
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
                        isFavorite: favorites.contains(movie.id),
                        isWatchLater: watchLater.contains(movie.id),
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
    required this.category,
    required this.controller,
    required this.player,
    required this.playerTitle,
    required this.rate,
    required this.labelFor,
    required this.onBack,
    required this.onPlay,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
    super.key,
  });

  final VodMovie movie;
  final String category;
  final VideoController controller;
  final Player player;
  final String playerTitle;
  final double rate;
  final String Function(dynamic value) labelFor;
  final VoidCallback onBack;
  final VoidCallback onPlay;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: movie.name,
      eyebrow: [
        if (category.isNotEmpty) category,
        if (movie.rating.isNotEmpty) '★ ${movie.rating}',
        movie.containerExtension.toUpperCase(),
      ].join(' · '),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
        child: Column(
          children: [
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Film'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: onPlay,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(
              child: Row(
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
                    child: Column(
                      children: [
                        Expanded(
                          child: PlayerCard(
                            title: playerTitle,
                            controller: controller,
                            player: player,
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
          ],
        ),
      ),
    );
  }
}

class SeriesScreen extends StatelessWidget {
  const SeriesScreen({
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
          Expanded(
            child: shows.isEmpty
                ? const _EmptyState(message: 'Nessuna serie da mostrare.')
                : GridView.builder(
                    padding: const EdgeInsets.all(28),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 210,
                          mainAxisExtent: 320,
                          crossAxisSpacing: 18,
                          mainAxisSpacing: 20,
                        ),
                    itemCount: shows.length,
                    itemBuilder: (_, index) => _SeriesPosterCard(
                      show: shows[index],
                      category: categoryName(shows[index].categoryId),
                      onOpen: onOpen,
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
    required this.episodes,
    required this.loading,
    required this.controller,
    required this.player,
    required this.playerTitle,
    required this.rate,
    required this.labelFor,
    required this.onBack,
    required this.onPlay,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
    super.key,
  });

  final SeriesShow show;
  final List<SeriesEpisode> episodes;
  final bool loading;
  final VideoController controller;
  final Player player;
  final String playerTitle;
  final double rate;
  final String Function(dynamic value) labelFor;
  final VoidCallback onBack;
  final ValueChanged<SeriesEpisode> onPlay;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: show.name,
      eyebrow: '${episodes.length} episodi',
      child: Row(
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
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: episodes.isEmpty
                      ? const _EmptyState(message: 'Nessun episodio caricato.')
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                          itemCount: episodes.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
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
              child: Column(
                children: [
                  Expanded(
                    child: PlayerCard(
                      title: playerTitle,
                      controller: controller,
                      player: player,
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
          ),
        ],
      ),
    );
  }
}

class EpgScreen extends StatelessWidget {
  const EpgScreen({
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
  });

  final List<LiveChannel> channels;
  final LiveChannel? selectedChannel;
  final Map<int, List<EpgProgramme>> epgByChannel;
  final ValueChanged<LiveChannel> onSelectChannel;
  final void Function(LiveChannel channel, EpgProgramme programme)
  onWatchProgramme;
  final bool loading;

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
                  return _EpgTimelineRow(
                    channel: channel,
                    programmes:
                        widget.epgByChannel[channel.id] ??
                        const <EpgProgramme>[],
                    active: widget.selectedChannel?.id == channel.id,
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
                for (final programme in visibleProgrammes)
                  _TimelineProgrammeCell(
                    channel: channel,
                    programme: programme,
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
    required this.viewStart,
    required this.hourWidth,
    required this.visibleHours,
    required this.onWatch,
  });

  final LiveChannel channel;
  final EpgProgramme programme;
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
    final borderColor = live || replayable
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
                border: Border.all(color: borderColor),
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
    required this.profiles,
    required this.activeProfile,
    required this.titleController,
    required this.serverController,
    required this.userController,
    required this.passController,
    required this.manualUrlController,
    required this.onSave,
    required this.onReload,
    required this.onSelectProfile,
    required this.onDeleteProfile,
    required this.onOpenManualUrl,
    super.key,
  });

  final List<XtreamProfile> profiles;
  final XtreamProfile? activeProfile;
  final TextEditingController titleController;
  final TextEditingController serverController;
  final TextEditingController userController;
  final TextEditingController passController;
  final TextEditingController manualUrlController;
  final VoidCallback onSave;
  final VoidCallback onReload;
  final ValueChanged<XtreamProfile> onSelectProfile;
  final ValueChanged<XtreamProfile> onDeleteProfile;
  final VoidCallback onOpenManualUrl;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      title: 'Impostazioni',
      eyebrow: 'Provider',
      child: ListView(
        padding: const EdgeInsets.all(28),
        children: [
          _SettingsBand(
            title: 'Liste IPTV',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (profiles.isEmpty)
                  const _InlineNotice(
                    text:
                        'Nessuna lista salvata. Inserisci un profilo Xtream e premi Salva e carica.',
                  )
                else
                  ...profiles.map(
                    (profile) => _ProfileTile(
                      profile: profile,
                      active: activeProfile?.id == profile.id,
                      onSelect: () => onSelectProfile(profile),
                      onDelete: () => onDeleteProfile(profile),
                    ),
                  ),
                if (profiles.isNotEmpty) const SizedBox(height: 18),
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: 'Nome lista',
                    hintText: 'Es. Casa, Sport, Provider principale',
                  ),
                  onSubmitted: (_) => onSave(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: serverController,
                  decoration: const InputDecoration(labelText: 'Server URL'),
                  onSubmitted: (_) => onSave(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: userController,
                  decoration: const InputDecoration(labelText: 'Username'),
                  onSubmitted: (_) => onSave(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passController,
                  decoration: const InputDecoration(labelText: 'Password'),
                  obscureText: true,
                  onSubmitted: (_) => onSave(),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: onSave,
                      icon: const Icon(Icons.cloud_sync),
                      label: const Text('Salva e carica'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: onReload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Ricarica dal provider'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Il catalogo viene riusato dalla cache per 24 ore. Ricarica dal provider forza un nuovo download.',
                  style: TextStyle(color: LelegColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _SettingsBand(
            title: 'Player diagnostico',
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: manualUrlController,
                    decoration: const InputDecoration(
                      labelText: 'URL stream manuale',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: onOpenManualUrl,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play URL'),
                ),
              ],
            ),
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
    required this.onSelect,
    required this.onDelete,
  });

  final XtreamProfile profile;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: active ? LelegColors.surface3 : LelegColors.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: active
              ? LelegColors.accent.withValues(alpha: 0.55)
              : LelegColors.line,
        ),
      ),
      child: Row(
        children: [
          Icon(
            active ? Icons.check_circle : Icons.playlist_play,
            color: active ? LelegColors.accent : LelegColors.muted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                Text(
                  '${profile.baseUrl.replaceFirst(RegExp(r'^https?://'), '')} · ${profile.username}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: LelegColors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          OutlinedButton(
            onPressed: active ? null : onSelect,
            child: Text(active ? 'Attiva' : 'Usa'),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: onDelete,
            tooltip: 'Rimuovi lista',
            icon: const Icon(Icons.delete_outline),
          ),
        ],
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

class _PageScaffold extends StatelessWidget {
  const _PageScaffold({required this.title, required this.child, this.eyebrow});

  final String title;
  final String? eyebrow;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topLeft,
          radius: 1.1,
          colors: [Color(0xFF0D2A34), LelegColors.bg],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (eyebrow != null)
                  Text(
                    eyebrow!.toUpperCase(),
                    style: const TextStyle(
                      color: LelegColors.muted,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 54,
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

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 260,
      height: 128,
      child: Material(
        color: LelegColors.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: LelegColors.line),
            ),
            child: Row(
              children: [
                Icon(icon, color: LelegColors.accent, size: 34),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        style: const TextStyle(color: LelegColors.muted),
                      ),
                    ],
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
    required this.rate,
    required this.labelFor,
    required this.onAudioChanged,
    required this.onSubtitleChanged,
    required this.onRateChanged,
    required this.onToggleFocusMode,
    required this.onPictureInPicture,
    this.focusMode = false,
    super.key,
  });

  final String title;
  final VideoController controller;
  final Player player;
  final double rate;
  final String Function(dynamic value) labelFor;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;
  final VoidCallback onToggleFocusMode;
  final VoidCallback onPictureInPicture;
  final bool focusMode;

  @override
  State<PlayerCard> createState() => _PlayerCardState();
}

class _PlayerCardState extends State<PlayerCard> {
  bool _showControls = false;
  Timer? _hideControlsTimer;

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
    _hideControlsTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted && !widget.focusMode) {
        setState(() => _showControls = false);
      }
    });
  }

  void _hideControls() {
    _hideControlsTimer?.cancel();
    if (mounted && !widget.focusMode) {
      setState(() => _showControls = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _revealControls(),
      onHover: (_) => _revealControls(),
      onExit: (_) => _hideControls(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: ColoredBox(
          color: Colors.black,
          child: Column(
            children: [
              Container(
                height: widget.focusMode ? 0 : 54,
                alignment: Alignment.centerLeft,
                padding: widget.focusMode
                    ? EdgeInsets.zero
                    : const EdgeInsets.symmetric(horizontal: 18),
                color: LelegColors.surface,
                child: widget.focusMode
                    ? const SizedBox.shrink()
                    : Text(
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
                      child: Video(
                        controller: widget.controller,
                        controls: NoVideoControls,
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: AnimatedOpacity(
                        opacity: _showControls || widget.focusMode ? 1 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: IgnorePointer(
                          ignoring: !(_showControls || widget.focusMode),
                          child: _PlayerTimelineControls(
                            player: widget.player,
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
        ),
      ),
    );
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
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              tooltip: playing ? 'Pausa' : 'Play',
                              onPressed: () =>
                                  playing ? player.pause() : player.play(),
                              icon: Icon(
                                playing ? Icons.pause : Icons.play_arrow,
                              ),
                            ),
                            SizedBox(
                              width: 118,
                              child: Text(
                                '${_formatDuration(position)} / ${_formatDuration(duration)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                value: valueMs,
                                min: 0,
                                max: maxMs,
                                onChanged: duration.inMilliseconds <= 0
                                    ? null
                                    : (value) => player.seek(
                                        Duration(milliseconds: value.round()),
                                      ),
                              ),
                            ),
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
                              tooltip: 'Picture-in-Picture non disponibile',
                              onPressed: onPictureInPicture,
                              icon: const Icon(Icons.picture_in_picture_alt),
                            ),
                          ],
                        ),
                      ],
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
  const _VolumeControl({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.volume,
      initialData: player.state.volume,
      builder: (context, snapshot) {
        final volume = (snapshot.data ?? 100).clamp(0, 100).toDouble();
        return SizedBox(
          width: 128,
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
    return StreamBuilder<Tracks>(
      stream: player.stream.tracks,
      initialData: player.state.tracks,
      builder: (context, snapshot) {
        final tracks = snapshot.data ?? const Tracks();
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
      },
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
  });

  final Player player;
  final double rate;
  final String Function(dynamic value) labelFor;
  final ValueChanged<AudioTrack> onAudioChanged;
  final ValueChanged<SubtitleTrack> onSubtitleChanged;
  final ValueChanged<double> onRateChanged;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Tracks>(
      stream: player.stream.tracks,
      initialData: player.state.tracks,
      builder: (context, snapshot) {
        final tracks = snapshot.data ?? const Tracks();
        return Row(
          mainAxisSize: MainAxisSize.min,
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
              child: const _PlayerMenuChip(
                icon: Icons.speed,
                label: 'Velocita',
              ),
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
      },
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
    final categoryIds = ['', ...categories.map((item) => item.id)];
    final selected = categoryIds.contains(selectedCategoryId)
        ? selectedCategoryId
        : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
      child: Row(
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
                itemLabel: (value) => value == 'az' ? 'A-Z' : 'Default',
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

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.channel,
    required this.onPlay,
    this.category,
  });

  final LiveChannel channel;
  final ValueChanged<LiveChannel> onPlay;
  final String? category;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: LelegColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: ListTile(
        leading: _Logo(url: channel.logo, fallback: Icons.live_tv),
        title: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          category == null || category!.isEmpty
              ? '#${channel.id}'
              : '$category · #${channel.id}',
          style: const TextStyle(color: LelegColors.muted),
        ),
        trailing: IconButton.filledTonal(
          onPressed: () => onPlay(channel),
          icon: const Icon(Icons.play_arrow),
        ),
        onTap: () => onPlay(channel),
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
    this.isFavorite = false,
    this.isWatchLater = false,
  });

  final VodMovie movie;
  final ValueChanged<VodMovie> onPlay;
  final String? category;
  final ValueChanged<VodMovie>? onFavorite;
  final ValueChanged<VodMovie>? onWatchLater;
  final bool isFavorite;
  final bool isWatchLater;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: LelegColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => onPlay(movie),
        child: Container(
          width: 190,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: LelegColors.line),
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
                    Row(
                      children: [
                        IconButton.filledTonal(
                          onPressed: () => onPlay(movie),
                          icon: const Icon(Icons.play_arrow),
                          tooltip: 'Play',
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
                      ],
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
}

class _SeriesPosterCard extends StatelessWidget {
  const _SeriesPosterCard({
    required this.show,
    required this.category,
    required this.onOpen,
  });

  final SeriesShow show;
  final String category;
  final ValueChanged<SeriesShow> onOpen;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: LelegColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => onOpen(show),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: LelegColors.line),
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
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.episode, required this.onPlay});

  final SeriesEpisode episode;
  final ValueChanged<SeriesEpisode> onPlay;

  @override
  Widget build(BuildContext context) {
    final code = [
      if (episode.season > 0) 'S${episode.season.toString().padLeft(2, '0')}',
      if (episode.episode > 0) 'E${episode.episode.toString().padLeft(2, '0')}',
    ].join('');
    return Material(
      color: LelegColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: LelegColors.surface3,
          child: Text(
            code.isEmpty ? 'EP' : code,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
          ),
        ),
        title: Text(
          episode.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          episode.duration.isEmpty
              ? episode.containerExtension.toUpperCase()
              : '${episode.duration} · ${episode.containerExtension.toUpperCase()}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: LelegColors.muted),
        ),
        trailing: IconButton.filledTonal(
          onPressed: () => onPlay(episode),
          icon: const Icon(Icons.play_arrow),
        ),
        onTap: () => onPlay(episode),
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

class _EpgProgrammeListState extends State<_EpgProgrammeList> {
  static const _rowExtent = 104.0;

  final ScrollController _controller = ScrollController();
  int? _lastFocusedIndex;

  @override
  void didUpdateWidget(covariant _EpgProgrammeList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.programmes != widget.programmes ||
        oldWidget.channel?.id != widget.channel?.id) {
      _lastFocusedIndex = null;
      _scheduleCurrentScroll();
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
    final orderedProgrammes = _chronologicalProgrammes(widget.programmes);
    _scheduleCurrentScroll(orderedProgrammes);
    return ListView.separated(
      controller: _controller,
      itemCount: orderedProgrammes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, index) {
        final programme = orderedProgrammes[index];
        return _programmeTile(programme, highlight: _isLive(programme));
      },
    );
  }

  bool _canInteract(EpgProgramme programme) {
    return widget.channel != null &&
        (_isLive(programme) || _canReplay(programme));
  }

  List<EpgProgramme> _chronologicalProgrammes(List<EpgProgramme> source) {
    final items = source
        .where(
          (programme) =>
              _isLive(programme) ||
              _canReplay(programme) ||
              (programme.start?.isAfter(DateTime.now()) ?? false),
        )
        .toList();
    items.sort(_sortAsc);
    return items;
  }

  void _scheduleCurrentScroll([List<EpgProgramme>? ordered]) {
    final items = ordered ?? _chronologicalProgrammes(widget.programmes);
    final currentIndex = items.indexWhere(_isLive);
    if (currentIndex < 0 || _lastFocusedIndex == currentIndex) return;
    _lastFocusedIndex = currentIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final target = (currentIndex * _rowExtent) - (_rowExtent * 1.2);
      _controller.animateTo(
        target.clamp(0.0, _controller.position.maxScrollExtent).toDouble(),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Widget _programmeTile(EpgProgramme programme, {required bool highlight}) {
    return Container(
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
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: LelegColors.muted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  int _sortAsc(EpgProgramme a, EpgProgramme b) {
    final aStart = a.start;
    final bStart = b.start;
    if (aStart == null && bStart == null) return 0;
    if (aStart == null) return 1;
    if (bStart == null) return -1;
    return aStart.compareTo(bStart);
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
  const _Logo({required this.url, required this.fallback});

  final String url;
  final IconData fallback;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return CircleAvatar(
        backgroundColor: LelegColors.surface3,
        child: Icon(fallback, color: LelegColors.accent),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        url,
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => CircleAvatar(
          backgroundColor: LelegColors.surface3,
          child: Icon(fallback, color: LelegColors.accent),
        ),
      ),
    );
  }
}

class _SettingsBand extends StatelessWidget {
  const _SettingsBand({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: LelegColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: LelegColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 16),
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
