import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../constants/app_constants.dart';
import '../models/draft_job_model.dart';
import '../models/instance_models.dart';
import '../models/job_model.dart';
import '../models/render_provider.dart';
import '../providers/api_keys_provider.dart';
import '../providers/balance_provider.dart';
import '../providers/draft_job_provider.dart';
import '../providers/jobs_provider.dart';
import '../providers/settings_provider.dart';
import 'app_paths.dart';
import 'instance_api_service.dart';
import 'local_jobs_repository.dart';
import 'notification_service.dart';
import 'output_download_service.dart';
import 'providers/gpu_provider_service.dart';
import 'providers/provider_service_factory.dart';

final renderJobManagerProvider = Provider<RenderJobManager>((ref) {
  final manager = RenderJobManager(ref);
  ref.onDispose(manager.dispose);
  return manager;
});

/// Output download progress (0..1) of jobs downloading right now, by job id —
/// automatic or from the download button alike.
final downloadProgressProvider =
    StateProvider<Map<String, double>>((ref) => const {});

/// Orchestrates the full render lifecycle client-side, replacing the old
/// Supabase edge functions, Realtime stream and Upstash Redis polling:
///
///   submit -> create provider instance -> wait for boot + /health
///          -> chunked project upload -> poll /progress
///          -> completed (outputs stay on the instance)
///
/// Instances are destroyed by an explicit user action (cancel, delete
/// instance, delete job), by the startup/upload timeouts, or — with the
/// "Auto download & delete instance" setting on — once a finished job's
/// outputs have been downloaded and verified. A single 5s timer advances
/// every active job, and [initialize] resumes jobs after an app restart.
class RenderJobManager {
  static const _pollInterval = Duration(seconds: 5);

  /// Covers Salad cold starts (node allocation + public image pull).
  static const _startupTimeout = Duration(minutes: 25);

  static const _uploadRetryDelay = Duration(seconds: 30);

  /// Wall-clock bound on the upload phase. Generous enough for a large project
  /// on a slow link, but without it an upload that can never succeed retries
  /// every 30s forever while the rented GPU keeps billing.
  static const _uploadTimeout = Duration(hours: 6);

  /// Consecutive failed /progress polls before asking the provider whether
  /// the instance still exists.
  static const _maxProgressFailures = 36; // ~3 minutes

  /// Budget for the pre-submit Blender version check. Deliberately short — it
  /// sits between the user's click and the rental, and its failure mode is to
  /// give up and proceed, so waiting longer buys nothing.
  static const _preflightTimeout = Duration(seconds: 5);

  final Ref _ref;
  final InstanceApiService _instanceApi;
  final OutputDownloadService _downloader;

  LocalJobsRepository? _repo;
  Timer? _pollTimer;
  bool _ticking = false;

  final Set<String> _uploadsInFlight = {};
  final Map<String, DateTime> _uploadRetryAt = {};
  final Map<String, DateTime> _uploadingSince = {};
  final Map<String, DateTime> _startingSince = {};

  /// Jobs already warned about a slow start, so the notification fires once.
  final Set<String> _slowStartNotified = {};
  final Map<String, int> _progressFailures = {};
  final Set<String> _downloadsInFlight = {};

  RenderJobManager(this._ref,
      {InstanceApiService? instanceApi, OutputDownloadService? downloader})
      : _instanceApi = instanceApi ?? InstanceApiService(),
        _downloader =
            downloader ?? OutputDownloadService(instanceApi ?? InstanceApiService());

  JobsNotifier get _jobs => _ref.read(jobsProvider.notifier);

  /// Load persisted jobs, reconcile interrupted ones, and start polling.
  /// Called once at app startup.
  Future<void> initialize() async {
    _repo = await LocalJobsRepository.create();

    final jobs = _repo!.getJobs();
    for (var i = 0; i < jobs.length; i++) {
      final job = jobs[i];
      // An instance-creation call that never finished cannot be resumed —
      // there is no instance id to reattach to.
      if (job.status == LocalJobStatus.creating && job.instanceId == null) {
        jobs[i] = job.copyWith(
          status: LocalJobStatus.failed,
          errorMessage:
              'App closed during instance creation. Check your provider '
              'console for orphaned instances.',
        );
        await _repo!.saveJob(jobs[i]);
      }
    }
    _jobs.setAll(jobs);

    // Drop temp data nothing points at any more: jobs deleted while the app
    // was closed, and folders stranded by a crash mid-submit.
    unawaited(_sweepOrphanedTempData(jobs));

    // A download the app was closed in the middle of: pick the automatic
    // flow back up, or leave the job showing that it didn't finish.
    for (final job in jobs.where((j) => j.downloadState == DownloadState.downloading)) {
      if (job.canDownload && _ref.read(settingsProvider).autoDownloadAndDelete) {
        unawaited(_autoDownloadAndDelete(job.id));
      } else {
        await _saveAndPublish(job.copyWith(
          downloadState: DownloadState.failed,
          downloadError: 'Download interrupted when the app closed',
        ));
      }
    }

    // Guard against a remount stacking a second, uncancellable poll loop —
    // MainLayoutScreen is both `home:` and the `/dashboard` route.
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _tick());
    _tick();
  }

  void dispose() {
    _pollTimer?.cancel();
  }

  // ============================================
  // Public actions
  // ============================================

  /// Deploy a configured draft job: rents the instance, then hands the job
  /// to the polling loop for boot/upload/render tracking.
  Future<RenderJob> submitJob(DraftJob draft) async {
    final gpu = draft.selectedGpu;
    if (gpu == null) {
      throw StateError('No GPU selected for job ${draft.id}');
    }

    final apiToken = _generateToken();
    var job = RenderJob(
      id: draft.id,
      status: LocalJobStatus.creating,
      provider: gpu.provider,
      gpuName: gpu.gpuName,
      pricePerHour: gpu.pricePerHour,
      gpuOffer: gpu,
      apiToken: apiToken,
      projectZipPath: draft.blendFilePath,
      blenderVersion: draft.blenderVersion,
      renderParams: RenderParams.fromJson(draft.renderParams),
      createdAt: DateTime.now(),
    );
    _jobs.upsert(job);

    // Check the Blender build exists before renting anything. A version the
    // download server doesn't have kills the container during startup, before
    // its API binds — which from here is indistinguishable from a slow boot,
    // so the job would sit out the full 25-minute startup timeout on a GPU
    // that is already billing. One HEAD request costs nothing and turns that
    // into an instant, explicit failure.
    final unavailable = await _blenderVersionUnavailable(draft.blenderVersion);
    if (unavailable != null) {
      _jobs.remove(job.id);
      throw StateError(unavailable);
    }

    final CreatedInstance instance;
    try {
      final service = _serviceFor(gpu.provider);
      instance = await service.createInstance(InstanceRequest(
        jobId: job.id,
        gpu: gpu,
        dockerImage: AppConstants.renderImage,
        blenderVersion: draft.blenderVersion,
        renderParams: draft.renderParams,
        apiToken: apiToken,
        diskGb: _ref.read(settingsProvider).instanceStorageGb,
      ));
    } catch (e) {
      // Leave the draft intact so the user can fix keys/GPU and retry.
      _jobs.remove(job.id);
      rethrow;
    }

    job = job.copyWith(
      status: LocalJobStatus.starting,
      instanceId: instance.instanceId,
      instanceName: instance.instanceName,
      instanceCreatedAt: DateTime.now(),
    );
    _startingSince[job.id] = DateTime.now();
    await _saveAndPublish(job);
    _ref.invalidate(balanceProvider);
    print('✅ Instance created for job ${job.id}: ${instance.instanceId} '
        '(${gpu.provider.label})');
    return job;
  }

  /// Stop an active job: graceful render stop, destroy the instance, keep
  /// the record as cancelled.
  ///
  /// The project zip is kept so the job can be retried; it is only reclaimed
  /// once a completed job's instance is deleted, or the job itself is.
  Future<void> cancelJob(String jobId) async {
    final job = _jobs.byId(jobId);
    if (job == null || !job.isActive) return;

    await _instanceApi.stopRender(job);
    if (job.instanceId != null) {
      await _destroyWithService(job);
    }
    _purgeJobState(jobId);
    await _saveAndPublish(job.copyWith(
      status: LocalJobStatus.cancelled,
      instanceDestroyed: true,
      completedAt: DateTime.now(),
    ));
  }

  /// Turn a job back into a draft on the submission page, deleting its
  /// instance if one is still live.
  ///
  /// Used by Retry (failed/cancelled jobs, [keepGpu] true so the previous GPU
  /// is preselected) and by the slow-start warning (a starting instance that
  /// seems stuck, [keepGpu] false so a different machine gets picked). The
  /// draft keeps the job's id, so the temp folder holding the project zip
  /// carries over untouched.
  Future<void> returnToDraft(String jobId, {required bool keepGpu}) async {
    final old = _jobs.byId(jobId);
    if (old == null) {
      throw StateError('Job no longer exists');
    }
    final starting = old.status == LocalJobStatus.creating ||
        old.status == LocalJobStatus.starting;
    if (!starting && !old.canRetry) {
      throw StateError('This job cannot be sent back to GPU selection');
    }
    final zipPath = old.projectZipPath;
    if (zipPath == null || !await File(zipPath).exists()) {
      throw StateError(
          'Project file missing on disk — resend the job from Blender');
    }

    if (old.hasLiveInstance) {
      await _destroyWithService(old);
    }
    _purgeJobState(jobId);

    final gpu = keepGpu ? old.gpuOffer : null;
    // The draft is saved before the job is removed, so a crash in between
    // leaves a duplicate rather than losing the project.
    await _ref.read(draftJobsProvider.notifier).restoreDraft(DraftJob(
          id: old.id,
          blendFilePath: zipPath,
          originalFilename: old.renderParams.originalFilename ?? 'project',
          // RenderParams round-trips to exactly the keys the addon sent, so
          // the container receives an identical payload. blender_version
          // rides alongside rather than inside RenderParams.
          renderParams: {
            ...old.renderParams.toJson(),
            'blender_version': old.blenderVersion,
          },
          blenderVersion: old.blenderVersion,
          createdAt: DateTime.now(),
          selectedGpu: gpu,
          status: gpu != null ? DraftJobStatus.ready : DraftJobStatus.submitted,
        ));

    // Not _cleanupJobTempData: the draft owns the folder now.
    await _repo?.deleteJob(jobId);
    _jobs.remove(jobId);
    print('↩️ Job $jobId returned to GPU selection');
  }

  /// Destroy the provider instance of a finished job (outputs become
  /// unavailable). The job record stays in the history.
  ///
  /// For a completed job this is the end of the line, so its project files
  /// are reclaimed too. Failed and cancelled jobs keep them for a retry.
  Future<void> destroyInstance(String jobId) async {
    final job = _jobs.byId(jobId);
    if (job == null || !job.hasLiveInstance) return;

    await _destroyWithService(job);
    await _saveAndPublish(job.copyWith(
      instanceDestroyed: true,
      clearProjectZipPath: job.isCompleted,
    ));
    if (job.isCompleted) {
      await _cleanupJobTempData(jobId);
    }
  }

  /// Remove a job from history, destroying its instance first if still alive.
  Future<void> deleteJob(String jobId) async {
    final job = _jobs.byId(jobId);
    if (job == null) return;

    if (job.hasLiveInstance) {
      try {
        await _destroyWithService(job);
      } catch (e) {
        // Deleting the record is the user's explicit request and must succeed
        // even when the instance cannot be reached — a row that refuses to go
        // away is worse than one whose instance needs manual cleanup. This is
        // reachable for a withdrawn provider whose credentials are gone, so
        // say plainly that the instance may still be billing.
        print('⚠️ Could not destroy instance for job $jobId: $e');
        NotificationService().show(
          title: 'Instance may still be running',
          body: 'Job removed, but its ${job.provider.label} instance could not '
              'be destroyed. Check your provider console to stop billing.',
        );
      }
    }
    _purgeJobState(jobId);
    await _cleanupJobTempData(jobId);
    await _repo?.deleteJob(jobId);
    _jobs.remove(jobId);
  }

  // ============================================
  // Polling state machine
  // ============================================

  Future<void> _tick() async {
    if (_ticking || _repo == null) return;
    _ticking = true;
    try {
      final active = _ref.read(jobsProvider).where((j) => j.isActive).toList();
      for (final job in active) {
        try {
          switch (job.status) {
            case LocalJobStatus.creating:
              break; // submitJob call still in flight
            case LocalJobStatus.starting:
              await _advanceStarting(job);
              break;
            case LocalJobStatus.uploading:
              await _maybeStartUpload(job);
              break;
            case LocalJobStatus.rendering:
              await _pollRendering(job);
              break;
            default:
              break;
          }
        } catch (e) {
          print('⚠️ Job ${job.id} tick error: $e');
        }
      }
    } finally {
      _ticking = false;
    }
  }

  Future<void> _advanceStarting(RenderJob job) async {
    if (job.isSlowToStart(DateTime.now()) && _slowStartNotified.add(job.id)) {
      _notify(
        'Instance is taking unusually long',
        '${job.renderParams.displayName} has been starting for over '
            '${AppConstants.slowStartWarning.inMinutes} minutes. Open the job '
            'to view its logs or pick another GPU.',
      );
    }

    final service = _serviceFor(job.provider);

    final InstanceStatus status;
    try {
      status = await service.getInstance(job.instanceId!,
          instanceName: job.instanceName);
    } catch (e) {
      // A provider hiccup (or any error a provider client doesn't already
      // classify as missing/stopped) must not vanish silently — bound it by
      // the same startup timeout as a slow-booting instance instead of
      // retrying forever with nothing ever surfaced to the user.
      print('⚠️ getInstance failed for job ${job.id}, will retry: $e');
      await _checkStartupTimeout(job);
      return;
    }

    // Record what the provider actually bills, once it reports it — the live
    // cost uses this rather than the offer price shown before renting.
    final rate = status.pricePerHour;
    if (rate != null && rate > 0 && job.ratePerHour != rate) {
      job = job.copyWith(ratePerHour: rate);
      await _saveAndPublish(job);
    }

    switch (status.state) {
      case ProviderInstanceState.missing:
        await _fail(job, 'Instance no longer exists on ${job.provider.label}');
        return;
      case ProviderInstanceState.stopped:
        await _fail(job, 'Instance stopped before rendering started');
        return;
      case ProviderInstanceState.pending:
        await _checkStartupTimeout(job);
        return;
      case ProviderInstanceState.running:
        break;
    }

    var current = job;
    if (status.endpoint != null && status.endpoint != job.instanceEndpoint) {
      current = job.copyWith(instanceEndpoint: status.endpoint);
      await _saveAndPublish(current);
    }

    // Instance is up but the container/API may still be initializing
    // (image pull, Blender download).
    if (!await _instanceApi.health(current)) {
      await _checkStartupTimeout(current);
      return;
    }

    final containerStatus = await _instanceApi.getStatus(current);
    _startingSince.remove(current.id);

    if (ContainerJobState.uploadable.contains(containerStatus.state)) {
      current = current.copyWith(status: LocalJobStatus.uploading);
      await _saveAndPublish(current);
      await _maybeStartUpload(current);
    } else if (ContainerJobState.terminal.contains(containerStatus.state)) {
      await _finalizeFromContainer(current, containerStatus.state,
          containerStatus.errorMessage);
    } else {
      // Already extracting/rendering (resumed after an app restart).
      await _saveAndPublish(current.copyWith(status: LocalJobStatus.rendering));
    }
  }

  Future<void> _checkStartupTimeout(RenderJob job) async {
    final since = _startingSince.putIfAbsent(job.id, () => DateTime.now());
    if (DateTime.now().difference(since) > _startupTimeout) {
      print('⏰ Job ${job.id} startup timed out — destroying instance');
      await _destroyWithService(job);
      await _fail(
        job.copyWith(instanceDestroyed: true),
        'Instance never became reachable within '
        '${_startupTimeout.inMinutes} minutes',
      );
    }
  }

  Future<void> _maybeStartUpload(RenderJob job) async {
    if (_uploadsInFlight.contains(job.id)) return;
    final retryAt = _uploadRetryAt[job.id];
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return;

    final since = _uploadingSince.putIfAbsent(job.id, () => DateTime.now());
    if (DateTime.now().difference(since) > _uploadTimeout) {
      print('⏰ Job ${job.id} upload timed out — destroying instance');
      await _destroyWithService(job);
      await _fail(
        job.copyWith(instanceDestroyed: true),
        'Project upload did not complete within '
        '${_uploadTimeout.inHours} hours',
      );
      return;
    }

    final zipPath = job.projectZipPath;
    if (zipPath == null || !await File(zipPath).exists()) {
      await _fail(
          job, 'Project file missing on disk — cannot upload to instance');
      return;
    }

    _uploadsInFlight.add(job.id);
    // Runs outside the tick so a slow upload never blocks other jobs.
    Future(() async {
      try {
        await _instanceApi.uploadProject(
          job,
          zipPath,
          onProgress: (fraction) {
            final current = _jobs.byId(job.id);
            if (current == null || current.status != LocalJobStatus.uploading) {
              return;
            }
            _jobs.upsert(current.copyWith(
              progress: RenderProgressSnapshot(
                progressPercent: fraction * 100,
                statusMessage:
                    'Uploading project (${(fraction * 100).toStringAsFixed(0)}%)',
              ),
            ));
          },
        );
        _uploadRetryAt.remove(job.id);
        _uploadingSince.remove(job.id);
        final current = _jobs.byId(job.id);
        if (current != null && current.status == LocalJobStatus.uploading) {
          await _saveAndPublish(
              current.copyWith(status: LocalJobStatus.rendering));
        }
      } on InstanceStateException {
        // Container is already past the upload phase — treat as rendering.
        final current = _jobs.byId(job.id);
        if (current != null && current.status == LocalJobStatus.uploading) {
          await _saveAndPublish(
              current.copyWith(status: LocalJobStatus.rendering));
        }
      } catch (e) {
        print('⚠️ Upload failed for job ${job.id}, will retry: $e');
        _uploadRetryAt[job.id] = DateTime.now().add(_uploadRetryDelay);
      } finally {
        _uploadsInFlight.remove(job.id);
      }
    });
  }

  Future<void> _pollRendering(RenderJob job) async {
    final ContainerProgress progress;
    try {
      progress = await _instanceApi.getProgress(job);
    } catch (e) {
      await _handleProgressFailure(job);
      return;
    }
    _progressFailures.remove(job.id);

    if (ContainerJobState.terminal.contains(progress.state)) {
      String? errorMessage;
      try {
        errorMessage = (await _instanceApi.getStatus(job)).errorMessage;
      } catch (_) {}
      await _finalizeFromContainer(job, progress.state, errorMessage);
      return;
    }

    // In-memory only: progress snapshots aren't worth a disk write per tick.
    _jobs.upsert(job.copyWith(progress: progress.progress));
  }

  /// The instance stopped answering /progress — after a grace period, ask
  /// the provider whether it still exists.
  Future<void> _handleProgressFailure(RenderJob job) async {
    final failures = (_progressFailures[job.id] ?? 0) + 1;
    _progressFailures[job.id] = failures;
    if (failures < _maxProgressFailures) return;

    _progressFailures.remove(job.id);
    final service = _serviceFor(job.provider);
    try {
      final status = await service.getInstance(job.instanceId!,
          instanceName: job.instanceName);
      if (status.state == ProviderInstanceState.missing ||
          status.state == ProviderInstanceState.stopped) {
        await _fail(
            job, 'Instance disappeared mid-render (${job.provider.label})');
      }
      // Otherwise still reachable per the provider — let polling resume;
      // the /progress failures will keep accumulating if it's truly stuck.
    } catch (e) {
      // Don't let this escape to _tick()'s silent catch-all — a job that
      // stopped responding and whose provider status check also fails
      // needs to end up failed, not stuck forever.
      await _fail(job,
          'Instance stopped responding and could not be reached '
          '(${job.provider.label}): $e');
    }
  }

  Future<void> _finalizeFromContainer(
      RenderJob job, String containerState, String? errorMessage) async {
    var outputFiles = <OutputFileInfo>[];
    try {
      outputFiles = (await _instanceApi.listOutputs(job)).files;
    } catch (e) {
      print('⚠️ Could not list outputs for job ${job.id}: $e');
    }

    final LocalJobStatus status;
    switch (containerState) {
      case ContainerJobState.completed:
        status = LocalJobStatus.completed;
        break;
      case ContainerJobState.partiallyCompleted:
        status = LocalJobStatus.partiallyCompleted;
        break;
      default:
        status = LocalJobStatus.failed;
    }

    // The project is kept whatever the outcome: a failed render can be
    // retried, and a finished one's files go when its instance is deleted.
    final finished = job.copyWith(
      status: status,
      outputFiles: outputFiles,
      errorMessage: errorMessage,
      completedAt: DateTime.now(),
    );
    await _saveAndPublish(finished);

    final autoDownload = finished.canDownload &&
        _ref.read(settingsProvider).autoDownloadAndDelete;
    _notify(
      status == LocalJobStatus.failed
          ? 'Render failed'
          : 'Render ${status == LocalJobStatus.completed ? 'complete' : 'partially complete'}',
      status == LocalJobStatus.failed
          ? '${job.renderParams.displayName}: ${errorMessage ?? 'unknown error'}'
          : autoDownload
              ? '${job.renderParams.displayName} finished — downloading your '
                  'files, then the instance will be deleted.'
              : '${job.renderParams.displayName} finished — '
                  'download your files, then delete the instance to stop billing.',
    );
    if (autoDownload) {
      // Outside the tick: a large download must not hold up other jobs.
      unawaited(_autoDownloadAndDelete(job.id));
    }
  }

  /// Download a finished job's outputs into `<download folder>/<job name>/`,
  /// verified, and record the outcome on the job. Returns the folder.
  ///
  /// Shared by the download button and the automatic flow. Throws (after
  /// recording the failure on the job) if every retry failed, or a
  /// [StateError] if the job can't be downloaded right now.
  Future<String> downloadOutputs(String jobId) async {
    final job = _jobs.byId(jobId);
    if (job == null || !job.canDownload) {
      throw StateError('Outputs are no longer available on the instance');
    }
    if (!_downloadsInFlight.add(jobId)) {
      throw StateError('Already downloading');
    }

    try {
      await _saveAndPublish(job.copyWith(
        downloadState: DownloadState.downloading,
        clearDownloadError: true,
      ));
      _setDownloadProgress(jobId, 0);

      final root = await OutputDownloadService.resolveDownloadRoot(
          _ref.read(settingsProvider).downloadPath);
      final folder = await _downloader.downloadJobOutputs(
        job,
        downloadRoot: root,
        onProgress: (f) => _setDownloadProgress(jobId, f),
      );

      final latest = _jobs.byId(jobId);
      if (latest != null) {
        await _saveAndPublish(latest.copyWith(
          downloadState: DownloadState.downloaded,
          downloadedTo: folder,
        ));
      }
      return folder;
    } catch (e) {
      final latest = _jobs.byId(jobId);
      if (latest != null) {
        await _saveAndPublish(latest.copyWith(
          downloadState: DownloadState.failed,
          downloadError: '$e',
        ));
      }
      rethrow;
    } finally {
      _downloadsInFlight.remove(jobId);
      _clearDownloadProgress(jobId);
    }
  }

  /// The "Auto download & delete instance" flow: delete the instance only
  /// once every output is safely on disk. On failure the instance is kept so
  /// nothing is lost, and the job shows why.
  Future<void> _autoDownloadAndDelete(String jobId) async {
    final name = _jobs.byId(jobId)?.renderParams.displayName ?? jobId;

    final String folder;
    try {
      folder = await downloadOutputs(jobId);
    } on StateError {
      return; // already downloading, or nothing left to download
    } catch (e) {
      _notify('Auto-download failed',
          '$name: $e. The instance was kept so you can download manually.');
      return;
    }

    try {
      await destroyInstance(jobId);
      _notify('Render downloaded',
          '$name saved to $folder — instance deleted.');
    } catch (e) {
      print('⚠️ Could not delete instance after download for job $jobId: $e');
      _notify('Instance may still be running',
          '$name was downloaded to $folder, but its instance could not be '
          'deleted. Delete it from the job to stop billing.');
    }
  }

  /// Progress updates arrive per network read; only publish whole percents
  /// so the UI isn't rebuilt thousands of times per file.
  void _setDownloadProgress(String jobId, double fraction) {
    final notifier = _ref.read(downloadProgressProvider.notifier);
    final previous = notifier.state[jobId];
    if (previous != null && (fraction - previous).abs() < 0.01 && fraction < 1) {
      return;
    }
    notifier.state = {...notifier.state, jobId: fraction};
  }

  void _clearDownloadProgress(String jobId) {
    final notifier = _ref.read(downloadProgressProvider.notifier);
    notifier.state = {...notifier.state}..remove(jobId);
  }

  // ============================================
  // Helpers
  // ============================================

  Future<void> _fail(RenderJob job, String message) async {
    // The project zip is deliberately left on disk — a failed job is retryable
    // and its temp folder is reclaimed when the user deletes or retries it.
    _purgeJobState(job.id);
    await _saveAndPublish(job.copyWith(
      status: LocalJobStatus.failed,
      errorMessage: message,
      completedAt: DateTime.now(),
    ));
    _notify('Render failed',
        '${job.renderParams.displayName}: $message');
  }

  Future<void> _saveAndPublish(RenderJob job) async {
    _jobs.upsert(job);
    await _repo?.saveJob(job);
  }

  Future<void> _destroyWithService(RenderJob job) async {
    if (job.instanceId == null) return;
    final service = _serviceFor(job.provider);
    await service.destroyInstance(job.instanceId!,
        instanceName: job.instanceName);
    _ref.invalidate(balanceProvider);
  }

  GpuProviderService _serviceFor(RenderProvider provider) {
    return buildProviderService(provider, _ref.read(apiKeysProvider));
  }

  /// Delete temp folders belonging to neither a job nor a draft.
  ///
  /// Waits for drafts to load first: they start as an empty list, and sweeping
  /// against that would delete every project still awaiting GPU selection.
  Future<void> _sweepOrphanedTempData(List<RenderJob> jobs) async {
    final drafts = _ref.read(draftJobsProvider.notifier);
    await drafts.ready;
    await AppPaths.sweepOrphans({
      ...jobs.map((j) => j.id),
      ..._ref.read(draftJobsProvider).map((d) => d.id),
    });
  }

  /// Forget every in-memory tracker keyed by this job id.
  void _purgeJobState(String jobId) {
    _uploadsInFlight.remove(jobId);
    _uploadRetryAt.remove(jobId);
    _uploadingSince.remove(jobId);
    _startingSince.remove(jobId);
    _progressFailures.remove(jobId);
    _slowStartNotified.remove(jobId);
  }

  /// Delete a job's temp folder.
  ///
  /// Resolved from the job id rather than `projectZipPath`, because that path
  /// is cleared once a job finishes — deriving from it made this a silent
  /// no-op for exactly the jobs that had temp data left to clean.
  Future<void> _cleanupJobTempData(String jobId) async {
    try {
      final dir = Directory(AppPaths.jobDir(jobId));
      // Same safety rule as draft cleanup: only ever delete a folder that is
      // named after the job it belongs to.
      if (p.basename(dir.path) != jobId) return;
      if (!await dir.exists()) return;
      await dir.delete(recursive: true);
      print('🧹 Cleaned up project files for job $jobId');
    } catch (e) {
      print('⚠️ Failed to clean up project files: $e');
    }
  }

  void _notify(String title, String body) {
    try {
      if (_ref.read(settingsProvider).showNotifications) {
        NotificationService().show(title: title, body: body);
      }
    } catch (e) {
      print('⚠️ Notification failed: $e');
    }
  }

  /// Returns an error message if [version] is definitely not installable on
  /// the render machine, or null to proceed.
  ///
  /// Only a confident 404 blocks a submit. Anything else — no network, a
  /// timeout, a 5xx, a proxy in the way — returns null and lets the job run:
  /// a pre-flight that refuses work whenever it can't reach the internet is
  /// worse than no pre-flight, and the container's own download is the real
  /// gate either way. This is here to catch the one case we *can* be sure
  /// about, which is a development build that was never released.
  static Future<String?> _blenderVersionUnavailable(String version) async {
    if (version.trim().isEmpty) return null;

    final url = AppConstants.blenderDownloadUrl(version);
    try {
      final res = await Dio().head<void>(
        url,
        options: Options(
          followRedirects: true,
          sendTimeout: _preflightTimeout,
          receiveTimeout: _preflightTimeout,
          // Report 404 rather than throwing, so it lands in the check below
          // instead of the catch-all that deliberately lets jobs through.
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode == 404) {
        return 'Blender $version is not a published release, so the render '
            'machine cannot install it. Development and daily builds are not '
            'on download.blender.org. Save your file from a released Blender '
            'version and submit again.';
      }
      return null;
    } catch (e) {
      print('⚠️ Blender version pre-flight skipped ($version): $e');
      return null;
    }
  }

  static String _generateToken() {
    final rand = Random.secure();
    final bytes = List<int>.generate(32, (_) => rand.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
