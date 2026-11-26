import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Metadata read from a GGUF file header, plus the exact parameter count
/// (sum of all tensor element counts).
class GgufInfo {
  final String path;
  final int fileSizeBytes;
  final String? architecture;
  final String? name;
  final String? sizeLabel;
  final String? quantization;
  final int? contextLength;
  final int? blockCount;
  final int parameterCount;
  final int tensorCount;

  const GgufInfo({
    required this.path,
    required this.fileSizeBytes,
    required this.architecture,
    required this.name,
    required this.sizeLabel,
    required this.quantization,
    required this.contextLength,
    required this.blockCount,
    required this.parameterCount,
    required this.tensorCount,
  });

  double get paramsBillions => parameterCount / 1e9;
  double get fileSizeGb => fileSizeBytes / (1024 * 1024 * 1024);
  double get bitsPerWeight =>
      parameterCount == 0 ? 0 : fileSizeBytes * 8 / parameterCount;

  Map<String, dynamic> toJson() => {
    'path': path,
    'file_size_bytes': fileSizeBytes,
    'architecture': architecture,
    'name': name,
    'size_label': sizeLabel,
    'quantization': quantization,
    'context_length': contextLength,
    'block_count': blockCount,
    'parameter_count': parameterCount,
    'params_billions': double.parse(paramsBillions.toStringAsFixed(3)),
    'bits_per_weight': double.parse(bitsPerWeight.toStringAsFixed(2)),
    'tensor_count': tensorCount,
  };
}

const _fileTypes = <int, String>{
  0: 'F32', 1: 'F16', 2: 'Q4_0', 3: 'Q4_1', 7: 'Q8_0', 8: 'Q5_0', 9: 'Q5_1',
  10: 'Q2_K', 11: 'Q3_K_S', 12: 'Q3_K_M', 13: 'Q3_K_L', 14: 'Q4_K_S',
  15: 'Q4_K_M', 16: 'Q5_K_S', 17: 'Q5_K_M', 18: 'Q6_K', 19: 'IQ2_XXS',
  20: 'IQ2_XS', 21: 'Q2_K_S', 22: 'IQ3_XS', 23: 'IQ3_XXS', 24: 'IQ1_S',
  25: 'IQ4_NL', 26: 'IQ3_S', 27: 'IQ3_M', 28: 'IQ2_S', 29: 'IQ2_M',
  30: 'IQ4_XS', 31: 'IQ1_M', 32: 'BF16', 36: 'TQ1_0', 37: 'TQ2_0', 38: 'MXFP4',
};

/// Buffered little-endian reader over a [RandomAccessFile].
class _Reader {
  final RandomAccessFile _raf;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;
  static const _chunk = 1 << 20;

  _Reader(this._raf);

  void _ensure(int n) {
    if (_pos + n <= _buf.length) return;
    final remaining = _buf.sublist(_pos);
    final more = _raf.readSync(n > _chunk ? n : _chunk);
    final merged = Uint8List(remaining.length + more.length)
      ..setAll(0, remaining)
      ..setAll(remaining.length, more);
    _buf = merged;
    _pos = 0;
    if (_buf.length < n) throw const FormatException('Unexpected end of GGUF');
  }

  ByteData _view(int n) {
    _ensure(n);
    final v = ByteData.sublistView(_buf, _pos, _pos + n);
    _pos += n;
    return v;
  }

  int u8() => _view(1).getUint8(0);
  int u16() => _view(2).getUint16(0, Endian.little);
  int u32() => _view(4).getUint32(0, Endian.little);
  int i32() => _view(4).getInt32(0, Endian.little);
  int u64() => _view(8).getUint64(0, Endian.little);
  double f32() => _view(4).getFloat32(0, Endian.little);
  double f64() => _view(8).getFloat64(0, Endian.little);

  void skip(int n) {
    while (n > 0) {
      final step = n > _chunk ? _chunk : n;
      _ensure(step);
      _pos += step;
      n -= step;
    }
  }

  String str() {
    final len = u64();
    _ensure(len);
    final s = utf8.decode(_buf.sublist(_pos, _pos + len), allowMalformed: true);
    _pos += len;
    return s;
  }

  void skipStr() => skip(u64());
}

const _scalarSizes = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8};

Object? _readValue(_Reader r, int type, {bool keep = true}) {
  switch (type) {
    case 0: return r.u8();
    case 1: return r.u8();
    case 2: return r.u16();
    case 3: return r.u16();
    case 4: return r.u32();
    case 5: return r.i32();
    case 6: return r.f32();
    case 7: return r.u8() != 0;
    case 8:
      if (keep) return r.str();
      r.skipStr();
      return null;
    case 9:
      final itemType = r.u32();
      final n = r.u64();
      if (_scalarSizes[itemType] case final size?) {
        r.skip(size * n);
      } else {
        for (var i = 0; i < n; i++) {
          _readValue(r, itemType, keep: false);
        }
      }
      return null; // arrays (tokenizer vocab etc.) are skipped
    case 10: return r.u64();
    case 11: return r.u64();
    case 12: return r.f64();
    default: throw FormatException('Unknown GGUF value type $type');
  }
}

/// Reads GGUF metadata and computes the total parameter count.
Future<GgufInfo> readGguf(String path) async {
  final file = File(path);
  final size = await file.length();
  final raf = await file.open();
  try {
    final r = _Reader(raf);
    final magic = r.u32();
    if (magic != 0x46554747) throw FormatException('Not a GGUF file: $path');
    final version = r.u32();
    if (version < 2) throw FormatException('Unsupported GGUF version $version');
    final nTensors = r.u64();
    final nKv = r.u64();

    final kv = <String, Object?>{};
    for (var i = 0; i < nKv; i++) {
      final key = r.str();
      final type = r.u32();
      kv[key] = _readValue(r, type);
    }

    var params = 0;
    for (var i = 0; i < nTensors; i++) {
      r.skipStr(); // name
      final nDims = r.u32();
      var count = 1;
      for (var d = 0; d < nDims; d++) {
        count *= r.u64();
      }
      r.u32(); // ggml type
      r.u64(); // offset
      params += count;
    }

    final arch = kv['general.architecture'] as String?;
    final ft = kv['general.file_type'];
    return GgufInfo(
      path: path,
      fileSizeBytes: size,
      architecture: arch,
      name: kv['general.name'] as String?,
      sizeLabel: kv['general.size_label'] as String?,
      quantization: ft is int ? (_fileTypes[ft] ?? 'type_$ft') : _quantFromName(path),
      contextLength: kv['$arch.context_length'] as int?,
      blockCount: kv['$arch.block_count'] as int?,
      parameterCount: params,
      tensorCount: nTensors,
    );
  } finally {
    await raf.close();
  }
}

String? _quantFromName(String path) {
  final m = RegExp(r'(I?Q\d_[A-Z0-9_]+|Q\d_\d|F16|BF16|F32)', caseSensitive: false)
      .firstMatch(path.split('/').last);
  return m?.group(0)?.toUpperCase();
}
