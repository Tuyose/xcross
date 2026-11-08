import 'package:test/test.dart';
import 'package:xcross/src/composition/cli/flutter_build_command.dart';

void main() {
  test('App Store signing is disabled by default', () {
    final args = parseFlutterBuildArgs(['--release', '--ipa']);

    expect(args.appStore, isFalse);
  });

  test('App Store signing requires explicit opt-in', () {
    final args = parseFlutterBuildArgs(['--release', '--ipa', '--app-store']);

    expect(args.appStore, isTrue);
  });
}
