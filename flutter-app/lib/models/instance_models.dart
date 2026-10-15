import 'gpu_offer.dart';

/// Which of an instance's logs to fetch: the render container's own output,
/// or the provider's host-side log (image pull, container start/stop).
enum InstanceLogSource { container, system }

/// Lifecycle state of a provider instance as reported by the provider API.
enum ProviderInstanceState { pending, running, stopped, missing }

/// Result of polling a provider for an instance's state and endpoint.
class InstanceStatus {
  final ProviderInstanceState state;

  /// Base URL of the container's control API once reachable
  /// (e.g. http://1.2.3.4:40123 or https://podid-8000.proxy.runpod.net).
  final String? endpoint;

  /// The instance's actual $/hr including its disk, when the provider
  /// reports it. Can differ from the offer price shown before renting.
  final double? pricePerHour;

  InstanceStatus({required this.state, this.endpoint, this.pricePerHour});
}

/// Account balance on a provider, in USD.
class ProviderBalance {
  final double balance;

  /// Current total spend rate across the account, when the provider reports
  /// it (RunPod does; Vast does not).
  final double? spendPerHour;

  ProviderBalance({required this.balance, this.spendPerHour});
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

  /// Disk to rent with the instance, in GB.
  final int diskGb;

  InstanceRequest({
    required this.jobId,
    required this.gpu,
    required this.dockerImage,
    required this.blenderVersion,
    required this.renderParams,
    required this.apiToken,
    required this.diskGb,
  });
}
