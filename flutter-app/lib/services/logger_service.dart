import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

enum LogLevel { debug, info, warning, error }

extension LogLevelString on LogLevel {
  String get name {
    switch (this) {
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warning:
        return 'WARNING';
      case LogLevel.error:
        return 'ERROR';
    }
  }
}

/// Logger service that stores logs in SQLite database
class LoggerService {
  static const String _dbName = 'render_farm_logs.db';
  static const String _tableName = 'logs';
  static const int _maxLogs = 1000;

  late Database _db;
  bool _initialized = false;

  /// Initialize the logger service and create database
  Future<void> initialize() async {
    if (_initialized) return;

    final appDir = await getApplicationSupportDirectory();
    final dbPath = appDir.path;
    final path = join(dbPath, _dbName);

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );

    _initialized = true;
    info('Logger service initialized');
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        level TEXT NOT NULL,
        message TEXT NOT NULL,
        source TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  /// Log a debug message
  void debug(String message, {String? source}) {
    _log(LogLevel.debug, message, source: source);
  }

  /// Log an info message
  void info(String message, {String? source}) {
    _log(LogLevel.info, message, source: source);
  }

  /// Log a warning message
  void warning(String message, {String? source}) {
    _log(LogLevel.warning, message, source: source);
  }

  /// Log an error message
  void error(String message, {String? source, dynamic exception, StackTrace? stackTrace}) {
    final fullMessage = exception != null
        ? '$message\nException: $exception${stackTrace != null ? '\nStack: $stackTrace' : ''}'
        : message;
    _log(LogLevel.error, fullMessage, source: source);
  }

  Future<void> _log(
    LogLevel level,
    String message, {
    String? source,
  }) async {
    if (!_initialized) return;

    final now = DateTime.now();
    final timestamp = now.toIso8601String();

    try {
      await _db.insert(
        _tableName,
        {
          'timestamp': timestamp,
          'level': level.name,
          'message': message,
          'source': source ?? 'app',
          'created_at': now.millisecondsSinceEpoch,
        },
      );

      // Clean up old logs if exceeding max
      await _cleanupLogs();

      // Print to console for debugging
      print('[${level.name}] ${now.toLocal()}: $message');
    } catch (e) {
      print('Error logging message: $e');
    }
  }

  /// Clean up old logs to keep database size manageable
  Future<void> _cleanupLogs() async {
    try {
      final count = Sqflite.firstIntValue(
        await _db.rawQuery('SELECT COUNT(*) FROM $_tableName'),
      ) ?? 0;

      if (count > _maxLogs) {
        // Delete oldest logs
        final toDelete = count - _maxLogs;
        await _db.rawDelete(
          'DELETE FROM $_tableName WHERE id IN (SELECT id FROM $_tableName ORDER BY created_at ASC LIMIT $toDelete)',
        );
      }

      // Also delete logs older than 7 days
      final sevenDaysAgo = DateTime.now().subtract(Duration(days: 7)).millisecondsSinceEpoch;
      await _db.delete(
        _tableName,
        where: 'created_at < ?',
        whereArgs: [sevenDaysAgo],
      );
    } catch (e) {
      print('Error cleaning up logs: $e');
    }
  }

  /// Get logs for a specific date
  Future<List<Map<String, dynamic>>> getLogsForDate(DateTime date) async {
    if (!_initialized) return [];

    final startOfDay = DateTime(date.year, date.month, date.day);
    final endOfDay = startOfDay.add(Duration(days: 1));

    return _db.query(
      _tableName,
      where: 'timestamp >= ? AND timestamp < ?',
      whereArgs: [startOfDay.toIso8601String(), endOfDay.toIso8601String()],
      orderBy: 'timestamp DESC',
    );
  }

  /// Get all logs
  Future<List<Map<String, dynamic>>> getAllLogs({int limit = 100}) async {
    if (!_initialized) return [];

    return _db.query(
      _tableName,
      orderBy: 'timestamp DESC',
      limit: limit,
    );
  }

  /// Get logs by level
  Future<List<Map<String, dynamic>>> getLogsByLevel(LogLevel level, {int limit = 100}) async {
    if (!_initialized) return [];

    return _db.query(
      _tableName,
      where: 'level = ?',
      whereArgs: [level.name],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
  }

  /// Get logs by source
  Future<List<Map<String, dynamic>>> getLogsBySource(String source, {int limit = 100}) async {
    if (!_initialized) return [];

    return _db.query(
      _tableName,
      where: 'source = ?',
      whereArgs: [source],
      orderBy: 'timestamp DESC',
      limit: limit,
    );
  }

  /// Export logs as CSV string
  Future<String> exportLogsAsCsv() async {
    if (!_initialized) return '';

    final logs = await getAllLogs(limit: 10000);

    final buffer = StringBuffer('Timestamp,Level,Source,Message\n');
    for (final log in logs) {
      final timestamp = log['timestamp'] as String;
      final level = log['level'] as String;
      final source = log['source'] as String?;
      final message = (log['message'] as String).replaceAll('"', '""'); // Escape quotes

      buffer.write('"$timestamp","$level","${source ?? 'app'}","$message"\n');
    }

    return buffer.toString();
  }

  /// Clear all logs
  Future<void> clearAllLogs() async {
    if (!_initialized) return;

    await _db.delete(_tableName);
    info('All logs cleared');
  }

  /// Get log count
  Future<int> getLogCount() async {
    if (!_initialized) return 0;

    final count = Sqflite.firstIntValue(
      await _db.rawQuery('SELECT COUNT(*) FROM $_tableName'),
    );
    return count ?? 0;
  }

  /// Close database
  Future<void> close() async {
    if (_initialized) {
      await _db.close();
      _initialized = false;
    }
  }
}
