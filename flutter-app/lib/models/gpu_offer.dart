import 'render_provider.dart';

/// A GPU option offered by a provider, fetched live from the provider API.
class GpuOffer {
  final RenderProvider provider;

  /// Human-readable GPU name shown in the UI (e.g. "RTX 4090").
  final String gpuName;

  /// Provider-specific identifier used when creating an instance:
  /// - vast: the gpu_name used in offer search (e.g. "RTX 4090")
  /// - runpod: the gpuTypeId (e.g. "NVIDIA GeForce RTX 4090")
  /// - salad: the gpu_class UUID
  final String gpuId;

  /// Display-only hourly price in USD (billed by the provider directly).
  final double? pricePerHour;

  final int? memoryGb;

  /// Number of machines/units available right now, when the provider
  /// reports a count (vast: offer count, salad: available units).
  final int? availability;

  /// Textual stock signal for providers that report one (RunPod: High/Low...).
  final String? stockStatus;

  GpuOffer({
    required this.provider,
    required this.gpuName,
    required this.gpuId,
    this.pricePerHour,
    this.memoryGb,
    this.availability,
    this.stockStatus,
  });

  bool get isAvailable {
    if (availability != null) return availability! > 0;
    if (stockStatus != null) return stockStatus!.toLowerCase() != 'unavailable';
    return true;
  }

  String get availabilityLabel {
    if (availability != null) return '$availability available';
    if (stockStatus != null) return '$stockStatus availability';
    return '';
  }

  String get displayName {
    final price =
        pricePerHour != null ? ' (\$${pricePerHour!.toStringAsFixed(2)}/hr)' : '';
    return '${provider.label} - $gpuName$price';
  }

  Map<String, dynamic> toJson() => {
        'provider': provider.id,
        'gpu_name': gpuName,
        'gpu_id': gpuId,
        'price_per_hour': pricePerHour,
        'memory_gb': memoryGb,
        'availability': availability,
        'stock_status': stockStatus,
      };

  factory GpuOffer.fromJson(Map<String, dynamic> json) => GpuOffer(
        provider: RenderProviderX.fromId(json['provider'] as String),
        gpuName: json['gpu_name'] as String,
        gpuId: json['gpu_id'] as String,
        pricePerHour: (json['price_per_hour'] as num?)?.toDouble(),
        memoryGb: json['memory_gb'] as int?,
        availability: json['availability'] as int?,
        stockStatus: json['stock_status'] as String?,
      );
}
