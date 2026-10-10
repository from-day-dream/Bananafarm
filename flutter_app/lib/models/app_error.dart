class AppError {
  final String displayText;
  final dynamic error;
  final StackTrace? stackTrace;
  final ErrorSeverity severity;

  AppError({
    required this.displayText,
    this.error,
    this.stackTrace,
    this.severity = ErrorSeverity.error,
  });

  @override
  String toString() => 'AppError(display: $displayText, error: $error)';
}

enum ErrorSeverity { warning, error, critical }
