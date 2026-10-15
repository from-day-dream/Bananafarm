import 'dart:async';

import 'package:flutter/material.dart';

import '../models/job_model.dart';

/// A job's instance cost, counting up while the instance exists.
///
/// Ticks on its own every 5 s (the job poll interval) rather than waiting for
/// job updates: finished jobs whose instance hasn't been deleted are no
/// longer polled, but they are still billing.
class LiveCostText extends StatefulWidget {
  final RenderJob job;
  final TextStyle? style;

  const LiveCostText({super.key, required this.job, this.style});

  /// `$0.42 so far · $0.21/hr` while live, `$0.42 total` once deleted.
  /// Null when the cost is unknown (jobs from before cost tracking).
  static String? format(RenderJob job, DateTime now) {
    final cost = job.costSoFar(now);
    if (cost == null) return null;
    final total = '\$${cost.toStringAsFixed(2)}';
    if (job.instanceDestroyedAt != null) return '$total total';
    final rate = job.effectiveRatePerHour;
    return rate == null
        ? '$total so far'
        : '$total so far · \$${rate.toStringAsFixed(2)}/hr';
  }

  @override
  State<LiveCostText> createState() => _LiveCostTextState();
}

class _LiveCostTextState extends State<LiveCostText> {
  static const _tick = Duration(seconds: 5);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(LiveCostText oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  /// Only tick while the cost is still rising.
  void _syncTimer() {
    final live = widget.job.instanceCreatedAt != null &&
        widget.job.instanceDestroyedAt == null;
    if (live && _timer == null) {
      _timer = Timer.periodic(_tick, (_) => setState(() {}));
    } else if (!live) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = LiveCostText.format(widget.job, DateTime.now());
    if (text == null) return const SizedBox.shrink();
    return Text(text, style: widget.style);
  }
}
