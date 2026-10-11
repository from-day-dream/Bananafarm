import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/logger_service.dart';
import '../services/local_storage_service.dart';

// These providers will be overridden in main.dart with the initialized instances
final loggerServiceProvider = Provider<LoggerService>((ref) {
  throw UnimplementedError('LoggerService not initialized');
});

final localStorageServiceProvider = Provider<LocalStorageService>((ref) {
  throw UnimplementedError('LocalStorageService not initialized');
});
