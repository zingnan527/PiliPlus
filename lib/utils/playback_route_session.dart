// SPDX-License-Identifier: GPL-3.0-only
// Adapted from taresky/PiliPlus japan-cdn commit 5022c1d.
// Local changes restrict hostname rewriting to an explicit code allowlist.

/// Per-playback CDN candidates with bounded, forward-only recovery.
final class PlaybackRouteSession {
  static const int maxRoutesPerTrack = 8;

  late final _RouteCursor _video;
  _RouteCursor? _audio;

  PlaybackRouteSession({
    required Iterable<String> videoUrls,
    Iterable<String> audioUrls = const [],
    String? preferredVideoHost,
    String? preferredAudioHost,
    Iterable<String> fallbackVideoHostOrder = const [],
    Iterable<String> fallbackAudioHostOrder = const [],
    Set<String> rewriteHostAllowlist = const {},
  }) {
    final normalizedAllowlist = rewriteHostAllowlist
        .map((host) => host.toLowerCase())
        .toSet();
    _video = _RouteCursor(
      _orderedUrls(
        videoUrls,
        preferredHost: preferredVideoHost,
        fallbackHostOrder: fallbackVideoHostOrder,
        rewriteHostAllowlist: normalizedAllowlist,
      ),
    );
    final orderedAudio = _orderedUrls(
      audioUrls,
      preferredHost: preferredAudioHost,
      fallbackHostOrder: fallbackAudioHostOrder,
      rewriteHostAllowlist: normalizedAllowlist,
      allowEmpty: true,
    );
    if (orderedAudio.isNotEmpty) _audio = _RouteCursor(orderedAudio);
  }

  String get videoUrl => _video.current;
  String? get audioUrl => _audio?.current;

  /// Advances to the next server-supplied video URL.
  ///
  /// Every host is returned at most once. Once exhausted, this keeps returning
  /// `null` for the lifetime of the playback session.
  String? nextVideo() => _video.next();

  String? nextAudio() => _audio?.next();

  static List<String> _orderedUrls(
    Iterable<String> urls, {
    String? preferredHost,
    Iterable<String> fallbackHostOrder = const [],
    Set<String> rewriteHostAllowlist = const {},
    bool allowEmpty = false,
  }) {
    final byHost = <String, String>{};
    for (final url in urls) {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !uri.hasScheme ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        continue;
      }
      byHost.putIfAbsent(uri.host.toLowerCase(), uri.toString);
    }
    if (byHost.isEmpty && !allowEmpty) {
      throw ArgumentError.value(urls, 'urls', 'must contain a playable URL');
    }

    final result = <String>[];
    final usedHosts = <String>{};

    void addUrl(String url) {
      if (result.length >= maxRoutesPerTrack) return;
      final host = Uri.parse(url).host.toLowerCase();
      if (usedHosts.add(host)) result.add(url);
    }

    void addHost(String host, {bool allowRewrite = false}) {
      final normalized = host.toLowerCase();
      if (normalized.isEmpty || usedHosts.contains(normalized)) return;
      final serverUrl = byHost[normalized];
      if (serverUrl != null) {
        addUrl(serverUrl);
        return;
      }
      if (allowRewrite && rewriteHostAllowlist.contains(normalized)) {
        final rewritten = _rewriteBilivideoHost(byHost.values, normalized);
        if (rewritten != null) addUrl(rewritten);
      }
    }

    if (preferredHost case final host? when host.isNotEmpty) {
      addHost(host, allowRewrite: true);
    }
    if (result.isEmpty && byHost.isNotEmpty) {
      addUrl(byHost.values.first);
    }
    for (final host in fallbackHostOrder) {
      if (result.length >= maxRoutesPerTrack) break;
      // Automatic recovery may reorder complete server URLs, but must never
      // fabricate a signed URL for a host that the response did not contain.
      addHost(host);
    }
    for (final url in byHost.values) {
      if (result.length >= maxRoutesPerTrack) break;
      addUrl(url);
    }
    return result;
  }

  static String? _rewriteBilivideoHost(
    Iterable<String> serverUrls,
    String targetHost,
  ) {
    if (!targetHost.endsWith('.bilivideo.com')) return null;
    for (final url in serverUrls) {
      final uri = Uri.parse(url);
      if (uri.host.endsWith('.bilivideo.com') &&
          uri.path.contains('/upgcxcode/')) {
        return uri.replace(host: targetHost).toString();
      }
    }
    return null;
  }
}

final class _RouteCursor {
  final List<String> _urls;
  int _index = 0;

  _RouteCursor(List<String> urls) : _urls = List.unmodifiable(urls);

  String get current => _urls[_index];

  String? next() {
    final nextIndex = _index + 1;
    if (nextIndex >= _urls.length) return null;
    _index = nextIndex;
    return current;
  }
}
