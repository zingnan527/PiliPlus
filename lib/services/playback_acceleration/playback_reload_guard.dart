/// Orders native player opens so an old open cannot finish after a new one.
final class PlaybackReloadQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run(
    Future<void> Function() reload, {
    bool Function()? isCurrent,
  }) {
    final pending = _tail.then((_) async {
      if (isCurrent?.call() == false) return;
      await reload();
    });
    // A failed open belongs to its caller, not to subsequent queued opens.
    _tail = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
  }
}

/// Invalidates fallback work when the user changes video or CDN.
final class PlaybackReloadGuard {
  int _generation = 0;

  int get generation => _generation;

  void invalidate() => _generation++;

  bool isCurrent(int generation) => generation == _generation;

  Future<bool> run({
    required Future<void> Function() prepare,
    required bool Function() isPlaybackCurrent,
    required Future<void> Function() reload,
  }) async {
    final generation = _generation;
    await prepare();
    if (!isCurrent(generation) || !isPlaybackCurrent()) return false;
    await reload();
    return true;
  }
}
