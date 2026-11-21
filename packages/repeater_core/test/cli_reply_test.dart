import 'package:repeater_core/repeater_core.dart';
import 'package:test/test.dart';

void main() {
  group('classifyCliReply', () {
    test('value replies are ok', () {
      expect(classifyCliReply('> on'), CliReplyKind.ok);
      expect(classifyCliReply('> 20'), CliReplyKind.ok);
      // extra.sf has no value prefix.
      expect(classifyCliReply('10'), CliReplyKind.ok);
    });

    test('errors and unknown commands are errors', () {
      expect(classifyCliReply('Err - bad value'), CliReplyKind.error);
      expect(classifyCliReply('Unknown command'), CliReplyKind.error);
      expect(classifyCliReply('??: cpu.freq'), CliReplyKind.error);
    });

    test('reboot notices are distinct from plain ok', () {
      expect(classifyCliReply('OK, reboot required'),
          CliReplyKind.rebootNeeded);
      expect(classifyCliReply('> on (reboot to apply)'),
          CliReplyKind.rebootNeeded);
    });

    test('a lost reply is unknown', () {
      expect(classifyCliReply(''), CliReplyKind.unknown);
      expect(classifyCliReply('   '), CliReplyKind.unknown);
    });
  });

  group('getReplyValue', () {
    test('strips the value prefix', () {
      expect(getReplyValue('> 20'), '20');
      expect(getReplyValue('  >   on  '), 'on');
    });

    test('leaves unprefixed values alone', () {
      expect(getReplyValue('10'), '10');
    });
  });

  test('isUnknownCommand', () {
    expect(isUnknownCommand('Unknown command'), isTrue);
    expect(isUnknownCommand('> on'), isFalse);
  });
}
