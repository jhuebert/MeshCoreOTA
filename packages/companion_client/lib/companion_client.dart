/// Companion-protocol client for the phone app's needs: enumerate the
/// companion's contacts, remote-login to a repeater, and run the remote admin
/// CLI over `TXT_MSG`.
///
/// Built directly on [RadioLink]'s `sendFrame`/`pushes` surface (the transport
/// extension added for this app). All exchanges are push-driven and must run
/// one at a time; the UI serializes them. Pure Dart, no Flutter imports.
library;

export 'src/companion_client.dart';
