import 'dart:typed_data';

/// The op a delta emits. `copy` references the base (running-slot) image;
/// `literal` carries target bytes verbatim.
sealed class DeltaOp {
  const DeltaOp();
}

/// Copy [length] bytes from base offset [baseOffset] into the output.
class CopyOp extends DeltaOp {
  const CopyOp(this.baseOffset, this.length);

  final int baseOffset;
  final int length;

  @override
  String toString() => 'COPY base=$baseOffset len=$length';
}

/// Write [data] verbatim into the output.
class LiteralOp extends DeltaOp {
  const LiteralOp(this.data);

  final Uint8List data;

  @override
  String toString() => 'LITERAL len=${data.length}';
}

/// A run of new bytes compressed with raw DEFLATE. The node inflates it into
/// the staged slot, so the wire carries fewer literal bytes and fewer ops.
class CompressedLiteralOp extends DeltaOp {
  const CompressedLiteralOp(this.compressed, this.originalLength);

  /// Raw DEFLATE payload (no gzip header or trailer).
  final Uint8List compressed;
  final int originalLength;

  @override
  String toString() => 'COMPRESSED len=$originalLength -> ${compressed.length}';
}

/// Result of [computeDelta]: the op stream in emission order (which is also
/// application order) plus sizes for display.
class DeltaResult {
  const DeltaResult({
    required this.ops,
    required this.literalBytes,
    required this.copyBytes,
  });

  final List<DeltaOp> ops;
  final int literalBytes;
  final int copyBytes;

  int get opCount => ops.length;
}

/// Block size for the rolling hash matcher. Matches are extended block by
/// block, so values larger than ~128 waste matches on short unchanged runs.
const deltaBlockSize = 64;

/// Polynomial rolling hash constant (FNV-64 prime). The hash need not be
/// collision-free — every candidate match is verified byte-for-byte.
const int _rollingPrime = 0x00000100000001B3;

/// Compute a delta that turns [base] into [target].
///
/// Classic rsync-style: index every position of [base] with a rolling hash,
/// then scan [target] once. Identical regions of any alignment are found
/// regardless of phase, and are emitted as COPYs (the "compression" for an
/// adjacent-build firmware). Deterministic; never wrong — a bug here is caught
/// at OP_END by the device's SHA-256 gate.
DeltaResult computeDelta(Uint8List base, Uint8List target) {
  const block = deltaBlockSize;
  final ops = <DeltaOp>[];
  int literalBytes = 0;
  int copyBytes = 0;

  void emitLiteral(int start, int end) {
    var cursor = start;
    while (cursor < end) {
      final length = (end - cursor).clamp(1, 0xFFFF);
      ops.add(
          LiteralOp(Uint8List.sublistView(target, cursor, cursor + length)));
      literalBytes += length;
      cursor += length;
    }
  }

  void emitCopy(int baseOffset, int length) {
    var cursorBase = baseOffset;
    var remaining = length;
    while (remaining > 0) {
      final take = remaining < 0xFFFF ? remaining : 0xFFFF;
      ops.add(CopyOp(cursorBase, take));
      copyBytes += take;
      cursorBase += take;
      remaining -= take;
    }
  }

  if (target.length < block || base.length < block) {
    emitLiteral(0, target.length);
    return DeltaResult(
        ops: ops, literalBytes: literalBytes, copyBytes: copyBytes);
  }

  final nB = base.length - block + 1;
  final hashes = Uint64List(nB);
  final offsets = Uint32List(nB);

  // Precompute prime^(block-1) mod 2^64 with wrapping int64 arithmetic. The
  // order of hash values is irrelevant (sort is a total order on signed
  // ints), so no masking is applied anywhere.
  int primePow = 1;
  for (int i = 0; i < block - 1; i++) {
    primePow *= _rollingPrime;
  }

  int hash = 0;
  for (int i = 0; i < block; i++) {
    hash = hash * _rollingPrime + base[i];
  }
  for (int i = 0; i <= nB - 1; i++) {
    hashes[i] = hash;
    offsets[i] = i;
    if (i < nB - 1) {
      final outByte = base[i];
      final inByte = base[i + block];
      hash = (hash - outByte * primePow) * _rollingPrime + inByte;
    }
  }
  _sortPairs(hashes, offsets);

  final nT = target.length;
  int targetHash = 0;
  for (int i = 0; i < block; i++) {
    targetHash = targetHash * _rollingPrime + target[i];
  }

  var literalStart = 0;
  var i = 0;
  final lastScan = nT - block;
  while (i <= lastScan) {
    final matchBase =
        _findMatch(hashes, offsets, targetHash, base, target, i, block);
    if (matchBase == null) {
      // Advance one byte, rolling the hash forward.
      if (i < lastScan) {
        final outByte = target[i];
        final inByte = target[i + block];
        targetHash = (targetHash - outByte * primePow) * _rollingPrime + inByte;
      }
      i += 1;
      continue;
    }
    if (i > literalStart) emitLiteral(literalStart, i);
    // Extend the match block by block.
    var length = block;
    while (i + length + block <= nT &&
        _bytesEqual(base, matchBase + length, target, i + length, block)) {
      length += block;
    }
    emitCopy(matchBase, length);
    final newI = i + length;
    literalStart = newI;
    i = newI;
    if (i <= lastScan) {
      targetHash = 0;
      for (int k = 0; k < block && i + k < nT; k++) {
        targetHash = targetHash * _rollingPrime + target[i + k];
      }
    }
  }
  if (literalStart < nT) emitLiteral(literalStart, nT);

  return DeltaResult(
      ops: ops, literalBytes: literalBytes, copyBytes: copyBytes);
}

/// Apply [ops] to [base] and return the reassembled image. Used by tests and
/// by the planner to double-check an op stream before it goes on air.
Uint8List applyDelta(Uint8List base, List<DeltaOp> ops,
    {required int expectedLength}) {
  final out = BytesBuilder(copy: false);
  for (final op in ops) {
    switch (op) {
      case CopyOp(:final baseOffset, :final length):
        out.add(Uint8List.sublistView(base, baseOffset, baseOffset + length));
      case LiteralOp(:final data):
        out.add(data);
      case CompressedLiteralOp():
        throw UnsupportedError(
            'applyDelta cannot inflate compressed literals; use the node');
    }
  }
  final bytes = out.toBytes();
  if (bytes.length != expectedLength) {
    throw StateError(
        'delta produced ${bytes.length} bytes, expected $expectedLength');
  }
  return bytes;
}

bool _bytesEqual(
    Uint8List base, int baseOff, Uint8List target, int targetOff, int length) {
  if (baseOff < 0 || baseOff + length > base.length) return false;
  if (targetOff < 0 || targetOff + length > target.length) return false;
  for (int i = 0; i < length; i++) {
    if (base[baseOff + i] != target[targetOff + i]) return false;
  }
  return true;
}

/// Binary-search the sorted index for the first base offset whose block
/// matches `target[targetOff..targetOff+block]`, or null. Hash collisions are
/// filtered by the byte comparison.
int? _findMatch(
  Uint64List hashes,
  Uint32List offsets,
  int hash,
  Uint8List base,
  Uint8List target,
  int targetOff,
  int block,
) {
  int lo = 0, hi = hashes.length - 1, lower = hashes.length;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (hashes[mid] >= hash) {
      lower = mid;
      hi = mid - 1;
    } else {
      lo = mid + 1;
    }
  }
  for (int j = lower; j < hashes.length && hashes[j] == hash; j++) {
    final off = offsets[j];
    if (_bytesEqual(base, off, target, targetOff, block)) return off;
  }
  return null;
}

void _sortPairs(Uint64List hashes, Uint32List offsets) {
  final n = hashes.length;
  if (n < 2) return;
  final stack = List<int>.filled(2 * 64, 0);
  var sp = 0;
  stack[sp++] = 0;
  stack[sp++] = n - 1;
  while (sp > 0) {
    final hi = stack[--sp];
    final lo = stack[--sp];
    if (lo >= hi) continue;
    final pivot = hashes[(lo + hi) >> 1];
    var i = lo, j = hi;
    while (i <= j) {
      while (hashes[i] < pivot) {
        i++;
      }
      while (hashes[j] > pivot) {
        j--;
      }
      if (i <= j) {
        final tempHash = hashes[i];
        hashes[i] = hashes[j];
        hashes[j] = tempHash;
        final tempOff = offsets[i];
        offsets[i] = offsets[j];
        offsets[j] = tempOff;
        i++;
        j--;
      }
    }
    if (lo < j && j - lo < hi - i) {
      stack[sp++] = i;
      stack[sp++] = hi;
      stack[sp++] = lo;
      stack[sp++] = j;
    } else {
      stack[sp++] = lo;
      stack[sp++] = j;
      stack[sp++] = i;
      stack[sp++] = hi;
    }
  }
}
