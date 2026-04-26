/// legoagent — Pybricks Hub 폰 BLE 리모컨 (1차 MVP: scan/connect/characteristic)
///
/// 이 앱은 의도적으로 **쓰기 경로를 구현하지 않는다.**
/// flutter/README.md "0.5단계 영구 저장 검증"이 통과하기 전까지는
/// START_USER_PROGRAM (0x01)도 WRITE_STDIN (0x06)도 보내지 않는다.
///
/// 성공 기준 3개 (flutter/README.md "성공 기준" 섹션):
///   1. Pybricks Hub가 스캔에 보인다
///   2. Hub에 GATT 연결된다
///   3. c5f50002-... command/event characteristic을 찾는다
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

const pybricksServiceUuid = 'c5f50001-8280-46da-89f4-6d8051e4aeef';
const pybricksCommandEventUuid = 'c5f50002-8280-46da-89f4-6d8051e4aeef';

void main() {
  runApp(const LegoAgentApp());
}

class LegoAgentApp extends StatelessWidget {
  const LegoAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'legoagent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
      ),
      home: const ScanConnectScreen(),
    );
  }
}

class ScanConnectScreen extends StatefulWidget {
  const ScanConnectScreen({super.key});

  @override
  State<ScanConnectScreen> createState() => _ScanConnectScreenState();
}

class _ScanConnectScreenState extends State<ScanConnectScreen> {
  String _status = 'idle — Scan을 눌러 Pybricks Hub 찾기';
  bool _scanning = false;
  final List<ScanResult> _results = [];
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _commandEvent;
  int? _mtu;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<bool>? _scanningSub;

  @override
  void initState() {
    super.initState();
    _scanningSub = FlutterBluePlus.isScanning.listen((v) {
      if (mounted) setState(() => _scanning = v);
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _scanningSub?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      setState(() => _status = 'BLE OFF — 시스템 설정에서 Bluetooth 켜기');
      return;
    }
    setState(() {
      _status = 'scanning…';
      _results.clear();
    });
    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.onScanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        _results
          ..clear()
          ..addAll(results);
      });
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(pybricksServiceUuid)],
        timeout: const Duration(seconds: 10),
      );
      if (mounted && _connectedDevice == null) {
        setState(() => _status = _results.isEmpty
            ? '스캔 완료 — Hub 미발견. 허브 켜고 노트북 BLE 끊었는지 확인'
            : '스캔 완료 — 목록에서 Hub 선택');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'scan error: $e');
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
    setState(() => _status = 'connecting → ${_displayName(device)} …');
    try {
      await device.connect(timeout: const Duration(seconds: 15));

      // stdin 라인이 패킷 분할 없이 가도록 MTU 협상 (homeagent 패턴)
      final mtu = await device.requestMtu(247);

      setState(() {
        _mtu = mtu;
        _status = 'connected (MTU=$mtu) — discovering services…';
      });

      final services = await device.discoverServices();
      final svc = services.firstWhere(
        (s) =>
            s.uuid.toString().toLowerCase() ==
            pybricksServiceUuid.toLowerCase(),
        orElse: () => throw StateError(
          'Pybricks service ($pybricksServiceUuid) not found',
        ),
      );
      final char = svc.characteristics.firstWhere(
        (c) =>
            c.uuid.toString().toLowerCase() ==
            pybricksCommandEventUuid.toLowerCase(),
        orElse: () =>
            throw StateError('command/event characteristic not found'),
      );

      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            _status = 'disconnected';
            _commandEvent = null;
            _connectedDevice = null;
            _mtu = null;
          });
        }
      });

      if (!mounted) return;
      setState(() {
        _connectedDevice = device;
        _commandEvent = char;
        _status = 'READY — command/event characteristic 발견';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'connect error: $e');
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  Future<void> _disconnect() async {
    final d = _connectedDevice;
    if (d == null) return;
    try {
      await d.disconnect();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _connectedDevice = null;
      _commandEvent = null;
      _mtu = null;
      _status = 'disconnected';
    });
  }

  String _displayName(BluetoothDevice d) =>
      d.platformName.isEmpty ? '(unnamed)' : d.platformName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = _connectedDevice != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('legoagent — Pybricks BLE'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _status,
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (connected)
              Card(
                color: theme.colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connected: ${_displayName(_connectedDevice!)}',
                        style: theme.textTheme.titleMedium,
                      ),
                      Text('id:  ${_connectedDevice!.remoteId}'),
                      if (_mtu != null) Text('MTU: $_mtu'),
                      const SizedBox(height: 6),
                      Text(
                        'command/event:\n${_commandEvent!.uuid}',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '— write path는 0.5 검증 통과 후 활성화 —',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onPrimaryContainer
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (!connected && !_scanning) ? _startScan : null,
                    icon: _scanning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bluetooth_searching),
                    label: Text(_scanning ? 'Scanning…' : 'Scan'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: connected ? _disconnect : null,
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        connected
                            ? '연결됨 — 끊으려면 Disconnect'
                            : 'Hub 미검색. Scan 누르기',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final r = _results[i];
                        return ListTile(
                          leading: const Icon(Icons.bluetooth),
                          title: Text(_displayName(r.device)),
                          subtitle:
                              Text('${r.device.remoteId}  RSSI ${r.rssi}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap:
                              connected ? null : () => _connect(r.device),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
