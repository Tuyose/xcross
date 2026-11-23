import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/build_upload.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../support/host_services.dart';

void main() {
  test(
    'streams an IPA, commits the correct checksum and resumes reservations',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'xcross-build-upload-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final ipa = File('${temporary.path}/sample.ipa');
      final bytes = List<int>.generate(4097, (index) => index % 251);
      await ipa.writeAsBytes(bytes);
      final key = CryptoUtils.generateEcKeyPair();
      final keyFile = File('${temporary.path}/AuthKey_TEST.p8');
      await keyFile.writeAsString(
        CryptoUtils.encodeEcPrivateKeyToPem(key.privateKey as ECPrivateKey),
      );
      final credentials = AscCredentials(
        hostServices: testHostServices,
        issuerId: 'issuer',
        keyId: 'TEST',
        privateKeyPath: keyFile.path,
      );
      final requests = <String>[];
      final uploaded = <int>[];
      final client = MockClient.streaming((
        http.BaseRequest request,
        http.ByteStream body,
      ) async {
        requests.add('${request.method} ${request.url.path}');
        final bodyBytes = await body.toBytes();
        if (request.url.path == '/v1/apps/app/buildUploads') {
          return _jsonResponse({
            'data': [
              {
                'type': 'buildUploads',
                'id': 'existing-upload',
                'attributes': {
                  'state': 'AWAITING_UPLOAD',
                  'cfBundleVersion': '7',
                  'cfBundleShortVersionString': '1.2.3',
                },
              },
            ],
          });
        }
        if (request.url.path == '/v1/buildUploadFiles' &&
            request.method == 'POST') {
          expect(
            jsonDecode(utf8.decode(bodyBytes)),
            isA<Map<String, dynamic>>(),
          );
          return _jsonResponse({
            'data': {
              'type': 'buildUploadFiles',
              'id': 'file-id',
              'attributes': {
                'uploadOperations': [
                  {
                    'url': 'https://upload.example/one',
                    'method': 'PUT',
                    'offset': 0,
                    'length': bytes.length,
                    'requestHeaders': [
                      {
                        'name': 'Content-Type',
                        'value': 'application/octet-stream',
                      },
                    ],
                  },
                ],
              },
            },
          });
        }
        if (request.url.host == 'upload.example') {
          uploaded.addAll(bodyBytes);
          return _jsonResponse(const {});
        }
        if (request.url.path == '/v1/buildUploadFiles/file-id' &&
            request.method == 'PATCH') {
          final decoded = (jsonDecode(utf8.decode(bodyBytes)) as Map)
              .cast<String, dynamic>();
          final data = (decoded['data'] as Map).cast<String, dynamic>();
          final attributes = (data['attributes'] as Map)
              .cast<String, dynamic>();
          final checksums = (attributes['sourceFileChecksums'] as Map)
              .cast<String, dynamic>();
          final fileChecksum = (checksums['file'] as Map)
              .cast<String, dynamic>();
          expect(fileChecksum['algorithm'], 'MD5');
          expect(fileChecksum['hash'], md5.convert(bytes).toString());
          return _jsonResponse(const {});
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      });
      final uploader = AscBuildUploadClient(
        credentials,
        httpClient: client,
        maxConcurrentOperations: 1,
      );
      addTearDown(uploader.close);

      final result = await uploader.uploadIpa(
        ipa: ipa,
        appId: 'app',
        shortVersion: '1.2.3',
        buildVersion: '7',
      );

      expect(result.buildUploadId, 'existing-upload');
      expect(result.fileId, 'file-id');
      expect(result.operationCount, 1);
      expect(uploaded, bytes);
      expect(requests, contains('GET /v1/apps/app/buildUploads'));
      expect(requests, contains('POST /v1/buildUploadFiles'));
      expect(requests, contains('PUT /one'));
      expect(requests, contains('PATCH /v1/buildUploadFiles/file-id'));
    },
  );
}

http.StreamedResponse _jsonResponse(
  Map<String, Object?> value, {
  int statusCode = 200,
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(value))),
  statusCode,
  headers: const {'content-type': 'application/json'},
);
