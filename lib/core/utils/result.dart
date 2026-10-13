/// Minimal error-handling type used across the services layer.
sealed class Result<T> {
  const Result();

  const factory Result.ok(T value) = Ok<T>;
  const factory Result.err(Object error, [StackTrace? stackTrace]) = Err<T>;

  bool get isOk => this is Ok<T>;
  bool get isErr => this is Err<T>;

  T? get valueOrNull => switch (this) {
        Ok<T>(:final value) => value,
        Err<T>() => null,
      };

  Object? get errorOrNull => switch (this) {
        Ok<T>() => null,
        Err<T>(:final error) => error,
      };

  R fold<R>(R Function(T value) onOk, R Function(Object error, StackTrace? st) onErr) =>
      switch (this) {
        Ok<T>(:final value) => onOk(value),
        Err<T>(:final error, :final stackTrace) => onErr(error, stackTrace),
      };

  /// Maps the success value, keeping failures untouched.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Ok<T>(:final value) => Ok<R>(transform(value)),
        Err<T>(:final error, :final stackTrace) => Err<R>(error, stackTrace),
      };

  /// Chains another fallible operation.
  Future<Result<R>> chain<R>(Future<Result<R>> Function(T value) transform) async {
    return switch (this) {
      Ok<T>(:final value) => await transform(value),
      Err<T>(:final error, :final stackTrace) => Err<R>(error, stackTrace),
    };
  }
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;

  @override
  String toString() => 'Ok($value)';
}

final class Err<T> extends Result<T> {
  const Err(this.error, [this.stackTrace]);

  final Object error;
  final StackTrace? stackTrace;

  @override
  String toString() => 'Err($error)';
}

/// Throw-away helper used by tests and by the pipeline to unwrap or rethrow.
T unwrap<T>(Result<T> result) => switch (result) {
      Ok<T>(:final value) => value,
      Err<T>(:final error, :final stackTrace) =>
        Error.throwWithStackTrace(error, stackTrace ?? StackTrace.current),
    };
