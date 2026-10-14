/// Thrown when the user aborts a running translation job.
class JobCancelledException implements Exception {
  const JobCancelledException([this.message = 'Job cancelled by operator']);

  final String message;

  @override
  String toString() => 'JobCancelledException: $message';
}

/// Lightweight cooperative cancellation token.
///
/// Long running steps (page extraction, network calls, injection) poll this
/// token and bail out with [JobCancelledException] as soon as it trips.
class JobCancellation {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void addListener(void Function() listener) => _listeners.add(listener);

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
    _listeners.clear();
  }

  /// Throws [JobCancelledException] if the job was cancelled.
  void throwIfCancelled() {
    if (_cancelled) throw const JobCancelledException();
  }

  /// Returns [orElse] when cancelled, otherwise [value].
  T select<T>(T value, T orElse) => _cancelled ? orElse : value;
}
