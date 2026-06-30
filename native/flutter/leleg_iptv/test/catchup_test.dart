import 'package:flutter_test/flutter_test.dart';
import 'package:leleg_iptv/domain/catchup.dart';
import 'package:leleg_iptv/domain/xtream_client.dart';

void main() {
  final now = DateTime(2026, 1, 2, 12);
  final programme = EpgProgramme(
    title: 'News',
    description: '',
    start: DateTime(2026, 1, 2, 10),
    end: DateTime(2026, 1, 2, 11, 30),
  );
  final channel = LiveChannel(
    id: 42,
    name: 'Test',
    logo: '',
    categoryId: '',
    tvgId: '',
    catchup: 'xtream',
    catchupDays: 7,
  );
  final profile = XtreamProfile(
    id: 'p1',
    title: 'Test',
    serverUrl: 'https://iptv.example.com',
    username: 'u',
    password: 'p',
    liveContainer: 'm3u8',
  );

  test('allows ended programmes inside catchup window', () {
    expect(Catchup.canReplayProgramme(channel, programme, now: now), isTrue);
  });

  test('builds encoded Xtream timeshift URLs', () {
    final urls = Catchup.buildStreamUrls(
      profile,
      channel,
      programme,
      liveUrl: (_) => 'https://iptv.example.com/live/u/p/42.m3u8',
      now: now,
    );
    expect(urls.first, contains('/timeshift/'));
    expect(
      urls,
      contains(
        'https://iptv.example.com/timeshift/u/p/90/2026-01-02%3A10-00/42.m3u8',
      ),
    );
    expect(urls.any((url) => url.contains('?utc=')), isFalse);
  });

  test('append urls for non-xtream catchup modes', () {
    final appendChannel = LiveChannel(
      id: 42,
      name: 'Append',
      logo: '',
      categoryId: '',
      tvgId: '',
      catchup: 'append',
      catchupDays: 3,
    );
    final urls = Catchup.buildStreamUrls(
      profile,
      appendChannel,
      programme,
      liveUrl: (_) => 'https://iptv.example.com/live/u/p/42.m3u8',
      now: now,
    );
    expect(
      urls,
      contains(
        'https://iptv.example.com/live/u/p/42.m3u8?utc=1767344400&lutc=1767351600',
      ),
    );
  });

  test('replaces catchup-source placeholders', () {
    final customChannel = LiveChannel(
      id: 1,
      name: 'Custom',
      logo: '',
      categoryId: '',
      tvgId: '',
      catchup: 'default',
      catchupDays: 7,
      catchupSource:
          'https://example.com/replay/\${start}/\${end}/\${duration}/\${timestamp}',
    );
    final urls = Catchup.buildStreamUrls(
      profile,
      customChannel,
      programme,
      liveUrl: (_) => 'https://iptv.example.com/live/u/p/1.m3u8',
      now: now,
    );
    expect(
      urls.first,
      'https://example.com/replay/${programme.start!.millisecondsSinceEpoch ~/ 1000}/'
      '${programme.end!.millisecondsSinceEpoch ~/ 1000}/5400/${now.millisecondsSinceEpoch ~/ 1000}',
    );
  });
}
