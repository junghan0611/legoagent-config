/// legoagent — Pybricks Hub 폰 BLE 리모컨
///
/// 역할 분리 (flutter/README.md "역할 분리" 섹션):
///   Pybricks Code = 펌웨어/프로그램 설치 도구
///   Flutter App   = START + WRITE_STDIN 리모컨
///
/// **이 앱은 업로드를 모른다.** 허브 hub slot에 main.py가 Pybricks Code로
/// 미리 Download되어 있어야 동작한다. 0.5 검증 게이트 전이라 전원 사이클
/// 후 잔존 여부는 미검증 — UI에 경고가 박혀 있다.
///
/// 안전장치:
///   - 앱이 background/hidden/inactive로 가면 자동 `drv stp`
///   - Drive pad: 누름 = 방향 명령, 뗌 = `drv stp` (deadman)
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

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
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String _status = 'idle — Scan을 눌러 Pybricks Hub 찾기';
  bool _scanning = false;
  final List<ScanResult> _results = [];
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _commandEvent;
  int? _mtu;
  String _lastWrite = '';

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<bool>? _scanningSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scanningSub = FlutterBluePlus.isScanning.listen((v) {
      if (mounted) setState(() => _scanning = v);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    _connSub?.cancel();
    _scanningSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 앱이 화면에서 벗어나면 즉시 stop — 바론이 휴대폰 떨어뜨려도 차가 멈춘다.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _emergencyStop();
    }
  }

  // ---- Permissions ----

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final ok = (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
        (statuses[Permission.bluetoothConnect]?.isGranted ?? false);
    if (!ok && mounted) {
      setState(() =>
          _status = '권한 거부됨 — 시스템 설정 → legoagent → Bluetooth 허용');
    }
    return ok;
  }

  // ---- Scan/Connect ----

  Future<void> _startScan() async {
    if (!await _ensurePermissions()) return;
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
            _lastWrite = '';
          });
        }
      });
      if (!mounted) return;
      setState(() {
        _connectedDevice = device;
        _commandEvent = char;
        _status = 'READY — Start slot 0 → Drive';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'connect error: $e');
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  Future<void> _disconnect() async {
    await _emergencyStop();
    final d = _connectedDevice;
    if (d == null) return;
    try {
      await d.disconnect();
    } catch (_) {}
  }

  String _displayName(BluetoothDevice d) =>
      d.platformName.isEmpty ? '(unnamed)' : d.platformName;

  // ---- Write helpers ----

  Future<void> _writeCommand(List<int> bytes, String label) async {
    final char = _commandEvent;
    if (char == null) return;
    try {
      await char.write(bytes, withoutResponse: false);
      if (mounted) setState(() => _lastWrite = '✓ $label');
    } catch (e) {
      if (mounted) setState(() => _lastWrite = '✗ $label: $e');
    }
  }

  Future<void> _startDefault() => _writeCommand([0x01], 'START default');

  Future<void> _startSlot0() => _writeCommand([0x01, 0x00], 'START slot 0');

  Future<void> _writeLine(String line) =>
      _writeCommand([0x06, ...utf8.encode('$line\n')], line);

  Future<void> _emergencyStop() async {
    final char = _commandEvent;
    if (char == null) return;
    try {
      await char.write(
        [0x06, ...utf8.encode('drv stp\n')],
        withoutResponse: false,
      );
    } catch (_) {}
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = _connectedDevice != null;
    return Scaffold(
      appBar: AppBar(title: const Text('legoagent — Pybricks BLE')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _status,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              if (_lastWrite.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _lastWrite,
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 8),
              if (connected) _connectedCard(theme),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          (!connected && !_scanning) ? _startScan : null,
                      icon: _scanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
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
                child: connected
                    ? _controlsView(theme)
                    : _scanResultsView(theme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectedCard(ThemeData theme) {
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connected: ${_displayName(_connectedDevice!)}  (MTU=$_mtu)',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              '⚠ main.py가 Pybricks Code로 slot 0에 Download되어 있어야 동작합니다.\n'
              '   0.5 검증 게이트 전 — 전원 사이클 후 잔존 여부 미검증.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer
                    .withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scanResultsView(ThemeData theme) {
    if (_results.isEmpty) {
      return Center(
        child: Text('Hub 미검색. Scan 누르기',
            style: theme.textTheme.bodyMedium),
      );
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final r = _results[i];
        return ListTile(
          leading: const Icon(Icons.bluetooth),
          title: Text(_displayName(r.device)),
          subtitle: Text('${r.device.remoteId}  RSSI ${r.rssi}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _connect(r.device),
        );
      },
    );
  }

  Widget _controlsView(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel(theme, 'Quick'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _quickButton('Start default', _startDefault),
              _quickButton('Start slot 0', _startSlot0),
              _quickButton('Beep', () => _writeLine('snd beep 660 150')),
              _quickButton('Light red', () => _writeLine('lit 255 0 0')),
              _quickButton(
                'Stop',
                () => _writeLine('drv stp'),
                emphasis: true,
              ),
            ],
          ),
          const SizedBox(height: 20),
          _sectionLabel(theme, 'Drive (누름 = 진행, 뗌 = 정지)'),
          const SizedBox(height: 8),
          _drivePad(),
        ],
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String s) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(s, style: theme.textTheme.titleSmall),
      );

  Widget _quickButton(
    String label,
    VoidCallback onTap, {
    bool emphasis = false,
  }) {
    if (emphasis) {
      return FilledButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.stop_circle),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.red.shade600,
          foregroundColor: Colors.white,
        ),
      );
    }
    return FilledButton.tonal(
      onPressed: onTap,
      child: Text(label),
    );
  }

  Widget _drivePad() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PadCell(),
              _PadCell(child: _DirButton(Icons.arrow_upward, 'drv fwd', this)),
              const _PadCell(),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PadCell(child: _DirButton(Icons.arrow_back, 'drv lft', this)),
              _PadCell(child: _CenterStop(this)),
              _PadCell(
                child: _DirButton(Icons.arrow_forward, 'drv rgt', this),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PadCell(),
              _PadCell(
                child: _DirButton(Icons.arrow_downward, 'drv rev', this),
              ),
              const _PadCell(),
            ],
          ),
        ],
      ),
    );
  }
}

class _PadCell extends StatelessWidget {
  final Widget? child;
  const _PadCell({this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: 88, height: 88, child: child ?? const SizedBox());
  }
}

class _DirButton extends StatelessWidget {
  final IconData icon;
  final String pressLine;
  final _HomeScreenState owner;
  const _DirButton(this.icon, this.pressLine, this.owner);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTapDown: (_) => owner._writeLine(pressLine),
      onTapUp: (_) => owner._writeLine('drv stp'),
      onTapCancel: () => owner._writeLine('drv stp'),
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          icon,
          size: 40,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _CenterStop extends StatelessWidget {
  final _HomeScreenState owner;
  const _CenterStop(this.owner);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => owner._writeLine('drv stp'),
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.red.shade600,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(Icons.stop, size: 40, color: Colors.white),
      ),
    );
  }
}
