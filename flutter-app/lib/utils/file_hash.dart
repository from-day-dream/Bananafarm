import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Streams a file through SHA-256 on a worker isolate.
///
/// Hashing a multi-GB project zip on the UI isolate froze the Windows app: the
/// synchronous per-block work stops the platform thread from pumping messages
/// while every 64KB read completion keeps posting to the embedder's task
/// runner, whose message queue is capped at 10,000 entries. Past that,
/// PostMessage fails and the embedder logs "Failed to post message to main
/// thread" until the app is unusable.
Future<String> hashFileInIsolate(String path) {
  return Isolate.run(() async {
    return (await sha256.bind(File(path).openRead()).first).toString();
  });
}
