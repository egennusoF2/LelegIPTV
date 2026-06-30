import 'xtream_client.dart';

/// Catch-up / timeshift URL builders aligned with `src/scripts/lib/catchup.ts`.
class Catchup {
  static const defaultCatchupDays = 7;

  static bool channelHasCatchup(LiveChannel channel) {
    final mode = channel.catchup.trim().toLowerCase();
    return channel.catchupSource.isNotEmpty ||
        channel.catchupDays > 0 ||
        mode == 'xtream' ||
        mode == 'append' ||
        mode == 'default' ||
        mode == 'shift' ||
        mode == 'flussonic';
  }

  static bool canReplayProgramme(
    LiveChannel? channel,
    EpgProgramme programme, {
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    if (channel == null || !channelHasCatchup(channel)) return false;
    final start = programme.start;
    final end = programme.end;
    if (start == null || end == null) return false;
    if (end.isAfter(clock) || !end.isAfter(start)) return false;
    final windowDays = channel.catchupDays > 0
        ? channel.catchupDays
        : (channelHasCatchup(channel) ? defaultCatchupDays : 0);
    if (windowDays <= 0) return false;
    return start.isAfter(clock.subtract(Duration(days: windowDays)));
  }

  static List<String> buildStreamUrls(
    XtreamProfile profile,
    LiveChannel channel,
    EpgProgramme programme, {
    required String Function(LiveChannel channel) liveUrl,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    if (!canReplayProgramme(channel, programme, now: clock)) {
      return const [];
    }
    final start = programme.start;
    final end = programme.end;
    if (start == null || end == null) return const [];

    final urls = <String>[];
    final mode = channel.catchup.trim().toLowerCase();

    final source = channel.catchupSource.trim();
    if (source.isNotEmpty) {
      urls.add(_replaceCatchupPlaceholders(source, start, end, clock));
    }

    if (mode == 'xtream' ||
        channel.catchupDays > 0 ||
        (mode.isEmpty && channelHasCatchup(channel))) {
      urls.addAll(_xtreamTimeshiftUrls(profile, channel, programme));
    }

    final liveBase = channel.directSource.trim().isNotEmpty
        ? channel.directSource.trim()
        : liveUrl(channel);
    if (liveBase.isNotEmpty) {
      final appendAllowed =
          mode == 'append' ||
          mode == 'default' ||
          mode == 'shift' ||
          mode == 'flussonic' ||
          (channel.catchupDays > 0 && mode != 'xtream');
      if (appendAllowed) {
        final startSec = start.millisecondsSinceEpoch ~/ 1000;
        final stopSec = end.millisecondsSinceEpoch ~/ 1000;
        final nowSec = clock.millisecondsSinceEpoch ~/ 1000;
        final separator = liveBase.contains('?') ? '&' : '?';
        urls.add('$liveBase${separator}utc=$startSec&lutc=$nowSec');
        urls.add(
          '$liveBase${separator}utc=$startSec&lutc=$nowSec&duration=${stopSec - startSec}',
        );
      }
    }

    return urls.toSet().toList(growable: false);
  }

  static List<String> _xtreamTimeshiftUrls(
    XtreamProfile profile,
    LiveChannel channel,
    EpgProgramme programme,
  ) {
    final start = programme.start;
    final end = programme.end;
    if (start == null || end == null) return const [];
    final durationMinutes = (end.difference(start).inSeconds / 60).ceil();
    final safeDuration = durationMinutes < 1 ? 1 : durationMinutes;
    final stamp = _formatXtreamStart(start);
    final primary = profile.liveContainer == 'ts' ? 'ts' : 'm3u8';
    final alternate = primary == 'ts' ? 'm3u8' : 'ts';
    final user = profile.username;
    final pass = profile.password;
    final plainBase =
        '${profile.baseUrl}/timeshift/$user/$pass/$safeDuration/$stamp/${channel.id}';
    final encodedBase =
        '${profile.baseUrl}/timeshift/'
        '${Uri.encodeComponent(user)}/'
        '${Uri.encodeComponent(pass)}/'
        '$safeDuration/'
        '${Uri.encodeComponent(stamp)}/'
        '${Uri.encodeComponent(channel.id.toString())}';
    return [
      '$encodedBase.$primary',
      '$plainBase.$primary',
      '$encodedBase.$alternate',
      '$plainBase.$alternate',
    ];
  }

  static String _formatXtreamStart(DateTime value) {
    String pad(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${pad(value.month)}-${pad(value.day)}:'
        '${pad(value.hour)}-${pad(value.minute)}';
  }

  static String _replaceCatchupPlaceholders(
    String template,
    DateTime start,
    DateTime end,
    DateTime now,
  ) {
    final startSec = start.millisecondsSinceEpoch ~/ 1000;
    final stopSec = end.millisecondsSinceEpoch ~/ 1000;
    final durationSec = stopSec - startSec < 1 ? 1 : stopSec - startSec;
    final durationMinutes = (durationSec / 60).ceil().clamp(1, 99999);
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;
    final replacements = <String, String>{
      'start': '$startSec',
      'end': '$stopSec',
      'stop': '$stopSec',
      'utc': '$startSec',
      'lutc': '$nowSec',
      'timestamp': '$nowSec',
      'duration': '$durationSec',
      'duration-minutes': '$durationMinutes',
      'offset': '$startSec',
    };
    return template.replaceAllMapped(RegExp(r'\$\{([^}]+)\}|\{([^}]+)\}'), (
      match,
    ) {
      final key = (match.group(1) ?? match.group(2) ?? '').trim().toLowerCase();
      return replacements[key] ?? match.group(0)!;
    });
  }
}
