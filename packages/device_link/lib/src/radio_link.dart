import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// Acknowledgement that the companion queued a `CMD_SEND_BINARY_REQ`:
/// `RESP_CODE_SENT` (`[06][flooded(1)][tag(4)][est_timeout(4)]`).
class BinaryRequestSent {
  const BinaryRequestSent({
    required this.tag,
    required this.flooded,
    required this.estTimeoutMs,
  });

  /// The tag the companion wove into the request datagram. The node echoes it
  /// in its response; `PUSH_CODE_BINARY_RESPONSE` carries it back verbatim.
  final int tag;

  /// Whether the request went out as a flood (the contact had no stored
  /// DIRECT path) rather than a direct route.
  final bool flooded;

  /// The companion's estimated round-trip window.
  final int estTimeoutMs;
}

/// Device link connection state.
enum LinkState { disconnected, connecting, connected }

/// Callback invoked for every raw over-air frame the device forwards.
typedef RawRxListener = void Function(double snr, int rssi, Uint8List raw);

/// Abstraction over a MeshCore companion device used purely as a radio.
abstract class RadioLink {
  Future<void> connect();
  Future<void> disconnect();
  Stream<LinkState> get state;
  LinkState get currentState;

  /// Transmit an arbitrary MeshCore packet on air.
  Future<void> sendRawPacket(Uint8List packet, [int priority = 0]);

  /// Send a custom binary request to a contact (`CMD_SEND_BINARY_REQ`).
  ///
  /// The companion encrypts `tag(4) | [reqData...]` as a REQ datagram to
  /// [contact]'s public key, routes it like any other direct message (its
  /// stored DIRECT path, or a flood when none is known — see [BinaryRequestSent.flooded]),
  /// and answers `RESP_CODE_SENT` once the datagram is queued on the radio.
  /// The reply, if the node sends one, arrives later as
  /// `PUSH_CODE_BINARY_RESPONSE` (0x8C) on [pushes].
  ///
  /// This is the only way an app that does not hold the companion's private
  /// key can reach a node over an encrypted request/response exchange.
  Future<BinaryRequestSent> sendBinaryRequest(
      Contact contact, List<int> reqData);

  /// Overwrite [contact]'s stored DIRECT path in the companion, like the
  /// `change_path` CLI in meshcli. Binary requests have no per-packet path
  /// field, so this is the only lever for routing them when the path the
  /// companion saved for the contact is wrong.
  ///
  /// [path] is the path bytes; [encodedPathLen] the wire path_len byte
  /// (`PathUtils.encodePathLen`). 0xFF floods.
  Future<void> setContactPath(Contact contact,
      {required List<int> path, required int encodedPathLen});

  /// Register the callback for received raw frames.
  void setRawRxListener(RawRxListener? listener);

  /// Fire-and-forget write of a companion frame (no reply correlation).
  ///
  /// Used for commands whose results arrive as pushes rather than as request
  /// replies (e.g. `CMD_SEND_LOGIN`, `CMD_SEND_TXT_MSG`). Writes are serialized
  /// against in-flight requests; nothing is returned, so the caller watches
  /// [pushes] for the outcome.
  Future<void> sendFrame(Uint8List frame);

  /// Broadcast of every inbound frame the link accepts, before request
  /// matching.
  ///
  /// Requests issued through this link still deliver their replies via the
  /// request machinery; this stream additionally exposes frames that carry no
  /// request life of their own (`PUSH_CODE_*`). Consumers must filter by
  /// response code themselves — a fire-and-forget command's correlated reply
  /// (e.g. `RESP_CODE_SENT`) appears here too, indistinguishable by channel.
  Stream<Uint8List> get pushes;

  Future<DeviceInfo> deviceInfo();
  Future<ParsedSelfInfo> selfInfo();
  Future<RadioParams> radioParams();

  /// The physical radio's noise floor and airtime counters
  /// (`CMD_GET_STATS` + `STATS_TYPE_RADIO`).
  Future<RadioStats> radioStats();

  /// Write radio parameters. When [clientRepeat] is supplied it is encoded
  /// explicitly (0 or 1); `null` leaves the optional byte out.
  Future<void> setRadioParams(RadioParams params, {bool? clientRepeat});
  Future<void> setTxPower(int dbm);

  /// Reboot the device (`CMD_REBOOT`).
  ///
  /// The firmware reboots the hardware — needed for saved radio-pref changes
  /// (`CMD_SET_RADIO_PARAMS`) to take effect — and does not send a reply.
  Future<void> reboot();

  /// Power the device off through the physical CLI (`CMD_RUN_CLI_COMMAND`
  /// `poweroff`, firmware v14+). No normal reply is expected.
  Future<void> shutdown();
  Future<BatteryReading?> battery();

  /// Read the device's radio tuning parameters (`CMD_GET_TUNING_PARAMS`).
  Future<TuningParams> tuningParams();

  /// Write the device's radio tuning parameters (`CMD_SET_TUNING_PARAMS`).
  Future<void> setTuningParams(TuningParams params);

  /// Set the device's path-hash mode (`CMD_SET_PATH_HASH_MODE`, fw v10+).
  Future<void> setPathHashMode(int mode);

  /// Run a CLI command on the device (`CMD_RUN_CLI_COMMAND`, fw v14+).
  ///
  /// Returns the CLI reply text (`RESP_CODE_CLI_REPLY`).
  Future<String> runCliCommand(String command);

  /// The device's allowed repeat-frequency ranges
  /// (`CMD_GET_ALLOWED_REPEAT_FREQ`): raw `[lower(4)][upper(4)]...` bytes.
  Future<Uint8List> getAllowedRepeatFreq();
}

/// Frames the proxy sends to the device (the device-facing subset).
class DeviceFrames {
  const DeviceFrames._();

  static Uint8List deviceQuery({int appVersion = appProtocolVersion}) =>
      Uint8List.fromList([cmdDeviceQuery, appVersion]);

  /// `APP_START`: seven reserved bytes, then the app name.
  ///
  /// The protocol version is supplied by `DEVICE_QUERY`; stock firmware ignores
  /// these reserved bytes.
  static Uint8List appStart({String appName = 'MeshCoreProxy'}) {
    final nameBytes = BufferWriter()..writeString(appName);
    return Uint8List.fromList([
      cmdAppStart,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      ...nameBytes.toBytes(),
      0,
    ]);
  }

  static Uint8List getBattAndStorage() =>
      Uint8List.fromList([cmdGetBattAndStorage]);

  static Uint8List getStats(int statsType) =>
      Uint8List.fromList([cmdGetStats, statsType]);

  static Uint8List sendRawPacket(Uint8List packet, [int priority = 0]) =>
      Uint8List.fromList([cmdSendRawPacket, priority, ...packet]);

  /// `CMD_SEND_BINARY_REQ`: `[pub_key(32)][req_data...]`.
  ///
  /// The companion prepends its own tag and encrypts the result as a REQ
  /// datagram to [pubKey].
  static Uint8List binaryRequest(Uint8List pubKey, List<int> reqData) =>
      Uint8List.fromList([cmdSendBinaryReq, ...pubKey, ...reqData]);

  /// `CMD_ADD_UPDATE_CONTACT` around a `Contact` record body with the path
  /// swapped in.
  static Uint8List addUpdateContact(Uint8List recordBody) =>
      Uint8List.fromList([cmdAddUpdateContact, ...recordBody]);

  static Uint8List setRadioParams(
    RadioParams params, {
    bool? clientRepeat,
  }) {
    final w = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      // Firmware expects frequency in kHz and bandwidth in Hz.
      ..writeUInt32Le(params.frequencyHz ~/ 1000)
      ..writeUInt32Le(params.bandwidthHz)
      ..writeByte(params.spreadingFactor)
      ..writeByte(params.codingRate);
    if (clientRepeat != null) w.writeByte(clientRepeat ? 1 : 0);
    return w.toBytes();
  }

  static Uint8List setTxPower(int dbm) =>
      Uint8List.fromList([cmdSetRadioTxPower, dbm & 0xFF]);

  static Uint8List reboot() =>
      Uint8List.fromList([cmdReboot, ...'reboot'.codeUnits]);

  static Uint8List shutdown() => runCliCommand('poweroff');

  static Uint8List getTuningParams() =>
      Uint8List.fromList([cmdGetTuningParams]);

  static Uint8List setTuningParams(TuningParams params) => (BufferWriter()
        ..writeByte(cmdSetTuningParams)
        ..writeUInt32Le(params.rxDelayBaseMs)
        ..writeUInt32Le(params.airtimeFactorMs))
      .toBytes();

  static Uint8List setPathHashMode(int mode) =>
      Uint8List.fromList([cmdSetPathHashMode, 0, mode & 0xFF]);

  static Uint8List runCliCommand(String command) => Uint8List.fromList([
        cmdRunCliCommand,
        ...(BufferWriter()..writeString(command)).toBytes(),
      ]);

  static Uint8List getAllowedRepeatFreq() =>
      Uint8List.fromList([cmdGetAllowedRepeatFreq]);
}

/// Parsed `RESP_CODE_SELF_INFO` radio parameters and node name.
class ParsedSelfInfo {
  const ParsedSelfInfo({
    required this.publicKey,
    required this.radioParams,
    required this.nodeName,
    required this.txPowerDbm,
    required this.maxTxPower,
    required this.latitude,
    required this.longitude,
    required this.advType,
  });

  final Uint8List publicKey;
  final RadioParams radioParams;
  final String nodeName;
  final int txPowerDbm;
  final int maxTxPower;
  final double latitude;
  final double longitude;
  final int advType;

  static ParsedSelfInfo? parse(Uint8List frame) {
    if (frame.isEmpty || frame[0] != respCodeSelfInfo) return null;
    try {
      final r = BufferReader(frame);
      r.skipBytes(2);
      final tx = r.readInt8();
      final maxTx = r.readInt8();
      final pubkey = r.readBytes(pubKeySize);
      final lat = r.readInt32Le() / 1e6;
      final lon = r.readInt32Le() / 1e6;
      r.skipBytes(3); // multi_acks, advert_loc_policy, telemetry
      r.skipBytes(1); // manual_add_contacts
      final freq = r.readUInt32Le();
      final bw = r.readUInt32Le();
      final sf = r.readByte();
      final cr = r.readByte();
      final name = r.readCString();
      return ParsedSelfInfo(
        publicKey: pubkey,
        radioParams: RadioParams(
          // SELF_INFO reports frequency in kHz; normalise to Hz.
          frequencyHz: freq * 1000,
          bandwidthHz: bw,
          spreadingFactor: sf,
          codingRate: cr,
          txPowerDbm: tx,
        ),
        nodeName: name,
        txPowerDbm: tx,
        maxTxPower: maxTx,
        latitude: lat,
        longitude: lon,
        advType: frame.length > 1 ? frame[1] : advTypeChat,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A raw frame received from the device's `PUSH_CODE_LOG_RX_DATA`.
class RawRxFrame {
  const RawRxFrame({required this.snr, required this.rssi, required this.raw});

  final double snr;
  final int rssi;
  final Uint8List raw;

  /// Parse `[0x88][snr*4][rssi][raw...]`.
  static RawRxFrame? parse(Uint8List frame) {
    if (frame.length < 4 || frame[0] != pushCodeLogRxData) return null;
    final reader = BufferReader(frame)..skipBytes(1);
    return RawRxFrame(
      snr: reader.readInt8() / 4.0,
      rssi: reader.readInt8(),
      raw: reader.readRemainingBytes(),
    );
  }
}
