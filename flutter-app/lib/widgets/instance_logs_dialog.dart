import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/instance_models.dart';
import '../models/job_model.dart';
import '../models/render_provider.dart';
import '../providers/api_keys_provider.dart';
import '../services/providers/gpu_provider_service.dart';
import '../services/providers/provider_service_factory.dart';
import '../utils/toast_utils.dart';

/// Show the job's instance logs: the render container's output and the
/// provider's system log (image pull, container start/stop).
Future<void> showInstanceLogs(
  BuildContext context,
  WidgetRef ref,
  RenderJob job,
) {
  final instanceId = job.instanceId;
  if (instanceId == null) return Future.value();
  final GpuProviderService service;
  try {
    service = buildProviderService(job.provider, ref.read(apiKeysProvider));
  } catch (e) {
    ToastUtils.showError(ScaffoldMessenger.of(context), 'Logs unavailable: $e');
    return Future.value();
  }
  return showDialog<void>(
    context: context,
    builder: (_) => _InstanceLogsDialog(
      title: '${job.renderParams.displayName} — ${job.provider.label} '
          'instance $instanceId',
      load: (source) => service.getLogs(
        instanceId,
        source: source,
        instanceName: job.instanceName,
      ),
    ),
  );
}

class _InstanceLogsDialog extends StatelessWidget {
  final String title;
  final Future<String> Function(InstanceLogSource source) load;

  const _InstanceLogsDialog({required this.title, required this.load});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      child: SizedBox(
        width: size.width * 0.8,
        height: size.height * 0.8,
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [Tab(text: 'Container'), Tab(text: 'System')],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _LogPane(load: () => load(InstanceLogSource.container)),
                    _LogPane(load: () => load(InstanceLogSource.system)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One log stream: fetched when first shown, refreshable, copyable.
class _LogPane extends StatefulWidget {
  final Future<String> Function() load;

  const _LogPane({required this.load});

  @override
  State<_LogPane> createState() => _LogPaneState();
}

class _LogPaneState extends State<_LogPane>
    with AutomaticKeepAliveClientMixin {
  late Future<String> _logs;
  final _scroll = ScrollController();

  @override
  bool get wantKeepAlive => true; // don't refetch when switching tabs

  @override
  void initState() {
    super.initState();
    _logs = _fetch();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<String> _fetch() async {
    final text = await widget.load();
    // Newest lines are at the bottom; start there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
    return text;
  }

  void _refresh() => setState(() => _logs = _fetch());

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<String>(
      future: _logs,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState != ConnectionState.done;
        final text = snapshot.data ?? '';
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: loading || text.isEmpty
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: text));
                            ToastUtils.showSuccess(
                                ScaffoldMessenger.of(context), 'Logs copied');
                          },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                  ),
                  TextButton.icon(
                    onPressed: loading ? null : _refresh,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
            ),
            Expanded(child: _body(context, snapshot, loading, text)),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, AsyncSnapshot<String> snapshot,
      bool loading, String text) {
    if (loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (snapshot.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Could not load logs: ${snapshot.error}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    if (text.trim().isEmpty) {
      return const Center(child: Text('No log lines yet'));
    }
    return Container(
      width: double.infinity,
      color: Colors.black87,
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            text,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontFamilyFallback: ['Menlo', 'Consolas'],
              fontSize: 12,
              color: Colors.white,
              height: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}
