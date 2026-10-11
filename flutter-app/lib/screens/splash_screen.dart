import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../main.dart'; // Import to access initializationStatus

/// Splash Screen that shows in a frameless window while the app is initializing
/// 
/// **Window Specifications:**
/// - Window Size: 600x400 logical pixels (frameless, borderless)
/// - Style: Discord/Riot client launcher style
/// 
/// **Lottie Animation Specifications:**
/// - Container Size: 300x300 logical pixels
/// - Animation Scale (X & Y): 1.2 (120% of container)
/// - Effective Animation Size: 360x360 pixels
/// - Position: Centered in window
/// 
/// When replacing the placeholder image with a Lottie animation:
/// 1. Add your Lottie JSON file to assets/animations/splash.json
/// 2. Uncomment the Lottie widget code below
/// 3. Remove the Image.asset widget
class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _version = packageInfo.version;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent, // Transparent to show background if needed
      body: ClipRRect(
        borderRadius: BorderRadius.circular(16.0),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background Image
            Image.asset(
              'assets/images/splash_screen.png',
              fit: BoxFit.cover,
            ),
            


            // Bottom Gradient Overlay
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 250,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black, Colors.transparent],
                  ),
                ),
              ),
            ),



            // Bottom Left: Icon + App Name + Status
            Positioned(
              left: 20,
              bottom: 20,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/icon/icon.png',
                    width: 32,
                    height: 32,
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'bananafarm',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'Inter', 
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            'v$_version',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              fontFamily: 'Inter',
                            ),
                          ),
                          const SizedBox(width: 8),
                          ValueListenableBuilder<String>(
                            valueListenable: initializationStatus,
                            builder: (context, status, child) {
                              return Text(
                                '•  $status',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.5),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w400,
                                  fontFamily: 'Inter',
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Bottom Right: Loading Animation
            Positioned(
              right: 20,
              bottom: 20,
              child: SizedBox(
                width: 24, 
                height: 24,
                child: Lottie.asset(
                  'assets/animations/loading.json',
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
