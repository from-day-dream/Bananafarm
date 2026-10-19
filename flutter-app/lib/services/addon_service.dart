import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'app_paths.dart';

/// Callback for when a job is received from Blender addon
typedef JobReceivedCallback = void Function(Map<String, dynamic> jobData);

/// Callback for any sign of life from the Blender addon
typedef AddonSeenCallback = void Function();

class AddonService {
  late HttpServer _server;
  bool _isRunning = false;
  int _port = 47288;
  JobReceivedCallback? _onJobReceived;
  AddonSeenCallback? _onAddonSeen;
  DateTime? _lastAddonSeenAt;

  bool get isRunning => _isRunning;
  int get port => _port;

  /// Last time the addon made itself known (heartbeat, temp-root probe or a
  /// job transfer). Null until the first such request after this server start.
  DateTime? get lastAddonSeenAt => _lastAddonSeenAt;

  void _markAddonSeen() {
    _lastAddonSeenAt = DateTime.now();
    _onAddonSeen?.call();
  }

  /// Start the HTTP server to receive jobs from Blender addon
  Future<bool> startServer({
    int port = 47288,
    JobReceivedCallback? onJobReceived,
    AddonSeenCallback? onAddonSeen,
  }) async {
    try {
      _port = port;
      _onJobReceived = onJobReceived;
      _onAddonSeen = onAddonSeen;
      // A fresh server knows nothing about the addon yet; without this reset a
      // restart on a new port could keep the old timestamp "fresh" briefly.
      _lastAddonSeenAt = null;

      _server = await HttpServer.bind('localhost', port);
      _isRunning = true;

      _server.listen((HttpRequest request) async {
        try {
          // Add CORS headers
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
          request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
          request.response.headers.add('Content-Type', 'application/json');

          // Handle OPTIONS preflight
          if (request.method == 'OPTIONS') {
            request.response.statusCode = 200;
            await request.response.close();
            return;
          }

          // Route handling
          if (request.method == 'POST' && request.uri.path == '/transfer-job') {
            _markAddonSeen();
            await _handleTransferJob(request);
          } else if (request.method == 'GET' &&
              request.uri.path == '/temp-root') {
            _markAddonSeen();
            // The addon asks for this before it writes anything, so the app
            // stays the single source of truth for where temp data lives.
            await Directory(AppPaths.incomingRoot).create(recursive: true);
            request.response.write(jsonEncode({
              'temp_root': AppPaths.incomingRoot,
            }));
            await request.response.close();
          } else if (request.method == 'GET' &&
              request.uri.path == '/addon-ping') {
            // Presence heartbeat from the addon; nothing to serve, the
            // timestamp it stamped is the payload.
            _markAddonSeen();
            request.response.write(jsonEncode({'status': 'ok'}));
            await request.response.close();
          } else if (request.method == 'GET' && request.uri.path == '/health') {
            request.response.write(jsonEncode({
              'status': 'ok',
              'timestamp': DateTime.now().toIso8601String(),
            }));
            await request.response.close();
          } else {
            request.response.statusCode = 404;
            request.response.write(jsonEncode({'error': 'Not found'}));
            await request.response.close();
          }
        } catch (e) {
          request.response.statusCode = 500;
          request.response.write(jsonEncode({'error': 'Server error: $e'}));
          await request.response.close();
        }
      });

      print('Addon server listening on http://localhost:$port');
      return true;
    } catch (e) {
      print('Failed to start addon server: $e');
      _isRunning = false;
      return false;
    }
  }

  /// Handle job transfer from Blender addon
  Future<void> _handleTransferJob(HttpRequest request) async {
    try {
      final bytes = await request.toList();
      final body = utf8.decode(bytes.expand((chunk) => chunk).toList());
      final jobData = jsonDecode(body) as Map<String, dynamic>;

      // Callback to notify listeners of new job
      _onJobReceived?.call(jobData);

      request.response.statusCode = 200;
      request.response.write(jsonEncode({
        'status': 'success',
        'message': 'Job received and queued for processing',
        'timestamp': DateTime.now().toIso8601String(),
      }));
      await request.response.close();
    } catch (e) {
      request.response.statusCode = 400;
      request.response.write(jsonEncode({
        'status': 'error',
        'message': 'Failed to process job: $e',
      }));
      await request.response.close();
    }
  }

  /// Stop the HTTP server
  Future<void> stopServer() async {
    if (_isRunning) {
      await _server.close();
      _isRunning = false;
      print('Addon server stopped');
    }
  }

  /// Change the port (requires restart)
  void setPort(int newPort) {
    _port = newPort;
  }
}
