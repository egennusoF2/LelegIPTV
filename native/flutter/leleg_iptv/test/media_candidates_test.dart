import 'package:flutter_test/flutter_test.dart';
import 'package:leleg_iptv/domain/media_candidates.dart';

void main() {
  test('preserves the provider VOD container', () {
    final candidates = vodMediaCandidates(
      'https://provider.example/movie/user/pass/8480.mkv',
    );

    expect(candidates, [
      'https://provider.example/movie/user/pass/8480.mkv',
      'http://provider.example/movie/user/pass/8480.mkv',
    ]);
    expect(candidates, isNot(contains(contains('.mp4'))));
  });

  test('does not invent a fallback for episode URLs', () {
    final candidates = vodMediaCandidates(
      'http://provider.example/series/user/pass/301.ts',
    );

    expect(candidates, [
      'http://provider.example/series/user/pass/301.ts',
      'https://provider.example/series/user/pass/301.ts',
    ]);
  });
}
