import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Choose which directly connected repeater the management screens address.
/// This is a single node, never the tag-defined fleet group.
class RepeaterPickerSheet extends StatefulWidget {
  const RepeaterPickerSheet({super.key});

  @override
  State<RepeaterPickerSheet> createState() => _RepeaterPickerSheetState();
}

class _RepeaterPickerSheetState extends State<RepeaterPickerSheet> {
  final _keyController = TextEditingController();
  String? _keyError;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  void _useKey(AppState app) {
    final contact = app.addManualTarget(_keyController.text);
    if (contact == null) {
      setState(() => _keyError = 'Enter the 64-character public key.');
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.92,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              const Icon(Icons.cell_tower, color: OtaTheme.accent),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('Choose a repeater',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                tooltip: 'Close',
              ),
            ],
          ),
          const SectionHeader('Known repeaters'),
          if (app.contacts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'The companion has no repeaters in its list yet.',
                style: TextStyle(color: OtaTheme.textMuted, fontSize: 12),
              ),
            ),
          for (final contact in app.contacts)
            ListTile(
              leading: const Icon(Icons.cell_tower, color: OtaTheme.accent),
              title: Text(contact.name.isEmpty
                  ? contact.publicKeyHex.substring(0, 12)
                  : contact.name),
              subtitle: Text(contact.publicKeyHex.substring(0, 12),
                  style: const TextStyle(
                      color: OtaTheme.textMuted, fontSize: 11)),
              onTap: () {
                app.selectTarget(contact);
                Navigator.of(context).pop();
              },
            ),
          const SectionHeader('Public key'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _keyController,
              decoration: InputDecoration(
                labelText: '64-character public key',
                errorText: _keyError,
              ),
              autocorrect: false,
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FilledButton.icon(
              onPressed: () => _useKey(app),
              icon: const Icon(nextIcon),
              label: const Text('Use key'),
            ),
          ),
        ],
      ),
    );
  }
}
