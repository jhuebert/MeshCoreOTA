/// How a repeater answered a CLI command. The app uses this taxonomy instead
/// of sprinkling string checks across screens.
enum CliReplyKind { ok, rebootNeeded, error, unknown }

/// Classify a raw CLI reply. A lost reply is [CliReplyKind.unknown], never a
/// success: an unknown outcome must be re-read before anything is claimed.
CliReplyKind classifyCliReply(String reply) {
  final text = reply.trim();
  if (text.isEmpty) return CliReplyKind.unknown;
  final lower = text.toLowerCase();
  if (lower.startsWith('err') ||
      lower.startsWith('??') ||
      lower.contains('unknown command')) {
    return CliReplyKind.error;
  }
  if (lower.contains('reboot')) return CliReplyKind.rebootNeeded;
  return CliReplyKind.ok;
}

/// Strip the CLI's `> ` value prefix. A few keys (`extra.sf`) omit it.
String getReplyValue(String reply) {
  final text = reply.trim();
  return text.startsWith('>') ? text.substring(1).trimLeft() : text;
}

/// Whether the firmware rejected the command itself, rather than its value.
bool isUnknownCommand(String reply) =>
    reply.trim().toLowerCase().contains('unknown command');
