import 'dart:typed_data';

/// The 56-byte `REQ_TYPE_GET_STATUS` report from `RepeaterStats` in the
/// repeater firmware. All counters are since boot.
class RepeaterStatus {
  const RepeaterStatus({
    required this.batteryMilliVolts,
    required this.txQueueLength,
    required this.noiseFloor,
    required this.lastRssi,
    required this.packetsReceived,
    required this.packetsSent,
    required this.totalAirTimeSecs,
    required this.uptimeSecs,
    required this.sentFlood,
    required this.sentDirect,
    required this.recvFlood,
    required this.recvDirect,
    required this.errorEvents,
    required this.lastSnr,
    required this.directDuplicates,
    required this.floodDuplicates,
    required this.rxAirTimeSecs,
    required this.recvErrors,
    required this.fetchedAt,
  });

  /// Size of the firmware struct, excluding the companion's tag and padding.
  static const int reportLength = 56;

  final int batteryMilliVolts;
  final int txQueueLength;
  final int noiseFloor;
  final int lastRssi;
  final int packetsReceived;
  final int packetsSent;
  final int totalAirTimeSecs;
  final int uptimeSecs;
  final int sentFlood;
  final int sentDirect;
  final int recvFlood;
  final int recvDirect;
  final int errorEvents;
  final double lastSnr;
  final int directDuplicates;
  final int floodDuplicates;
  final int rxAirTimeSecs;
  final int recvErrors;
  final DateTime fetchedAt;

  Map<String, Object?> toJson() => {
        'schema': 1,
        'batteryMv': batteryMilliVolts,
        'txQueue': txQueueLength,
        'noiseFloor': noiseFloor,
        'lastRssi': lastRssi,
        'packetsReceived': packetsReceived,
        'packetsSent': packetsSent,
        'totalAirTimeSecs': totalAirTimeSecs,
        'uptimeSecs': uptimeSecs,
        'sentFlood': sentFlood,
        'sentDirect': sentDirect,
        'recvFlood': recvFlood,
        'recvDirect': recvDirect,
        'errorEvents': errorEvents,
        'lastSnr': lastSnr,
        'directDuplicates': directDuplicates,
        'floodDuplicates': floodDuplicates,
        'rxAirTimeSecs': rxAirTimeSecs,
        'recvErrors': recvErrors,
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  factory RepeaterStatus.fromJson(Map<String, dynamic> json) => RepeaterStatus(
        batteryMilliVolts: json['batteryMv'] as int,
        txQueueLength: json['txQueue'] as int,
        noiseFloor: json['noiseFloor'] as int,
        lastRssi: json['lastRssi'] as int,
        packetsReceived: json['packetsReceived'] as int,
        packetsSent: json['packetsSent'] as int,
        totalAirTimeSecs: json['totalAirTimeSecs'] as int,
        uptimeSecs: json['uptimeSecs'] as int,
        sentFlood: json['sentFlood'] as int,
        sentDirect: json['sentDirect'] as int,
        recvFlood: json['recvFlood'] as int,
        recvDirect: json['recvDirect'] as int,
        errorEvents: json['errorEvents'] as int,
        lastSnr: (json['lastSnr'] as num).toDouble(),
        directDuplicates: json['directDuplicates'] as int,
        floodDuplicates: json['floodDuplicates'] as int,
        rxAirTimeSecs: json['rxAirTimeSecs'] as int,
        recvErrors: json['recvErrors'] as int,
        fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      );
}

/// Parse the fixed little-endian `RepeaterStats` struct. Returns null for a
/// short or malformed report; trailing zero padding from the crypto layer is
/// ignored by the caller slicing [RepeaterStatus.reportLength] bytes.
RepeaterStatus? parseStatusReport(List<int> bytes, {DateTime? fetchedAt}) {
  if (bytes.length < RepeaterStatus.reportLength) return null;
  final r = ByteData.sublistView(
      Uint8List.fromList(bytes), 0, RepeaterStatus.reportLength);
  var o = 0;
  int u16() {
    final v = r.getUint16(o, Endian.little);
    o += 2;
    return v;
  }

  int i16() {
    final v = r.getInt16(o, Endian.little);
    o += 2;
    return v;
  }

  int u32() {
    final v = r.getUint32(o, Endian.little);
    o += 4;
    return v;
  }

  final battery = u16();
  final queue = u16();
  final noise = i16();
  final rssi = i16();
  final recv = u32();
  final sent = u32();
  final air = u32();
  final uptime = u32();
  final sentFlood = u32();
  final sentDirect = u32();
  final recvFlood = u32();
  final recvDirect = u32();
  final errors = u16();
  final snr = i16();
  final directDups = u16();
  final floodDups = u16();
  final rxAir = u32();
  final recvErrors = u32();

  return RepeaterStatus(
    batteryMilliVolts: battery,
    txQueueLength: queue,
    noiseFloor: noise,
    lastRssi: rssi,
    packetsReceived: recv,
    packetsSent: sent,
    totalAirTimeSecs: air,
    uptimeSecs: uptime,
    sentFlood: sentFlood,
    sentDirect: sentDirect,
    recvFlood: recvFlood,
    recvDirect: recvDirect,
    errorEvents: errors,
    lastSnr: snr / 4,
    directDuplicates: directDups,
    floodDuplicates: floodDups,
    rxAirTimeSecs: rxAir,
    recvErrors: recvErrors,
    fetchedAt: fetchedAt ?? DateTime.now(),
  );
}
