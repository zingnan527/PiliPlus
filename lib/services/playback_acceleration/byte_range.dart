import 'dart:math' as math;

final class ByteRange {
  final int start;
  final int end;

  const ByteRange(this.start, this.end)
    : assert(start >= 0),
      assert(end >= start);

  int get length => end - start + 1;

  static ByteRange parseHeader(String value) {
    final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(value.trim());
    if (match == null) {
      throw FormatException('Expected one closed byte range');
    }
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    if (end < start) throw FormatException('Range end precedes start');
    return ByteRange(start, end);
  }

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'bytes=$start-$end';
}

final class ContentByteRange {
  final int start;
  final int end;
  final int total;

  const ContentByteRange(this.start, this.end, this.total)
    : assert(start >= 0),
      assert(end >= start),
      assert(total > end);

  static ContentByteRange parse(String value) {
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
    ).firstMatch(value.trim());
    if (match == null) throw FormatException('Invalid Content-Range');
    final start = int.parse(match.group(1)!);
    final end = int.parse(match.group(2)!);
    final total = int.parse(match.group(3)!);
    if (end < start || total <= end) {
      throw FormatException('Impossible Content-Range');
    }
    return ContentByteRange(start, end, total);
  }

  ByteRange get range => ByteRange(start, end);

  @override
  bool operator ==(Object other) =>
      other is ContentByteRange &&
      other.start == start &&
      other.end == end &&
      other.total == total;

  @override
  int get hashCode => Object.hash(start, end, total);
}

List<ByteRange> splitByteRange(
  ByteRange range, {
  required int maxPieces,
  required int minPieceSize,
}) {
  if (maxPieces <= 0) {
    throw ArgumentError.value(maxPieces, 'maxPieces', 'must be positive');
  }
  if (minPieceSize <= 0) {
    throw ArgumentError.value(
      minPieceSize,
      'minPieceSize',
      'must be positive',
    );
  }
  final count = math.min(
    maxPieces,
    (range.length / minPieceSize).ceil(),
  );
  final baseSize = range.length ~/ count;
  final remainder = range.length % count;
  final result = <ByteRange>[];
  var cursor = range.start;
  for (var index = 0; index < count; index += 1) {
    final length = baseSize + (index < remainder ? 1 : 0);
    result.add(ByteRange(cursor, cursor + length - 1));
    cursor += length;
  }
  return List.unmodifiable(result);
}
