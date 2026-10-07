import 'package:connexia/core/sync/sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SyncState.copyWith', () {
    test('clearError resets a previous error', () {
      final failed = const SyncState().copyWith(error: 'boom');
      expect(failed.error, 'boom');

      final recovered = failed.copyWith(clearError: true);
      expect(recovered.error, isNull);
    });

    test('omitting error preserves the existing one', () {
      final failed = const SyncState().copyWith(error: 'boom');
      final untouched = failed.copyWith(pendingSync: true);
      expect(untouched.error, 'boom');
      expect(untouched.pendingSync, isTrue);
    });

    test('a new error replaces the previous one', () {
      final first = const SyncState().copyWith(error: 'first');
      final second = first.copyWith(error: 'second');
      expect(second.error, 'second');
    });
  });
}
