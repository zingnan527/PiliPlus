import 'package:PiliPlus/services/playback_acceleration/byte_range.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ByteRange', () {
    test('parses one closed byte range', () {
      expect(ByteRange.parseHeader('bytes=10-29'), const ByteRange(10, 29));
    });

    test('rejects suffix, open, reversed, and multiple ranges', () {
      for (final value in [
        'bytes=-10',
        'bytes=10-',
        'bytes=10-9',
        'bytes=0-1,4-5',
        'items=0-1',
      ]) {
        expect(() => ByteRange.parseHeader(value), throwsFormatException);
      }
    });

    test('splits without gaps or overlaps and respects minimum size', () {
      final pieces = splitByteRange(
        const ByteRange(100, 1123),
        maxPieces: 8,
        minPieceSize: 256,
      );

      expect(pieces, hasLength(4));
      expect(pieces.first, const ByteRange(100, 355));
      expect(pieces.last, const ByteRange(868, 1123));
      for (var index = 1; index < pieces.length; index += 1) {
        expect(pieces[index].start, pieces[index - 1].end + 1);
      }
      expect(
        pieces.fold<int>(0, (sum, piece) => sum + piece.length),
        1024,
      );
    });
  });

  group('ContentByteRange', () {
    test('parses a complete Content-Range', () {
      expect(
        ContentByteRange.parse('bytes 10-29/100'),
        const ContentByteRange(10, 29, 100),
      );
    });

    test('rejects missing or impossible totals', () {
      for (final value in [
        'bytes 10-29/*',
        'bytes 10-29/29',
        'bytes 30-29/100',
        'items 10-29/100',
      ]) {
        expect(() => ContentByteRange.parse(value), throwsFormatException);
      }
    });
  });
}
