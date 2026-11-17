import 'dart:io';
import 'dart:typed_data';

import 'package:ota_core/ota_core.dart';

void main(List<String> args) {
  final base = Uint8List.fromList(File(args[0]).readAsBytesSync());
  final target = Uint8List.fromList(File(args[1]).readAsBytesSync());
  final d = computeDelta(base, target);
  final frames = wireOpsFor(d.ops, literalChunk: otaLiteralChunkForBinaryReq(frameLimit: otaStockCompanionFrameLimit));
  final literalOps = d.ops.whereType<LiteralOp>().length;
  final copyOps = d.ops.whereType<CopyOp>().length;
  final litBytes = d.ops.fold<int>(0, (sum, op) => sum + (op is LiteralOp ? op.data.length : 0));
  final uniqueLit = d.ops.fold<int>(0, (sum, op) => sum + (op is LiteralOp ? op.data.length : 0));
  print('delta ops=${d.ops.length} literalOps=$literalOps copyOps=$copyOps '
      'literalBytes=$litBytes copyBytes=${d.copyBytes}');
  print('wire frames=${frames.frames.length}');
  var litFrames = 0;
  var maxLitLen = 0;
  for (final f in frames.frames) {
    if (f.length >= 5 && f[2] == otaOpLiteral) {
      litFrames++;
      final len = f[5] | (f[6] << 8);
      if (len > maxLitLen) maxLitLen = len;
    }
  }
  print('literal frames=$litFrames maxLiteralLen=$maxLitLen');
  print('copy ${d.copyBytes}B; fraction shown when opsApplied=28 => ${28 / (frames.frames.length - 1)}');
}
