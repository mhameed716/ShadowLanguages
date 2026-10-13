import 'package:flutter/foundation.dart';

/// Severity of a terminal log line.
enum LogLevel {
  system(0, 'SYS'),
  info(1, 'INF'),
  success(2, 'OK '),
  warning(3, 'WRN'),
  error(4, 'ERR'),
  incoming(5, '<<<'),
  outgoing(6, '>>>');

  const LogLevel(this.weight, this.tag);

  final int weight;
  final String tag;

  bool operator >=(LogLevel other) => weight >= other.weight;
  bool operator <=(LogLevel other) => weight <= other.weight;
}

/// A single line of the live log stream.
@immutable
class LogEntry {
  const LogEntry({
    required this.level,
    required this.message,
    required this.timestamp,
    this.detail,
  });

  final LogLevel level;
  final String message;

  /// Optional technical payload (HTTP status, stack snippet, ...).
  final String? detail;
  final DateTime timestamp;

  /// `[HH:MM:SS]`
  String get clock {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  /// `[System]: Source language detected successfully: [English - 99.9%]`
  String get prefix => '[${level.tag}]';

  @override
  String toString() => '$clock $prefix $message';
}

/// Ring buffer backed live log stream.
class LogBus extends ChangeNotifier {
  LogBus({this.capacity = 400});

  final int capacity;
  final List<LogEntry> _entries = [];

  List<LogEntry> get entries => List.unmodifiable(_entries);

  int get length => _entries.length;

  void log(LogLevel level, String message, {String? detail}) {
    _entries.add(LogEntry(
      level: level,
      message: message,
      detail: detail,
      timestamp: DateTime.now(),
    ));
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
    notifyListeners();
  }

  void system(String m, {String? detail}) => log(LogLevel.system, m, detail: detail);
  void info(String m, {String? detail}) => log(LogLevel.info, m, detail: detail);
  void success(String m, {String? detail}) => log(LogLevel.success, m, detail: detail);
  void warning(String m, {String? detail}) => log(LogLevel.warning, m, detail: detail);
  void error(String m, {String? detail}) => log(LogLevel.error, m, detail: detail);

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// Full transcript, handy for "copy logs" / bug reports.
  String dump({LogLevel minLevel = LogLevel.system}) => _entries
      .where((e) => e.level.weight >= minLevel.weight)
      .map((e) => e.toString())
      .join('\n');
}
