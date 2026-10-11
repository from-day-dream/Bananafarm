import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/gpu_offer.dart';
import '../models/draft_job_model.dart';
import '../models/render_provider.dart';
import '../providers/api_keys_provider.dart';
import '../providers/api_provider.dart';
import '../providers/draft_job_provider.dart';
import '../theme/app_theme.dart';

/// GPU picker fed directly by the provider APIs.
///
/// The provider dropdown lists one entry per configured account, and the
/// Secure toggle picks the marketplace tier within it — so Vast and RunPod
/// each occupy one row instead of two. Returns the chosen [GpuOffer] via
/// Navigator.pop.
class GpuSelectionModal extends ConsumerStatefulWidget {
  final String jobId;
  final GpuOffer? initialSelection;

  const GpuSelectionModal({
    Key? key,
    required this.jobId,
    this.initialSelection,
  }) : super(key: key);

  @override
  ConsumerState<GpuSelectionModal> createState() => _GpuSelectionModalState();
}

class _GpuSelectionModalState extends ConsumerState<GpuSelectionModal> {
  /// One-tap filters for the cards people ask for most often.
  static const _suggestedTerms = ['4090', '5090'];

  /// Split across two controls, but resolved back to a single
  /// [RenderProvider] for every downstream use — that enum stays the unit of
  /// catalog caching, service routing and persistence.
  RenderProviderFamily? _family;
  bool _secure = false;

  String? _selectedGpuId;

  RenderProvider? get _activeProvider => _family?.resolve(_secure);

  final _searchController = TextEditingController();

  /// Mirrored in state (rather than read from the controller at build time) so
  /// typing and the suggestion pills both settle through a single setState.
  String _searchTerm = '';

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSelection?.provider;
    _family = initial?.family;
    _secure = initial?.isSecureTier ?? false;
    _selectedGpuId = widget.initialSelection?.gpuId;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _setSearch(String term) {
    setState(() {
      _searchTerm = term;
      _searchController.text = term;
      _searchController.selection =
          TextSelection.collapsed(offset: term.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(configuredProvidersProvider);

    // One entry per account. `configuredProviders` lists tiers, and a single
    // key yields two of them, so collapse to families for the dropdown.
    final families = configured.map((p) => p.family).toSet().toList();

    // Keeps `_activeProvider!` safe wherever `configured` is non-empty.
    if (_family == null || !families.contains(_family)) {
      _family = families.isNotEmpty ? families.first : null;
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 600, maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Select GPU',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Live availability from your connected providers',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  if (configured.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(flex: 2, child: _buildProviderDropdown(families)),
                        const SizedBox(width: 8),
                        Expanded(child: _buildSecureToggle()),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildSearchRow(context),
                  ],
                ],
              ),
            ),

            // GPU List (or the no-keys empty state)
            Expanded(
              child: configured.isEmpty
                  ? _buildNoKeysState(context)
                  : _buildGpuList(context),
            ),

            // Action Buttons
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: Text(
                      'Cancel',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _canSelect() ? _confirmSelection : null,
                    child: const Text('Select'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _canSelect() {
    if (_selectedGpuId == null || _activeProvider == null) return false;
    final draft = ref
        .watch(draftJobsProvider)
        .where((j) => j.id == widget.jobId)
        .firstOrNull;
    return draft == null || draft.status != DraftJobStatus.zipping;
  }

  void _confirmSelection() {
    final offers =
        ref.read(gpuOffersProvider(_activeProvider!)).valueOrNull ?? [];
    final selected =
        offers.where((gpu) => gpu.gpuId == _selectedGpuId).firstOrNull;
    if (selected != null) {
      print(
          'Selected GPU: ${selected.gpuName}, Provider: ${selected.provider.label}');
      Navigator.of(context).pop(selected);
    }
  }

  /// Shown when the provider has GPUs but none match the search — distinct
  /// from the "provider has nothing available" state, which reads as an outage.
  Widget _buildNoMatchesState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No GPUs match "${_searchTerm.trim()}"',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Try a different term, or clear the search to see every '
              '$_scopeLabel GPU.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => _setSearch(''),
              child: const Text('Clear search'),
            ),
          ],
        ),
      ),
    );
  }

  /// Search field plus the suggestion pills, sitting right of the field.
  Widget _buildSearchRow(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _searchTerm = value),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search GPUs...',
              prefixIcon: const Icon(Icons.search, size: 20),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 40, minHeight: 20),
              suffixIcon: _searchTerm.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      splashRadius: 16,
                      tooltip: 'Clear search',
                      onPressed: () => _setSearch(''),
                    ),
              // Tighter than the global inputDecorationTheme's 16px, which is
              // built for full-width form fields rather than a toolbar row.
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
        ),
        for (final term in _suggestedTerms) ...[
          const SizedBox(width: 8),
          _buildSuggestionPill(term),
        ],
      ],
    );
  }

  /// Tapping toggles: a second tap on the active pill clears the filter.
  Widget _buildSuggestionPill(String term) {
    final isActive = _searchTerm.trim().toLowerCase() == term.toLowerCase();

    return GestureDetector(
      onTap: () => _setSearch(isActive ? '' : term),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isActive
              ? AppTheme.primary.withOpacity(0.1)
              : Colors.transparent,
          border: Border.all(
            color: isActive
                ? AppTheme.primary
                : Theme.of(context).dividerColor.withOpacity(0.4),
            width: isActive ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          term,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: isActive ? AppTheme.primary : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildNoKeysState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.vpn_key_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'No providers configured',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Add a Vast.ai or RunPod API key in Settings to see '
              'available GPUs.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGpuList(BuildContext context) {
    final offersAsync = ref.watch(gpuOffersProvider(_activeProvider!));

    return offersAsync.when(
      data: (gpus) {
        if (gpus.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.videogame_asset_off,
                  size: 48,
                  color: Colors.grey[400],
                ),
                const SizedBox(height: 16),
                Text(
                  'No GPUs Available',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'No $_scopeLabel GPUs available right now',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          );
        }

        // Substring match anywhere in the displayed name. gpuId is skipped on
        // purpose — for Salad it is an opaque UUID, so matching it would hide
        // why a row appeared.
        final term = _searchTerm.trim().toLowerCase();
        final filtered = term.isEmpty
            ? gpus
            : gpus
                .where((gpu) => gpu.gpuName.toLowerCase().contains(term))
                .toList();

        if (filtered.isEmpty) {
          return _buildNoMatchesState(context);
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final gpu = filtered[index];
            final isAvailable = gpu.isAvailable;
            final isSelected = _selectedGpuId == gpu.gpuId;

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GestureDetector(
                onTap: isAvailable
                    ? () {
                        setState(() {
                          _selectedGpuId = gpu.gpuId;
                        });
                      }
                    : null,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isSelected
                          ? AppTheme.primary
                          : (isAvailable
                              ? Theme.of(context)
                                  .dividerColor
                                  .withOpacity(0.2)
                              : Theme.of(context)
                                  .dividerColor
                                  .withOpacity(0.1)),
                      width: isSelected ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    color: isSelected
                        ? AppTheme.primary.withOpacity(0.1)
                        : (isAvailable
                            ? Colors.transparent
                            : Theme.of(context)
                                .disabledColor
                                .withOpacity(0.05)),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Radio<String>(
                        value: gpu.gpuId,
                        groupValue: _selectedGpuId,
                        onChanged: isAvailable
                            ? (value) {
                                setState(() {
                                  _selectedGpuId = value;
                                });
                              }
                            : null,
                        activeColor: AppTheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              gpu.gpuName,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color:
                                        isAvailable ? null : Colors.grey[500],
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              [
                                if (gpu.memoryGb != null)
                                  '${gpu.memoryGb} GB VRAM',
                                if (gpu.availabilityLabel.isNotEmpty)
                                  gpu.availabilityLabel,
                              ].join(' • '),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: isAvailable
                                        ? Colors.grey[600]
                                        : Colors.grey[400],
                                  ),
                            ),
                          ],
                        ),
                      ),
                      if (gpu.pricePerHour != null)
                        Text(
                          '\$${gpu.pricePerHour!.toStringAsFixed(2)}/Hr',
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: isAvailable
                                    ? AppTheme.success
                                    : Colors.grey[400],
                              ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text('Error: $error', textAlign: TextAlign.center),
        ),
      ),
    );
  }

  /// How to name the current scope in copy. The dropdown reads "RunPod", so
  /// the empty states must not read "RunPod Secure" underneath it.
  String get _scopeLabel {
    final family = _family;
    if (family == null) return 'GPU';
    final secure = _secure && family.supportsSecure;
    return secure ? '${family.label} secure' : family.label;
  }

  /// Shared so the dropdown and the toggle read as one control.
  static const double _controlHeight = 44;
  static const double _controlRadius = 8;

  Widget _buildProviderDropdown(List<RenderProviderFamily> families) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: _controlHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[900] : Colors.grey[200],
        borderRadius: BorderRadius.circular(_controlRadius),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<RenderProviderFamily>(
          value: _family,
          isExpanded: true,
          isDense: true,
          borderRadius: BorderRadius.circular(_controlRadius),
          dropdownColor: isDark ? Colors.grey[900] : Colors.white,
          icon: Icon(
            Icons.keyboard_arrow_down,
            size: 20,
            color: isDark ? Colors.grey[400] : Colors.grey[600],
          ),
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: isDark ? Colors.white : Colors.black,
          ),
          items: [
            for (final family in families)
              DropdownMenuItem(
                value: family,
                child: Text(family.label, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (family) {
            if (family == null) return;
            setState(() {
              _family = family;
              // The offer belongs to the old provider's catalog.
              _selectedGpuId = null;
            });
          },
        ),
      ),
    );
  }

  Widget _buildSecureToggle() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final family = _family;
    final supported = family?.supportsSecure ?? false;
    // Salad has a single tier, so the control stays in place but inert —
    // hiding it would reflow the row on every provider change.
    final isOn = supported && _secure;

    final background = isOn
        ? AppTheme.primary
        : (isDark ? Colors.grey[800] : Colors.grey[200]);

    // Black on the brand yellow, matching every other filled accent surface.
    final foreground = isOn
        ? Colors.black
        : (isDark ? Colors.grey[400] : Colors.grey[600]);

    final button = Opacity(
      opacity: supported ? 1 : 0.4,
      child: Container(
        height: _controlHeight,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(_controlRadius),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(isOn ? Icons.lock : Icons.lock_open,
                size: 16, color: foreground),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Secure',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: foreground,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (!supported) {
      return Tooltip(
        message: '${family?.label ?? 'This provider'} has a single tier',
        child: button,
      );
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _secure = !_secure;
          // Different marketplace, different catalog.
          _selectedGpuId = null;
        });
      },
      child: button,
    );
  }
}
