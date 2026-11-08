import 'package:apple_developer_kit/src/shared/appstoreconnect/asc_payloads.dart';
import 'package:test/test.dart';

void main() {
  test('development profile keeps device relationships', () {
    final payload = AscPayloads.profile(
      name: 'Development',
      bundleIdResourceId: 'bundle-1',
      certificateResourceIds: ['cert-1'],
      deviceResourceIds: ['device-1'],
    );

    final data = payload['data'] as Map<String, dynamic>;
    final attributes = data['attributes'] as Map<String, dynamic>;
    final relationships = data['relationships'] as Map<String, dynamic>;

    expect(attributes['profileType'], 'IOS_APP_DEVELOPMENT');
    expect(relationships.containsKey('devices'), isTrue);
  });

  test('App Store profile must not include devices', () {
    final payload = AscPayloads.profile(
      name: 'Distribution',
      bundleIdResourceId: 'bundle-1',
      certificateResourceIds: ['cert-1'],
      deviceResourceIds: [],
      profileType: 'IOS_APP_STORE',
    );

    final data = payload['data'] as Map<String, dynamic>;
    final attributes = data['attributes'] as Map<String, dynamic>;
    final relationships = data['relationships'] as Map<String, dynamic>;

    expect(attributes['profileType'], 'IOS_APP_STORE');
    expect(relationships.containsKey('devices'), isFalse);
  });
}
