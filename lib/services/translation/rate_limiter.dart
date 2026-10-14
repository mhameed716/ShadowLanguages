import 'dart:async';

/// Paces outgoing requests so a whole book never trips the API limits.
///
/// Three mechanisms, applied in this order:
///
/// 1. **Pacing** — a minimum interval between two requests, so a 400 page book
///    does not fire hundreds of calls in a burst.
/// 2. **Adaptive cooldown** — after a 429/503 the limiter remembers how long it
///    was told to wait (`Retry-After`) and holds *every* worker for that long.
/// 3. **Polite backoff** — repeated failures grow the interval geometrically up
///    to [maxInterval] and it decays again once requests succeed.
class RateLimiter {
  RateLimiter({
    this.minInterval = const Duration(milliseconds: 120),
    this.maxInterval = const Duration(seconds: 20),
    this.failurePenalty = const Duration(seconds: 2),
  });

  final Duration minInterval;
  final Duration maxInterval;
  final Duration failurePenalty;

  DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _currentInterval;
  Duration? _cooldownUntil;
  int _failures = 0;
  int _requests = 0;

  String toString() =>
      'RateLimiter(requests=$_requests, interval=${_currentInterval ?? minInterval})';

  Duration get _interval => _currentInterval ?? minInterval;

  int get requests => _requests;

  /// Waits until the next request is allowed.
  Future<void> acquire({Future<void> Function()? onWait}) async {
    while (true) {
      final now = DateTime.now();
      final cooldownUntil = _cooldownUntil;
      if (cooldownUntil != null && now.isBefore(cooldownUntil)) {
        final wait = cooldownUntil.difference(now);
        await Future<void>.delayed(wait);
        continue;
      }
      final next = _lastRequest.add(_interval);
      if (now.isBefore(next)) {
        await Future<void>.delayed(next.difference(now));
      }
      _lastRequest = DateTime.now();
      _requests++;
      return;
    }
  }

  /// Records a successful request: relax the interval.
  void success() {
    _cooldownUntil = null;
    _failures = 0;
    final current = _interval;
    if (current > minInterval) {
      final relaxed = Duration(
        microseconds:
            (current.inMicroseconds * 0.7).round().clamp(
                  minInterval.inMicroseconds,
                  maxInterval.inMicroseconds,
                ),
      );
      _currentInterval = relaxed;
    }
  }

  /// Records a rate-limit / server error and returns how long to wait.
  Duration failure({Duration? retryAfter}) {
    _failures++;
    final base = retryAfter ?? failurePenalty * _failures;
    final wait = base > maxInterval ? maxInterval : base;
    _cooldownUntil = DateTime.now().add(wait);
    final grown = Duration(
      microseconds: (_interval.inMicroseconds * 1.6)
          .round()
          .clamp(minInterval.inMicroseconds, maxInterval.inMicroseconds),
    );
    _currentInterval = grown;
    return wait;
  }

  void reset() {
    _cooldownUntil = null;
    _currentInterval = minInterval;
    _failures = 0;
  }
}

/// Splits text into pieces small enough for one request.
///
/// Token limits are the number one cause of a refused batch, and a single
/// 12 000 character paragraph can blow the whole request. The splitter is
/// therefore hierarchy aware: paragraph → sentence → clause → hard character
/// cut, so the model always receives complete thoughts.
class SmartChunker {
  const SmartChunker({this.maxCharacters = 1800, this.minCharacters = 24});

  final int maxCharacters;
  final int minCharacters;

  List<String> chunk(String text) {
    final value = text.trim();
    if (value.length <= maxCharacters) return [value];
    final paragraphs = value
        .split(RegExp(r'\n\s*\n'))
        .where((p) => p.trim().isNotEmpty)
        .toList(growable: false);
    if (paragraphs.length > 1) {
      return _pack(paragraphs);
    }
    final sentences = _splitSentences(value);
    if (sentences.length > 1) return _pack(sentences);
    final clauses = _splitClauses(value);
    if (clauses.length > 1) return _pack(clauses);
    return _hardCut(value);
  }

  /// Greedily packs pieces up to [maxCharacters] and then guarantees that no
  /// single piece is still over the limit — a 3 000 character sentence can not
  /// be shrunk by packing, it has to be cut further.
  List<String> _pack(List<String> pieces) {
    final out = <String>[];
    final buffer = StringBuffer();
    for (final piece in pieces) {
      final text = piece.trim();
      if (text.isEmpty) continue;
      if (buffer.isEmpty) {
        buffer.write(text);
      } else if (buffer.length + 1 + text.length <= maxCharacters) {
        buffer.write(' ');
        buffer.write(text);
      } else {
        out.add(buffer.toString());
        buffer
          ..clear()
          ..write(text);
      }
    }
    if (buffer.isNotEmpty) out.add(buffer.toString());
    final packed = out.isEmpty ? <String>[pieces.join(' ')] : out;
    return _enforceLimits(packed);
  }

  /// Splits whatever is still too big: sentence → clause → hard cut.
  ///
  /// Each level only recurses when it actually made the pieces smaller, so the
  /// process always terminates (hard cutting is the fixed point).
  List<String> _enforceLimits(List<String> pieces) {
    final out = <String>[];
    for (final piece in pieces) {
      if (piece.length <= maxCharacters) {
        out.add(piece);
        continue;
      }
      final sentences = _splitSentences(piece)
          .where((s) => s.isNotEmpty && s.length < piece.length)
          .toList(growable: false);
      if (sentences.length > 1) {
        out.addAll(_enforceLimits(_pack(sentences)));
        continue;
      }
      final clauses = _splitClauses(piece)
          .where((s) => s.isNotEmpty && s.length < piece.length)
          .toList(growable: false);
      if (clauses.length > 1) {
        out.addAll(_enforceLimits(_pack(clauses)));
        continue;
      }
      for (var i = 0; i < piece.length; i += maxCharacters) {
        final end = (i + maxCharacters).clamp(0, piece.length);
        out.add(piece.substring(i, end));
      }
    }
    return out;
  }

  List<String> _splitSentences(String text) {
    final matches = RegExp(r'[^.!?…۔؟]+[.!?…۔؟]+|\S[^.!?…۔؟]*$')
        .allMatches(text)
        .map((m) => m.group(0)!.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return matches;
  }

  List<String> _splitClauses(String text) {
    final matches = RegExp(r'[^,;:—–-]+[,;:—–-]?')
        .allMatches(text)
        .map((m) => m.group(0)!.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return matches;
  }

  List<String> _hardCut(String text) {
    final out = <String>[];
    for (var i = 0; i < text.length; i += maxCharacters) {
      final end = (i + maxCharacters).clamp(0, text.length);
      out.add(text.substring(i, end));
    }
    return out;
  }
}
