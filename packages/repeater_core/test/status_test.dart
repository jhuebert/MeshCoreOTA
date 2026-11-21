import 'dart:typed_data';

import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

void main() {
  test('parses the firmware RepeaterStats struct field by field', () {
    final b = ByteData(RepeaterStatus.reportLength);
    var o = 0;
    void u16(int v) {
      b.setUint16(o, v, Endian.little);
      o += 2;
    }

    void i16(int v) {
      b.setInt16(o, v, Endian.little);
      o += 2;
    }

    void u32(int v) {
      b.setUint32(o, v, Endian.little);
      o += 4;
    }

    u16(4123); // battery mV
    u16(2); // tx queue
    i16(-118); // noise floor
    i16(-72); // rssi
    u32(1000); // recv
    u32(900); // sent
    u32(500); // tx air secs
    u32(86400); // uptime
    u32(10);
    u32(20);
    u32(30);
    u32(40);
    u16(3); // error events
    i16(28); // snr x4 => 7.0
    u16(5);
    u16(6);
    u32(700); // rx air secs
    u32(9); // recv errors

    final at = DateTime.utc(2026, 11, 20);
    final s = parseStatusReport(b.buffer.asUint8List(), fetchedAt: at)!;
    expect(s.batteryMilliVolts, 4123);
    expect(s.txQueueLength, 2);
    expect(s.noiseFloor, -118);
    expect(s.lastRssi, -72);
    expect(s.packetsReceived, 1000);
    expect(s.packetsSent, 900);
    expect(s.totalAirTimeSecs, 500);
    expect(s.uptimeSecs, 86400);
    expect(s.sentFlood, 10);
    expect(s.sentDirect, 20);
    expect(s.recvFlood, 30);
    expect(s.recvDirect, 40);
    expect(s.errorEvents, 3);
    expect(s.lastSnr, 7.0);
    expect(s.directDuplicates, 5);
    expect(s.floodDuplicates, 6);
    expect(s.rxAirTimeSecs, 700);
    expect(s.recvErrors, 9);
    expect(s.fetchedAt, at);
  });

  test('short reports are rejected', () {
    expect(parseStatusReport(Uint8List(55)), isNull);
  });

  test('json roundtrip keeps the timestamp and counters', () {
    final s = RepeaterStatus(
      batteryMilliVolts: 4000,
      txQueueLength: 0,
      noiseFloor: -120,
      lastRssi: -80,
      packetsReceived: 1,
      packetsSent: 2,
      totalAirTimeSecs: 3,
      uptimeSecs: 4,
      sentFlood: 5,
      sentDirect: 6,
      recvFlood: 7,
      recvDirect: 8,
      errorEvents: 9,
      lastSnr: 1.25,
      directDuplicates: 10,
      floodDuplicates: 11,
      rxAirTimeSecs: 12,
      recvErrors: 13,
      fetchedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    );
    final decoded = RepeaterStatus.fromJson(s.toJson());
    expect(decoded.batteryMilliVolts, 4000);
    expect(decoded.lastSnr, 1.25);
    expect(decoded.recvErrors, 13);
    expect(decoded.fetchedAt, s.fetchedAt);
  });
}
