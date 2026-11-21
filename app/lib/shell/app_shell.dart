import 'package:flutter/material.dart';

import '../screens/app_settings_screen.dart';
import '../screens/firmware_screen.dart';
import '../screens/target_screen.dart';
import '../widgets/common.dart';
import 'connection_button.dart';
import 'repeater_hub_screen.dart';

/// The persistent shell. The connection lives above it, so navigating between
/// management destinations never tears down the link or the update activity.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _destinations = <(IconData, String, String)>[
    (repeaterIcon, 'Hub', 'Repeater overview and activities'),
    (Icons.people_outline, 'Repeaters', 'Choose the repeater to manage'),
    (libraryIcon, 'Library', 'Firmware files on this device'),
    (Icons.settings_outlined, 'Settings', 'Offline mode and local data'),
  ];

  static const _pages = <Widget>[
    RepeaterHubScreen(),
    TargetScreen(),
    FirmwareScreen(updateMode: false),
    AppSettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final selected = _index.clamp(0, _destinations.length - 1);
    return Scaffold(
      appBar: AppBar(
        title: Text(_destinations[selected].$2),
        actions: const [ConnectionButton()],
      ),
      body: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: selected,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              destinations: _destinations
                  .map((d) => NavigationRailDestination(
                      icon: Icon(d.$1), label: Text(d.$2)))
                  .toList(),
            ),
          if (wide) const VerticalDivider(width: 1),
          Expanded(child: IndexedStack(index: selected, children: _pages)),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: selected,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: _destinations
                  .map((d) => NavigationDestination(
                      icon: Icon(d.$1), label: d.$2))
                  .toList(),
            ),
    );
  }
}
