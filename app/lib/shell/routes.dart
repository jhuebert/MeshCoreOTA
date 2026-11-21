import 'package:flutter/material.dart';

import '../screens/connect_screen.dart';
import '../screens/firmware_screen.dart';

/// Named entry points for activities pushed from the shell. The update keeps
/// its own in-activity wizard navigation; this only opens the activity.
class AppRoutes {
  static const update = '/update';
  static const library = '/library';
}

Route<dynamic>? generateRoute(RouteSettings settings) => switch (settings.name) {
      AppRoutes.update => MaterialPageRoute(
          builder: (_) => const ConnectScreen(), settings: settings),
      AppRoutes.library => MaterialPageRoute(
          builder: (_) => const FirmwareScreen(updateMode: false),
          settings: settings),
      _ => null,
    };
