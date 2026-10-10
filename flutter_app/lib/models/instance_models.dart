import 'gpu_offer.dart';

/// Lifecycle state of a provider instance as reported by the provider API.
enum ProviderInstanceState { pending, running, stopped, missing }

/// Result of polling a provider for an instance's state and endpoint.
class InstanceStatus {
  final ProviderInstanceState state;

  /// Base URL of the container's control API once reachable
  /// (e.g. http://1.2.3.4:40123 or https://podid-8000.proxy.runpod.net).
  final String? endpoint;

  InstanceStatus({required this.state, this.endpoint});
}

/// Result of creating an instance on a provider.
class CreatedInstance {
  /// vast contract id / runpod pod id / salad container group id.
  final String instanceId;

  /// Salad container group name — required for its GET/DELETE calls.
  final String? instanceName;

  CreatedInstance({required this.instanceId, this.instanceName});
}

/// Everything a provider needs to deploy the render container for a job.
class InstanceRequest {
  final String jobId;
  final GpuOffer gpu;
  final String dockerImage;
  final String blenderVersion;
  final Map<String, dynamic> renderParams;

  /// Per-job bearer token protecting the container's control API.
  final String apiToken;

  InstanceRequest({
    required this.jobId,
    required this.gpu,
    required this.dockerImage,
    required this.blenderVersion,
    required this.renderParams,
    required this.apiToken,
  });
}
