/// LoRa OTA domain logic for MeshCoreOTA. Frozen against the fork firmware's
/// `OtaUpdate.h` (wire format v2: ops ride inside REQ/RESPONSE datagrams):
/// any change here is a protocol change.
library;

export 'src/wire.dart';
export 'src/ota_status.dart';
export 'src/delta.dart';
export 'src/transfer.dart';
