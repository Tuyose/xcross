import 'dart:convert';
import 'dart:io';

import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/distribution_provisioning.dart';
import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/src/shared/signing/x509.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/host_services.dart';

String _matchingTestCertificate(http.Request request, String identityDir) {
  final keyPath = p.join(identityDir, 'distribution-key.pem');
  final privateKey = parsePrivateKey(File(keyPath).readAsStringSync(), keyPath);

  final payload = jsonDecode(request.body) as Map<String, dynamic>;
  final data = payload['data'] as Map<String, dynamic>;
  final attributes = data['attributes'] as Map<String, dynamic>;
  final csrPem = attributes['csrContent'] as String;

  final certificatePem = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csrPem,
    365,
    serialNumber: '11256099',
  );

  return base64Encode(CryptoUtils.getBytesFromPEMString(certificatePem));
}

void main() {
  for (final filename in [
    'distribution-cert.pem',
    'distribution-key.pem',
    'distribution-state.json',
    'distribution-profile.mobileprovision',
  ]) {
    test('refuses to overwrite existing $filename', () async {
      final temp = Directory.systemTemp.createTempSync(
        'xcross_distribution_existing_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));

      final identityDir = Directory(p.join(temp.path, 'identity'))
        ..createSync();
      final outputDir = Directory(p.join(temp.path, 'profiles'))..createSync();

      final protectedPath = filename.endsWith('.mobileprovision')
          ? p.join(outputDir.path, filename)
          : p.join(identityDir.path, filename);

      File(protectedPath).writeAsStringSync('DO NOT OVERWRITE');

      var requests = 0;

      final client = AscClient(
        AscCredentials(
          hostServices: testHostServices,
          issuerId: 'test',
          keyId: 'test',
          privateKeyPath: p.join(temp.path, 'unused.p8'),
        ),
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('{}', 500);
        }),
      );
      addTearDown(client.close);

      await expectLater(
        AscDistributionProvisioning(
          hostServices: testHostServices,
          client: client,
        ).provisionIdentity(
          bundleId: 'com.example.app',
          identityDir: identityDir.path,
          outputDir: outputDir.path,
        ),
        throwsA(
          isA<AppleError>().having(
            (AppleError error) => error.message,
            'message',
            contains('already exists'),
          ),
        ),
      );

      expect(requests, 0);
      expect(File(protectedPath).readAsStringSync(), 'DO NOT OVERWRITE');
    });
  }

  test(
    'preserves private key and does not retry certificate conflict',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'xcross_distribution_conflict_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));

      final identityDir = Directory(p.join(temp.path, 'identity'))
        ..createSync();
      final outputDir = Directory(p.join(temp.path, 'profiles'))..createSync();

      final keyPair = CryptoUtils.generateEcKeyPair();
      final authKey = File(p.join(temp.path, 'AuthKey_TEST.p8'));
      authKey.writeAsStringSync(
        CryptoUtils.encodeEcPrivateKeyToPem(keyPair.privateKey as ECPrivateKey),
      );

      var certificateCreations = 0;
      var deletionRequests = 0;

      final client = AscClient(
        AscCredentials(
          hostServices: testHostServices,
          issuerId: 'issuer-test',
          keyId: 'TESTKEY123',
          privateKeyPath: authKey.path,
        ),
        httpClient: MockClient((request) async {
          if (request.method == 'DELETE') {
            deletionRequests++;
            return http.Response('{}', 204);
          }

          if (request.method == 'GET' && request.url.path == '/v1/bundleIds') {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'bundle-1',
                    'attributes': {
                      'identifier': 'com.example.app',
                      'name': 'Example',
                    },
                  },
                ],
              }),
              200,
            );
          }

          if (request.method == 'POST' &&
              request.url.path == '/v1/certificates') {
            certificateCreations++;
            return http.Response(
              jsonEncode({
                'errors': [
                  {'status': '409', 'detail': 'Certificate limit reached'},
                ],
              }),
              409,
            );
          }

          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(client.close);

      final provisioning = AscDistributionProvisioning(
        hostServices: testHostServices,
        client: client,
      );

      Future<void> attempt() async {
        await provisioning.provisionIdentity(
          bundleId: 'com.example.app',
          identityDir: identityDir.path,
          outputDir: outputDir.path,
        );
      }

      await expectLater(attempt(), throwsA(isA<AppleError>()));

      final privateKey = File(p.join(identityDir.path, 'distribution-key.pem'));

      expect(privateKey.existsSync(), isTrue);
      final originalKey = privateKey.readAsStringSync();
      expect(originalKey, contains('PRIVATE KEY'));

      expect(certificateCreations, 1);
      expect(deletionRequests, 0);

      // A second attempt must stop locally before contacting Apple.
      await expectLater(
        attempt(),
        throwsA(
          isA<AppleError>().having(
            (AppleError error) => error.message,
            'message',
            contains('already exists'),
          ),
        ),
      );

      expect(privateKey.readAsStringSync(), originalKey);
      expect(certificateCreations, 1);
      expect(deletionRequests, 0);

      expect(
        File(p.join(identityDir.path, 'distribution-cert.pem')).existsSync(),
        isFalse,
      );
    },
  );
  test('preserves identity when App Store profile creation fails', () async {
    final temp = Directory.systemTemp.createTempSync(
      'xcross_distribution_profile_failure_',
    );
    addTearDown(() => temp.deleteSync(recursive: true));

    final identityDir = Directory(p.join(temp.path, 'identity'))..createSync();
    final outputDir = Directory(p.join(temp.path, 'profiles'))..createSync();

    final keyPair = CryptoUtils.generateEcKeyPair();
    final authKey = File(p.join(temp.path, 'AuthKey_TEST.p8'));
    authKey.writeAsStringSync(
      CryptoUtils.encodeEcPrivateKeyToPem(keyPair.privateKey as ECPrivateKey),
    );

    var certificateCreations = 0;
    var profileCreations = 0;
    var deletionRequests = 0;

    final client = AscClient(
      AscCredentials(
        hostServices: testHostServices,
        issuerId: 'issuer-test',
        keyId: 'TESTKEY123',
        privateKeyPath: authKey.path,
      ),
      httpClient: MockClient((request) async {
        final path = request.url.path;

        if (request.method == 'DELETE') {
          deletionRequests++;
          return http.Response('', 204);
        }

        if (request.method == 'GET' && path == '/v1/bundleIds') {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'bundle-1',
                  'attributes': {
                    'identifier': 'com.example.app',
                    'name': 'Example',
                  },
                },
              ],
            }),
            200,
          );
        }

        if (request.method == 'POST' && path == '/v1/certificates') {
          certificateCreations++;
          return http.Response(
            jsonEncode({
              'data': {
                'id': 'created-cert',
                'attributes': {
                  'certificateContent': _matchingTestCertificate(
                    request,
                    identityDir.path,
                  ),
                  'serialNumber': 'ABC123',
                  'expirationDate': '2040-01-01T00:00:00Z',
                },
              },
            }),
            201,
          );
        }

        if (request.method == 'GET' && path == '/v1/certificates') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'created-cert'},
              ],
            }),
            200,
          );
        }

        if (request.method == 'POST' && path == '/v1/profiles') {
          profileCreations++;
          return http.Response(
            jsonEncode({
              'errors': [
                {'status': '409', 'detail': 'Profile creation rejected'},
              ],
            }),
            409,
          );
        }

        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(client.close);

    final provisioning = AscDistributionProvisioning(
      hostServices: testHostServices,
      client: client,
    );

    Future<void> attempt() => provisioning
        .provisionIdentity(
          bundleId: 'com.example.app',
          identityDir: identityDir.path,
          outputDir: outputDir.path,
        )
        .then((_) {});

    await expectLater(attempt(), throwsA(isA<AppleError>()));

    final key = File(p.join(identityDir.path, 'distribution-key.pem'));
    final cert = File(p.join(identityDir.path, 'distribution-cert.pem'));
    final state = File(p.join(identityDir.path, 'distribution-state.json'));
    final profile = File(
      p.join(outputDir.path, 'distribution-profile.mobileprovision'),
    );

    expect(key.existsSync(), isTrue);
    expect(cert.existsSync(), isTrue);
    expect(state.existsSync(), isTrue);
    expect(profile.existsSync(), isFalse);

    final originalKey = key.readAsStringSync();
    expect(originalKey, contains('PRIVATE KEY'));

    final savedState = jsonDecode(state.readAsStringSync()) as Map;
    expect(savedState['certificateSerialNumber'], 'ABC123');

    expect(certificateCreations, 1);
    expect(profileCreations, 1);
    expect(deletionRequests, 0);

    // A retry must not create a second Apple Distribution certificate.
    await expectLater(attempt(), throwsA(isA<AppleError>()));

    expect(key.readAsStringSync(), originalKey);
    expect(certificateCreations, 1);
    expect(profileCreations, 1);
    expect(deletionRequests, 0);
  });
  test(
    'rejects mismatched Apple certificate before profile creation',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'xcross_distribution_mismatch_',
      );
      addTearDown(() => temp.deleteSync(recursive: true));

      final identityDir = Directory(p.join(temp.path, 'identity'))
        ..createSync();
      final outputDir = Directory(p.join(temp.path, 'profiles'))..createSync();

      final authPair = CryptoUtils.generateEcKeyPair();
      final authKey = File(p.join(temp.path, 'AuthKey_TEST.p8'))
        ..writeAsStringSync(
          CryptoUtils.encodeEcPrivateKeyToPem(
            authPair.privateKey as ECPrivateKey,
          ),
        );

      // Simulate Apple returning a valid certificate for the WRONG key.
      final wrongPair = CryptoUtils.generateRSAKeyPair(keySize: 1024);
      final wrongPrivate = wrongPair.privateKey as RSAPrivateKey;
      final wrongCsr = X509Utils.generateRsaCsrPem(
        {'CN': 'Wrong Distribution Certificate'},
        wrongPrivate,
        wrongPair.publicKey as RSAPublicKey,
      );

      final wrongCertificate = X509Utils.generateSelfSignedCertificate(
        wrongPrivate,
        wrongCsr,
        365,
      );

      final wrongCertificateBase64 = base64Encode(
        CryptoUtils.getBytesFromPEMString(wrongCertificate),
      );

      var certificateCreations = 0;
      var profileCreations = 0;
      var deletions = 0;

      final client = AscClient(
        AscCredentials(
          hostServices: testHostServices,
          issuerId: 'issuer-test',
          keyId: 'TESTKEY123',
          privateKeyPath: authKey.path,
        ),
        httpClient: MockClient((request) async {
          final path = request.url.path;

          if (request.method == 'DELETE') {
            deletions++;
            return http.Response('', 204);
          }

          if (request.method == 'GET' && path == '/v1/bundleIds') {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'bundle-1',
                    'attributes': {
                      'identifier': 'com.example.app',
                      'name': 'Example',
                    },
                  },
                ],
              }),
              200,
            );
          }

          if (request.method == 'POST' && path == '/v1/certificates') {
            certificateCreations++;
            return http.Response(
              jsonEncode({
                'data': {
                  'id': 'wrong-cert',
                  'attributes': {
                    'certificateContent': wrongCertificateBase64,
                    'serialNumber': 'ABC123',
                    'expirationDate': '2040-01-01T00:00:00Z',
                  },
                },
              }),
              201,
            );
          }

          if (request.method == 'GET' && path == '/v1/certificates') {
            return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'wrong-cert'},
                ],
              }),
              200,
            );
          }

          if (request.method == 'POST' && path == '/v1/profiles') {
            profileCreations++;
            return http.Response(
              jsonEncode({
                'data': {
                  'id': 'profile-1',
                  'attributes': {
                    'profileContent': base64Encode([4, 5, 6]),
                  },
                },
              }),
              201,
            );
          }

          fail('Unexpected request: ${request.method} ${request.url}');
        }),
      );
      addTearDown(client.close);

      await expectLater(
        AscDistributionProvisioning(
          hostServices: testHostServices,
          client: client,
        ).provisionIdentity(
          bundleId: 'com.example.app',
          identityDir: identityDir.path,
          outputDir: outputDir.path,
        ),
        throwsA(
          isA<AppleError>().having(
            (AppleError error) => error.message,
            'message',
            contains('does not match'),
          ),
        ),
      );

      expect(certificateCreations, 1);
      expect(profileCreations, 0);
      expect(deletions, 0);

      expect(
        File(p.join(identityDir.path, 'distribution-key.pem')).existsSync(),
        isTrue,
      );
    },
  );
  test('creates isolated distribution identity without revocation', () async {
    final temp = Directory.systemTemp.createTempSync('xcross_distribution');
    addTearDown(() => temp.deleteSync(recursive: true));

    final identityDir = Directory(p.join(temp.path, 'identity'))..createSync();
    final outputDir = Directory(p.join(temp.path, 'profiles'))..createSync();

    final devCert = File(p.join(identityDir.path, 'cert.pem'))
      ..writeAsStringSync('EXISTING DEVELOPMENT CERTIFICATE');
    final devKey = File(p.join(identityDir.path, 'key.pem'))
      ..writeAsStringSync('EXISTING DEVELOPMENT KEY');

    final keyPair = CryptoUtils.generateEcKeyPair();
    final authKey = File(p.join(temp.path, 'AuthKey_TEST.p8'));
    authKey.writeAsStringSync(
      CryptoUtils.encodeEcPrivateKeyToPem(keyPair.privateKey as ECPrivateKey),
    );

    final credentials = AscCredentials(
      hostServices: testHostServices,
      issuerId: 'issuer-test',
      keyId: 'TESTKEY123',
      privateKeyPath: authKey.path,
    );

    var apiRequests = 0;
    var certificateCreations = 0;
    var profileCreations = 0;

    final client = AscClient(
      credentials,
      httpClient: MockClient((request) async {
        apiRequests++;
        final path = request.url.path;

        if (request.method == 'POST' && path == '/v1/certificates') {
          certificateCreations++;
          final body = jsonDecode(request.body) as Map;
          final data = body['data'] as Map;
          final attributes = data['attributes'] as Map;

          expect(attributes['certificateType'], 'DISTRIBUTION');
          expect(attributes['csrContent'], isNotEmpty);

          return http.Response(
            jsonEncode({
              'data': {
                'id': 'created-cert',
                'attributes': {
                  'certificateContent': _matchingTestCertificate(
                    request,
                    identityDir.path,
                  ),
                  'serialNumber': 'ABC123',
                  'expirationDate': '2040-01-01T00:00:00Z',
                },
              },
            }),
            201,
          );
        }

        if (request.method == 'GET' &&
            path == '/v1/bundleIds' &&
            request.url.queryParameters['filter[identifier]'] ==
                'com.example.second') {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'bundle-2',
                  'attributes': {
                    'identifier': 'com.example.second',
                    'name': 'Second',
                  },
                },
              ],
            }),
            200,
          );
        }

        if (request.method == 'GET' && path == '/v1/bundleIds') {
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'bundle-1',
                  'attributes': {
                    'identifier': 'com.example.app',
                    'name': 'Example',
                  },
                },
              ],
            }),
            200,
          );
        }

        if (request.method == 'GET' && path == '/v1/certificates') {
          expect(request.url.queryParameters['filter[serialNumber]'], 'ABC123');
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'team-cert-1'},
              ],
            }),
            200,
          );
        }

        if (request.method == 'POST' && path == '/v1/profiles') {
          profileCreations++;
          final body = jsonDecode(request.body) as Map;
          final data = body['data'] as Map;
          final attributes = data['attributes'] as Map;
          final relationships = data['relationships'] as Map;

          final bundleRelationship = relationships['bundleId'] as Map;
          final bundleData = bundleRelationship['data'] as Map;

          expect(
            bundleData['id'],
            profileCreations == 1 ? 'bundle-1' : 'bundle-2',
          );

          expect(attributes['profileType'], 'IOS_APP_STORE');
          expect(relationships.containsKey('devices'), isFalse);

          final certificates =
              (relationships['certificates'] as Map)['data'] as List;
          expect(
            (certificates.single as Map<String, dynamic>)['id'],
            'team-cert-1',
          );

          return http.Response(
            jsonEncode({
              'data': {
                'id': 'profile-1',
                'attributes': {
                  'profileContent': base64Encode([4, 5, 6]),
                },
              },
            }),
            201,
          );
        }

        fail('Unexpected request: ${request.method} ${request.url}');
      }),
    );
    addTearDown(client.close);

    final result =
        await AscDistributionProvisioning(
          hostServices: testHostServices,
          client: client,
        ).provisionIdentity(
          bundleId: 'com.example.app',
          identityDir: identityDir.path,
          outputDir: outputDir.path,
        );

    expect(certificateCreations, 1);
    expect(profileCreations, 1);

    expect(File(result.certificatePemPath).existsSync(), isTrue);
    expect(File(result.privateKeyPemPath).existsSync(), isTrue);
    expect(File(result.profilePath).readAsBytesSync(), [4, 5, 6]);

    expect(devCert.readAsStringSync(), 'EXISTING DEVELOPMENT CERTIFICATE');
    expect(devKey.readAsStringSync(), 'EXISTING DEVELOPMENT KEY');

    final originalCertificate = File(
      result.certificatePemPath,
    ).readAsBytesSync();

    final originalPrivateKey = File(result.privateKeyPemPath).readAsBytesSync();

    final originalState = File(
      p.join(identityDir.path, 'distribution-state.json'),
    ).readAsBytesSync();

    final secondOutputDir = Directory(p.join(temp.path, 'second-profile'))
      ..createSync();

    final provisioning = AscDistributionProvisioning(
      hostServices: testHostServices,
      client: client,
    );

    final second = await provisioning.provisionProfileForExistingIdentity(
      bundleId: 'com.example.second',
      identityDir: identityDir.path,
      outputDir: secondOutputDir.path,
    );

    // Only the profile is new. The certificate and key are reused.
    expect(certificateCreations, 1);
    expect(profileCreations, 2);
    expect(File(second.profilePath).readAsBytesSync(), [4, 5, 6]);

    expect(
      File(second.certificatePemPath).readAsBytesSync(),
      originalCertificate,
    );
    expect(
      File(second.privateKeyPemPath).readAsBytesSync(),
      originalPrivateKey,
    );
    expect(
      File(
        p.join(identityDir.path, 'distribution-state.json'),
      ).readAsBytesSync(),
      originalState,
    );

    // Repeating profile creation must not overwrite existing files.
    await expectLater(
      provisioning.provisionProfileForExistingIdentity(
        bundleId: 'com.example.second',
        identityDir: identityDir.path,
        outputDir: secondOutputDir.path,
      ),
      throwsA(isA<AppleError>()),
    );

    expect(certificateCreations, 1);
    expect(profileCreations, 2);
    // An unregistered Bundle ID must not create a profile.
    final rejectedDir = p.join(temp.path, 'unregistered-profile');

    await expectLater(
      provisioning.provisionProfileForExistingIdentity(
        bundleId: 'com.example.unregistered',
        identityDir: identityDir.path,
        outputDir: rejectedDir,
      ),
      throwsA(
        isA<AppleError>().having(
          (error) => error.message,
          'message',
          contains('not registered'),
        ),
      ),
    );

    expect(
      File(
        p.join(rejectedDir, 'distribution-profile.mobileprovision'),
      ).existsSync(),
      isFalse,
    );

    // Invalid identity state must be rejected without replacing files.
    final stateFile = File(p.join(identityDir.path, 'distribution-state.json'));

    stateFile.writeAsStringSync('{"certificateSerialNumber":""}');

    try {
      await expectLater(
        provisioning.provisionProfileForExistingIdentity(
          bundleId: 'com.example.second',
          identityDir: identityDir.path,
          outputDir: p.join(temp.path, 'invalid-state-profile'),
        ),
        throwsA(
          isA<AppleError>().having(
            (error) => error.message,
            'message',
            contains('no valid certificate serial number'),
          ),
        ),
      );
    } finally {
      stateFile.writeAsBytesSync(originalState);
    }

    expect(stateFile.readAsBytesSync(), originalState);

    // A well-formed but incorrect serial must fail without Apple API calls.
    final requestsBeforeMismatch = apiRequests;
    final tamperedState =
        jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;

    tamperedState['certificateSerialNumber'] = 'DEADBEEF';

    final mismatchDir = p.join(temp.path, 'mismatch-state-profile');

    try {
      stateFile.writeAsStringSync(jsonEncode(tamperedState));

      await expectLater(
        provisioning.provisionProfileForExistingIdentity(
          bundleId: 'com.example.second',
          identityDir: identityDir.path,
          outputDir: mismatchDir,
        ),
        throwsA(
          isA<AppleError>().having(
            (error) => error.message,
            'message',
            contains('serial number does not match'),
          ),
        ),
      );

      expect(apiRequests, requestsBeforeMismatch);

      expect(
        File(
          p.join(mismatchDir, 'distribution-profile.mobileprovision'),
        ).existsSync(),
        isFalse,
      );
    } finally {
      stateFile.writeAsBytesSync(originalState);
    }

    expect(stateFile.readAsBytesSync(), originalState);
    expect(certificateCreations, 1);
    expect(profileCreations, 2);
  });
}
