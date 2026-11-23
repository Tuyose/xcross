import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/src/shared/appstoreconnect/asc_jwt.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// A single binary upload operation returned by App Store Connect.
@immutable
final class AscUploadOperation {
  const AscUploadOperation({
    required this.url,
    required this.method,
    required this.headers,
    this.offset = 0,
    this.length,
  });

  factory AscUploadOperation.fromJson(Map<String, dynamic> json) {
    final rawHeaders = json['requestHeaders'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers['${entry.key}'] = '${entry.value}';
      }
    } else if (rawHeaders is List) {
      for (final entry in rawHeaders) {
        if (entry is Map && entry['name'] != null && entry['value'] != null) {
          headers['${entry['name']}'] = '${entry['value']}';
        }
      }
    }
    return AscUploadOperation(
      url: Uri.parse(json['url'] as String),
      method: (json['method'] as String?) ?? 'PUT',
      headers: headers,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
      length: (json['length'] as num?)?.toInt(),
    );
  }

  final Uri url;
  final String method;
  final Map<String, String> headers;
  final int offset;
  final int? length;
}

/// The result of committing an IPA to a Build Upload reservation.
@immutable
final class AscBuildUploadResult {
  const AscBuildUploadResult({
    required this.buildUploadId,
    required this.fileId,
    required this.operationCount,
    required this.md5,
  });

  final String buildUploadId;
  final String fileId;
  final int operationCount;
  final String md5;
}

/// Build Upload API client shared by Windows and Linux distribution flows.
///
/// The client deliberately owns only the API/upload part. IPA signing and
/// project-specific build preparation stay in xcross, so an already signed
/// IPA can be uploaded without rebuilding or resigning it.
final class AscBuildUploadClient {
  AscBuildUploadClient(
    this.credentials, {
    required http.Client httpClient,
    this.maxConcurrentOperations = 4,
    this.maxAttempts = 3,
  }) : _http = httpClient {
    if (maxConcurrentOperations < 1) {
      throw ArgumentError.value(
        maxConcurrentOperations,
        'maxConcurrentOperations',
        'must be at least 1',
      );
    }
    if (maxAttempts < 1) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        'must be at least 1',
      );
    }
  }

  final AscCredentials credentials;
  final http.Client _http;
  final int maxConcurrentOperations;
  final int maxAttempts;

  /// Resolves an App Store Connect app id from an exact bundle id.
  Future<String> resolveAppId(String bundleId) async {
    final response = await _get(
      '/apps?filter[bundleId]=${Uri.encodeQueryComponent(bundleId)}&limit=200',
    );
    final matches = [
      for (final item in _list(response['data']))
        if (item['attributes'] is Map &&
            (item['attributes'] as Map)['bundleId'] == bundleId)
          item,
    ];
    if (matches.length != 1) {
      throw AppleApiError(
        0,
        'Expected exactly one App Store Connect app for bundle id '
        '"$bundleId", found ${matches.length}.',
      );
    }
    return matches.single['id'] as String;
  }

  /// Uploads and commits [ipa] to an App Store Connect Build Upload.
  ///
  /// Upload operations are streamed directly from disk. This avoids the
  /// previous PowerShell implementation's whole-operation byte allocation and
  /// keeps memory stable for large IPAs. Independent operations are bounded by
  /// [maxConcurrentOperations].
  Future<AscBuildUploadResult> uploadIpa({
    required File ipa,
    required String appId,
    required String shortVersion,
    required String buildVersion,
  }) async {
    if (!ipa.existsSync()) {
      throw ArgumentError('IPA does not exist: ${ipa.path}');
    }
    final fileSize = await ipa.length();
    if (fileSize <= 0) throw ArgumentError('IPA is empty: ${ipa.path}');

    final buildUploadId = await _findOrCreateBuildUpload(
      appId: appId,
      shortVersion: shortVersion,
      buildVersion: buildVersion,
    );
    final reservation = await _post(
      '/buildUploadFiles',
      _buildUploadFilePayload(
        buildUploadId: buildUploadId,
        fileName: ipa.uri.pathSegments.last,
        fileSize: fileSize,
      ),
    );
    final data = _data(reservation);
    final fileId = data['id'] as String;
    final attributes = (data['attributes'] as Map).cast<String, dynamic>();
    final operations = [
      for (final raw in (attributes['uploadOperations'] as List? ?? const []))
        AscUploadOperation.fromJson((raw as Map).cast<String, dynamic>()),
    ];
    if (operations.isEmpty) {
      throw const FormatException(
        'App Store Connect returned no upload operations.',
      );
    }

    await _forEachBounded(operations, (operation) async {
      final length = operation.length ?? fileSize - operation.offset;
      if (operation.offset < 0 ||
          length <= 0 ||
          operation.offset + length > fileSize) {
        throw FormatException(
          'Invalid upload operation range: offset=${operation.offset} '
          'length=$length size=$fileSize',
        );
      }
      await _sendOperation(ipa: ipa, operation: operation, length: length);
    });

    final checksum = await _md5(ipa);
    await _patch('/buildUploadFiles/$fileId', {
      'data': {
        'type': 'buildUploadFiles',
        'id': fileId,
        'attributes': {
          'uploaded': true,
          'sourceFileChecksums': {
            'file': {'hash': checksum, 'algorithm': 'MD5'},
          },
        },
      },
    });
    return AscBuildUploadResult(
      buildUploadId: buildUploadId,
      fileId: fileId,
      operationCount: operations.length,
      md5: checksum,
    );
  }

  /// Reads the current upload/processing states for a reservation.
  Future<AscBuildUploadStatus> status(String buildUploadId) async {
    final response = await _get('/buildUploads/$buildUploadId?include=build');
    final data = _data(response);
    final attributes = (data['attributes'] as Map).cast<String, dynamic>();
    String? uploadState;
    final rawState = attributes['state'];
    if (rawState is String) uploadState = rawState;
    if (rawState is Map) uploadState = rawState['state'] as String?;

    String? processingState;
    for (final item in _list(response['included'])) {
      if (item['type'] != 'builds') continue;
      final itemAttributes = item['attributes'];
      if (itemAttributes is Map) {
        processingState = itemAttributes['processingState'] as String?;
      }
    }
    return AscBuildUploadStatus(
      buildUploadId: buildUploadId,
      uploadState: uploadState,
      processingState: processingState,
    );
  }

  void close() {
    _http.close();
  }

  Future<String> _findOrCreateBuildUpload({
    required String appId,
    required String shortVersion,
    required String buildVersion,
  }) async {
    final existing = await _get(
      '/apps/$appId/buildUploads'
      '?filter%5BcfBundleVersion%5D=${Uri.encodeQueryComponent(buildVersion)}'
      '&filter%5BcfBundleShortVersionString%5D='
      '${Uri.encodeQueryComponent(shortVersion)}&limit=20',
    );
    final awaiting = [
      for (final item in _list(existing['data']))
        if (_stateOf(item['attributes']) == 'AWAITING_UPLOAD') item,
    ];
    if (awaiting.length > 1) {
      throw const FormatException(
        'More than one AWAITING_UPLOAD reservation matches this version.',
      );
    }
    if (awaiting.length == 1) return awaiting.single['id'] as String;

    final created = await _post('/buildUploads', {
      'data': {
        'type': 'buildUploads',
        'attributes': {
          'cfBundleShortVersionString': shortVersion,
          'cfBundleVersion': buildVersion,
          'platform': 'IOS',
        },
        'relationships': {
          'app': {
            'data': {'type': 'apps', 'id': appId},
          },
        },
      },
    });
    return _data(created)['id'] as String;
  }

  Map<String, dynamic> _buildUploadFilePayload({
    required String buildUploadId,
    required String fileName,
    required int fileSize,
  }) => {
    'data': {
      'type': 'buildUploadFiles',
      'attributes': {
        'assetType': 'ASSET',
        'fileName': fileName,
        'fileSize': fileSize,
        'uti': 'com.apple.ipa',
      },
      'relationships': {
        'buildUpload': {
          'data': {'type': 'buildUploads', 'id': buildUploadId},
        },
      },
    },
  };

  Future<void> _sendOperation({
    required File ipa,
    required AscUploadOperation operation,
    required int length,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final request = http.StreamedRequest(operation.method, operation.url);
        for (final entry in operation.headers.entries) {
          if (entry.key.toLowerCase() == 'content-length') continue;
          request.headers[entry.key] = entry.value;
        }
        request.contentLength = length;
        final responseFuture = _http.send(request);
        final stream = ipa.openRead(
          operation.offset,
          operation.offset + length,
        );
        try {
          await request.sink.addStream(stream);
          await request.sink.close();
        } on Object {
          await request.sink.close();
          rethrow;
        }
        final response = await responseFuture;
        final body = await response.stream.bytesToString();
        if (response.statusCode >= 200 && response.statusCode < 300) return;
        throw UploadHttpError(response.statusCode, body);
      } on Object catch (error) {
        lastError = error;
        if (attempt == maxAttempts || !_retryable(error)) rethrow;
        await Future<void>.delayed(
          Duration(milliseconds: 400 * (1 << (attempt - 1))),
        );
      }
    }
    throw StateError('Upload operation failed: $lastError');
  }

  Future<void> _forEachBounded<T>(
    List<T> values,
    Future<void> Function(T value) action,
  ) async {
    var next = 0;
    Future<void> worker() async {
      while (true) {
        if (next >= values.length) return;
        final value = values[next++];
        await action(value);
      }
    }

    final workerCount = values.length < maxConcurrentOperations
        ? values.length
        : maxConcurrentOperations;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
  }

  Future<Map<String, dynamic>> _get(String path) async =>
      _decode(await _http.get(await _uri(path), headers: await _headers()));

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async => _decode(
    await _http.post(
      await _uri(path),
      headers: await _headers(),
      body: jsonEncode(body),
    ),
  );

  Future<Map<String, dynamic>> _patch(
    String path,
    Map<String, dynamic> body,
  ) async => _decode(
    await _http.patch(
      await _uri(path),
      headers: await _headers(),
      body: jsonEncode(body),
    ),
  );

  Future<Uri> _uri(String path) async =>
      Uri.parse('https://api.appstoreconnect.apple.com/v1$path');

  Future<Map<String, String>> _headers() async => {
    'Authorization': 'Bearer ${await AscJwt.generate(credentials)}',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  Map<String, dynamic> _decode(http.Response response) {
    final Object? decoded = response.body.isEmpty
        ? null
        : jsonDecode(response.body);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppleApiError(
        response.statusCode,
        'App Store Connect API error (HTTP ${response.statusCode}): '
        '${_firstErrorDetail(decoded) ?? response.body}',
      );
    }
    if (decoded == null) return const {};
    return (decoded as Map).cast<String, dynamic>();
  }

  static Map<String, dynamic> _data(Map<String, dynamic> json) =>
      (json['data'] as Map).cast<String, dynamic>();

  static List<Map<String, dynamic>> _list(Object? value) => [
    if (value is List)
      for (final item in value)
        if (item is Map) item.cast<String, dynamic>(),
  ];

  static String? _stateOf(Object? attributes) {
    if (attributes is! Map) return null;
    final state = attributes['state'];
    if (state is String) return state;
    if (state is Map) return state['state'] as String?;
    return null;
  }

  static String? _firstErrorDetail(Object? decoded) {
    if (decoded is Map && decoded['errors'] is List) {
      final errors = decoded['errors'] as List;
      if (errors.isNotEmpty && errors.first is Map) {
        final first = errors.first as Map;
        return '${first['detail'] ?? first['title'] ?? ''}'.trim();
      }
    }
    return null;
  }

  static bool _retryable(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      (error is UploadHttpError &&
          const {408, 429, 500, 502, 503, 504}.contains(error.statusCode));

  static Future<String> _md5(File file) async {
    final sink = DigestResultSink();
    final converter = md5.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      converter.add(chunk);
    }
    converter.close();
    return sink.value.toString();
  }
}

@immutable
final class AscBuildUploadStatus {
  const AscBuildUploadStatus({
    required this.buildUploadId,
    required this.uploadState,
    required this.processingState,
  });

  final String buildUploadId;
  final String? uploadState;
  final String? processingState;

  bool get isValid => processingState == 'VALID';
  bool get isFailed => uploadState == 'FAILED' || processingState == 'INVALID';
}

final class DigestResultSink implements Sink<Digest> {
  Digest? _result;

  Digest get value => _result ?? (throw StateError('MD5 digest is missing'));

  @override
  void add(Digest value) => _result = value;

  @override
  void close() {}
}

final class UploadHttpError implements Exception {
  const UploadHttpError(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() =>
      'Apple binary upload failed with HTTP $statusCode: $body';
}
