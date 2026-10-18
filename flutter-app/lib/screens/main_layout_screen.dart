import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_theme.dart';
import 'dashboard_screen.dart';
import 'profile_screen.dart';
import 'tabs/jobs_tab.dart';
import '../services/job_queue_service.dart';
import '../services/render_job_manager.dart';
import '../providers/api_keys_provider.dart';

class MainLayoutScreen extends ConsumerStatefulWidget {
  const MainLayoutScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<MainLayoutScreen> createState() => _MainLayoutScreenState();
}

class _MainLayoutScreenState extends ConsumerState<MainLayoutScreen> {
  int _currentIndex = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _currentIndex);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Load persisted jobs, resume interrupted ones, start polling
      ref.read(renderJobManagerProvider).initialize();
      // Initialize job queue worker
      ref.read(jobQueueServiceProvider);
      // One-time clear of credentials for the withdrawn Salad provider.
      ref.read(apiKeysProvider.notifier).purgeWithdrawnSaladCredentials();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Custom Header
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 24.0,
                vertical: 16.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Greeting
                  RichText(
                    text: TextSpan(
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            fontFamily: 'Urbanist',
                            height: 1.2,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                      children: const [
                        TextSpan(
                          text: 'Hello\n',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: 'Banana Farm',
                          style: TextStyle(fontWeight: FontWeight.normal),
                        ),
                      ],
                    ),
                  ),

                  // Tab Navigation
                  Container(
                    decoration: BoxDecoration(
                      color: isDark
                          ? AppTheme.darkSurface
                          : Colors.grey[100],
                      borderRadius: BorderRadius.circular(30),
                    ),
                    padding: const EdgeInsets.all(4),
                    // The Lab tab (AI upscaling / frame interpolation) is
                    // parked, not deleted: lib/screens/tabs/lab_tab.dart and
                    // its services are still in the tree. To bring it back,
                    // re-add `_buildTabButton(2, 'Lab')` here, renumber
                    // Settings to 3, and restore `LabTab()` at index 2 of the
                    // PageView below. The two lists are positionally coupled,
                    // so they must stay the same length and order.
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildTabButton(0, 'Home'),
                        _buildTabButton(1, 'Jobs'),
                        _buildTabButton(2, 'Settings'),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Content Area
            Expanded(
              child: PageView(
                controller: _pageController,
                physics:
                    const NeverScrollableScrollPhysics(), // Disable swipe to enforce tab navigation
                children: const [
                  DashboardScreen(), // Home Tab
                  JobsTab(), // Jobs Tab
                  ProfileScreen(), // Account Tab
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(int index, String label) {
    final isSelected = _currentIndex == index;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _onTabTapped(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            style: TextStyle(
              fontFamily: 'Urbanist',
              fontWeight: FontWeight.w500, // Medium
              fontSize: 12,
              color: isSelected
                  ? (isDark ? Colors.black : Colors.white)
                  : (isDark ? Colors.grey[400] : Colors.grey[600]),
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}
