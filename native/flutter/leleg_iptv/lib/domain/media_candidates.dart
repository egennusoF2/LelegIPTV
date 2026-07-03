List<String> vodMediaCandidates(String originalUrl) {
  final urls = <String>[];

  void add(String value) {
    if (value.isNotEmpty && !urls.contains(value)) urls.add(value);
  }

  String? alternateScheme(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return null;
    return switch (uri.scheme) {
      'https' => uri.replace(scheme: 'http').toString(),
      'http' => uri.replace(scheme: 'https').toString(),
      _ => null,
    };
  }

  add(originalUrl);
  final alternate = alternateScheme(originalUrl);
  if (alternate != null) add(alternate);
  return urls;
}
