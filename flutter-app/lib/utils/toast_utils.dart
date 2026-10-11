import 'package:flutter/material.dart';

class ToastUtils {
  static void showError(ScaffoldMessengerState messenger, String message) {
    _showToast(messenger, message, Colors.redAccent, Icons.error_outline);
  }

  static void showSuccess(ScaffoldMessengerState messenger, String message) {
    _showToast(messenger, message, Colors.green, Icons.check_circle_outline);
  }

  static void showInfo(ScaffoldMessengerState messenger, String message) {
    _showToast(messenger, message, Colors.blueGrey, Icons.info_outline);
  }

  static void _showToast(
    ScaffoldMessengerState messenger,
    String message,
    Color color,
    IconData icon,
  ) {
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              onPressed: () => messenger.hideCurrentSnackBar(),
              icon: const Icon(Icons.close, color: Colors.white, size: 20),
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
            ),
          ],
        ),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
        elevation: 4,
      ),
    );
  }
}
