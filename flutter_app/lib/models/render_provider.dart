/// GPU cloud providers the app can deploy render jobs to directly.
///
/// Vast and RunPod each sell the same account across two marketplaces — a
/// vetted-datacenter tier and a cheaper open one — so each appears twice, with
/// its own catalog query and pricing. Salad has a single tier.
///
/// The UI presents this as a provider plus a Secure toggle rather than as five
/// peers; see [RenderProviderFamily].
enum RenderProvider { vast, vastSecure, runpodSecure, runpodCommunity, salad }

extension RenderProviderX on RenderProvider {
  /// Stable identifier used for persistence (job records, draft GPU selection).
  String get id {
    switch (this) {
      case RenderProvider.vast:
        return 'vast';
      case RenderProvider.vastSecure:
        return 'vast_secure';
      case RenderProvider.runpodSecure:
        return 'runpod_secure';
      case RenderProvider.runpodCommunity:
        return 'runpod_community';
      case RenderProvider.salad:
        return 'salad';
    }
  }

  String get label {
    switch (this) {
      case RenderProvider.vast:
        return 'Vast.ai';
      case RenderProvider.vastSecure:
        return 'Vast.ai Secure';
      case RenderProvider.runpodSecure:
        return 'RunPod Secure';
      case RenderProvider.runpodCommunity:
        return 'RunPod Community';
      case RenderProvider.salad:
        return 'Salad';
    }
  }

  /// Value passed to the container's PROVIDER env var (selects bind host).
  String get containerProviderName {
    switch (this) {
      case RenderProvider.vast:
      case RenderProvider.vastSecure:
        return 'vast';
      case RenderProvider.runpodSecure:
      case RenderProvider.runpodCommunity:
        return 'runpod';
      case RenderProvider.salad:
        return 'salad';
    }
  }

  /// Which account/credential this tier belongs to.
  RenderProviderFamily get family {
    switch (this) {
      case RenderProvider.vast:
      case RenderProvider.vastSecure:
        return RenderProviderFamily.vast;
      case RenderProvider.runpodSecure:
      case RenderProvider.runpodCommunity:
        return RenderProviderFamily.runpod;
      case RenderProvider.salad:
        return RenderProviderFamily.salad;
    }
  }

  /// True for the vetted-datacenter tier of a family that has one.
  bool get isSecureTier {
    switch (this) {
      case RenderProvider.vastSecure:
      case RenderProvider.runpodSecure:
        return true;
      case RenderProvider.vast:
      case RenderProvider.runpodCommunity:
      case RenderProvider.salad:
        return false;
    }
  }

  static RenderProvider fromId(String id) {
    switch (id) {
      // Predates the secure/standard split, and meant the unfiltered search —
      // which is exactly what `vast` still means, so old records keep their
      // meaning rather than being silently promoted to the datacenter tier.
      case 'vast':
        return RenderProvider.vast;
      case 'vast_secure':
        return RenderProvider.vastSecure;
      case 'runpod_secure':
      // Legacy job records used plain 'runpod' for the secure cloud.
      case 'runpod':
        return RenderProvider.runpodSecure;
      case 'runpod_community':
        return RenderProvider.runpodCommunity;
      case 'salad':
        return RenderProvider.salad;
      default:
        throw ArgumentError('Unknown render provider: $id');
    }
  }
}

/// A provider account, independent of which marketplace tier is selected.
///
/// Named `RenderProviderFamily` rather than `ProviderFamily` because Riverpod
/// exports a `ProviderFamily` of its own, and every file that touches this
/// also imports Riverpod.
///
/// One API key maps to one family; a family maps to one or two
/// [RenderProvider] values. The GPU picker chooses a family and a Secure flag
/// and resolves them back to the enum, which stays the unit of persistence,
/// service routing and catalog caching.
enum RenderProviderFamily { vast, runpod, salad }

extension RenderProviderFamilyX on RenderProviderFamily {
  String get label {
    switch (this) {
      case RenderProviderFamily.vast:
        return 'Vast.ai';
      case RenderProviderFamily.runpod:
        return 'RunPod';
      case RenderProviderFamily.salad:
        return 'Salad';
    }
  }

  /// Whether this family sells a vetted-datacenter tier. Salad does not, so
  /// its Secure control is inert.
  bool get supportsSecure {
    switch (this) {
      case RenderProviderFamily.vast:
      case RenderProviderFamily.runpod:
        return true;
      case RenderProviderFamily.salad:
        return false;
    }
  }

  /// `secure` is ignored by families that have no secure tier, so callers can
  /// carry one flag across a provider change without normalising it first.
  RenderProvider resolve(bool secure) {
    switch (this) {
      case RenderProviderFamily.vast:
        return secure ? RenderProvider.vastSecure : RenderProvider.vast;
      case RenderProviderFamily.runpod:
        return secure
            ? RenderProvider.runpodSecure
            : RenderProvider.runpodCommunity;
      case RenderProviderFamily.salad:
        return RenderProvider.salad;
    }
  }
}
