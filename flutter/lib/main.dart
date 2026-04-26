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
///   - dispose 시에도 best-effort `drv stp`
///
/// 상태 상호작용 (바론이가 좋아하는 부분):
///   - notify 구독으로 `main.py`의 emit() stdout 라인을 받는다 (event 0x01)
///   - 배터리는 **자동 폴링 없음** — Refresh 버튼을 누르면 'bat' 한 번 보낸다
///     (자동화는 어른의 리듬이고, 아이는 누르고 응답이 오는 흐름에 감동한다)
///   - 마지막 허브 라인을 화면에 노출 (오타·에러도 바로 보인다)
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

  // Hub state — bat 폴링 + emit() 라인 누적
  int? _batteryMv;
  int? _batteryMa;
  DateTime? _batteryAt;
  String _lastHubLine = '';
  String _notifyBuf = '';

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<List<int>>? _notifySub;

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
    // 화면이 사라지기 직전 best-effort stop — 앱 강제 종료/네비게이션 모두 커버
    _emergencyStop();
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    _connSub?.cancel();
    _scanningSub?.cancel();
    _notifySub?.cancel();
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
          _stopHubTelemetry();
          setState(() {
            _status = 'disconnected';
            _commandEvent = null;
            _connectedDevice = null;
            _mtu = null;
            _lastWrite = '';
            _batteryMv = null;
            _batteryMa = null;
            _batteryAt = null;
            _lastHubLine = '';
            _notifyBuf = '';
          });
        }
      });

      // notify 구독: Pybricks event 0x01 = WRITE_STDOUT (program emit)
      await char.setNotifyValue(true);
      _notifySub = char.lastValueStream.listen(_onNotify);

      if (!mounted) return;
      setState(() {
        _connectedDevice = device;
        _commandEvent = char;
        _status = 'READY — Start slot 0 → 버튼을 누르면 허브가 응답합니다';
      });
      // 배터리/상태는 자동 폴링하지 않는다. 아이가 Refresh를 누르면 응답이 온다.
    } catch (e) {
      if (mounted) setState(() => _status = 'connect error: $e');
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  Future<void> _disconnect() async {
    await _emergencyStop();
    _stopHubTelemetry();
    final d = _connectedDevice;
    if (d == null) return;
    try {
      await d.disconnect();
    } catch (_) {}
  }

  void _stopHubTelemetry() {
    _notifySub?.cancel();
    _notifySub = null;
  }

  // ---- Notify (hub → app) ----

  void _onNotify(List<int> bytes) {
    if (bytes.isEmpty) return;
    // Pybricks event byte: 0x00=STATUS_REPORT, 0x01=WRITE_STDOUT.
    // 우리는 stdout만 읽는다.
    if (bytes.first != 0x01) return;
    final chunk = utf8.decode(bytes.sublist(1), allowMalformed: true);
    _notifyBuf += chunk;
    while (true) {
      final nl = _notifyBuf.indexOf('\n');
      if (nl < 0) break;
      final raw = _notifyBuf.substring(0, nl);
      _notifyBuf = _notifyBuf.substring(nl + 1);
      final line = raw.replaceAll('\r', '').trim();
      if (line.isEmpty) continue;
      _onHubLine(line);
    }
  }

  void _onHubLine(String line) {
    if (!mounted) return;
    if (line.startsWith('tlm bat ')) {
      // "tlm bat v=7800 i=200" — Pybricks PrimeHub.battery: voltage(mV), current(mA)
      int? mv;
      int? ma;
      for (final tok in line.split(' ')) {
        if (tok.startsWith('v=')) mv = int.tryParse(tok.substring(2));
        if (tok.startsWith('i=')) ma = int.tryParse(tok.substring(2));
      }
      setState(() {
        _batteryMv = mv;
        _batteryMa = ma;
        _batteryAt = DateTime.now();
      });
      return;
    }
    setState(() => _lastHubLine = line);
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
    final age = _batteryAt == null
        ? ''
        : '   (${DateTime.now().difference(_batteryAt!).inSeconds}s 전)';
    final batLine = _batteryMv == null
        ? '🔋 Battery: 🔄 Refresh를 누르면 허브가 알려줍니다'
        : '🔋 ${(_batteryMv! / 1000).toStringAsFixed(2)} V'
            '${_batteryMa == null ? '' : '   ⚡ $_batteryMa mA'}$age';
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
            Text(batLine, style: theme.textTheme.titleSmall),
            if (_lastHubLine.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '↩ $_lastHubLine',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
          _sectionLabel(theme, 'Program'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _quickButton('Start default', _startDefault),
              _quickButton('Start slot 0', _startSlot0),
              _quickButton('Hub OK', () => _writeLine('hub info')),
              _quickButton('🔄 Refresh battery', () => _writeLine('bat')),
              _quickButton(
                'Stop',
                () => _writeLine('drv stp'),
                emphasis: true,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _sectionLabel(theme, 'Light'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _quickButton('Red', () => _writeLine('lit 255 0 0')),
              _quickButton('Green', () => _writeLine('lit 0 255 0')),
              _quickButton('Blue', () => _writeLine('lit 0 0 255')),
              _quickButton('Off', () => _writeLine('lit 0 0 0')),
            ],
          ),
          const SizedBox(height: 16),
          _sectionLabel(theme, 'Sound'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _quickButton('Beep', () => _writeLine('snd beep 660 150')),
              _quickButton('C5', () => _writeLine('snd note C5 200')),
              _quickButton('E5', () => _writeLine('snd note E5 200')),
              _quickButton('G5', () => _writeLine('snd note G5 200')),
            ],
          ),
          const SizedBox(height: 16),
          _sectionLabel(theme, 'Display'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _quickButton('HI', () => _writeLine('dsp text HI')),
              _quickButton('Smile', () => _writeLine('dsp icon HAPPY')),
              _quickButton('Clear', () => _writeLine('dsp clear')),
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
