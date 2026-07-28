import 'package:flutter_test/flutter_test.dart';
import 'package:pi_pilot/core/pi_connection.dart';

void main() {
  group('parseHostInput', () {
    test('误粘贴完整 http URL(带路径与端口)', () {
      final r = parseHostInput('http://192.168.1.100:9377/health');
      expect(r, isNotNull);
      expect(r!.host, '192.168.1.100');
      expect(r.port, 9377);
    });

    test('误粘贴 ws URL(无端口)', () {
      final r = parseHostInput('ws://example.com/socket');
      expect(r, isNotNull);
      expect(r!.host, 'example.com');
      expect(r.port, isNull);
    });

    test('纯 IPv4', () {
      final r = parseHostInput('192.168.1.100');
      expect(r!.host, '192.168.1.100');
      expect(r.port, isNull);
    });

    test('IPv4:port', () {
      final r = parseHostInput('192.168.1.100:9377');
      expect(r!.host, '192.168.1.100');
      expect(r.port, 9377);
    });

    test('误带路径(无 scheme)', () {
      final r = parseHostInput('192.168.1.100/health');
      expect(r!.host, '192.168.1.100');
      expect(r.port, isNull);
    });

    test('前后空格 trim', () {
      final r = parseHostInput('  192.168.1.100  ');
      expect(r!.host, '192.168.1.100');
    });

    test('主机名', () {
      final r = parseHostInput('my-desktop.local');
      expect(r!.host, 'my-desktop.local');
      expect(r.port, isNull);
    });

    test('带方括号 IPv6 + 端口', () {
      final r = parseHostInput('[::1]:9377');
      expect(r!.host, '::1');
      expect(r.port, 9377);
    });

    test('空字符串 → null', () {
      expect(parseHostInput(''), isNull);
      expect(parseHostInput('   '), isNull);
    });

    test('只有 scheme → null', () {
      expect(parseHostInput('http://'), isNull);
    });

    test('冒号后非数字端口 → null', () {
      expect(parseHostInput('host:abc'), isNull);
    });

    test('含空白字符的主机 → null', () {
      expect(parseHostInput('my host'), isNull);
    });
  });
}
