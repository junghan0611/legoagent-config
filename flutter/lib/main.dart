/// legoagent — Pybricks Hub 폰 BLE 리모컨
///
/// 역할 분리 (flutter/README.md "역할 분리" 섹션):
///   Pybricks Code = 펌웨어/프로그램 설치 도구
///   Flutter App   = START + WRITE_STDIN 리모컨
///
/// **이 앱은 업로드를 모른다.** Pybricks Code에서 slot 0을 선택해 main.py를
/// Run하고, 허브를 정상 종료해 저장한다. CLI RAM 실행과 웹앱 저장은 구분한다.
/// 폰은 저장된 프로그램을 START하고 줄 명령만 보낸다.
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

import 'build_info.dart';

const pybricksServiceUuid = 'c5f50001-8280-46da-89f4-6d8051e4aeef';
const pybricksCommandEventUuid = 'c5f50002-8280-46da-89f4-6d8051e4aeef';

// 테마 모드 — 폰 디스플레이가 오래돼 흰 바탕이 잘 안 보인다.
// 기본 다크로 켜고, 설정/스캔화면 토글로 라이트 전환 가능.
final themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.dark);

void _toggleTheme() {
  themeNotifier.value = themeNotifier.value == ThemeMode.dark
      ? ThemeMode.light
      : ThemeMode.dark;
}

void main() {
  runApp(const LegoAgentApp());
}

class LegoAgentApp extends StatelessWidget {
  const LegoAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: '레고 리모컨',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorSchemeSeed: Colors.deepPurple,
            useMaterial3: true,
            brightness: Brightness.light,
          ),
          darkTheme: ThemeData(
            colorSchemeSeed: Colors.deepPurple,
            useMaterial3: true,
            brightness: Brightness.dark,
          ),
          themeMode: mode,
          home: const HomeScreen(),
        );
      },
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.testSend, this.testMtu = 23});

  /// 하드웨어 없이 위젯과 명령 경계를 검증한다.
  final Future<void> Function(String line)? testSend;
  final int testMtu;

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
  final _textController = TextEditingController();
  String? _textError;
  VoidCallback? _refreshSettings;

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
    _textController.dispose();
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
    final ok =
        (statuses[Permission.bluetoothScan]?.isGranted ?? false) &&
        (statuses[Permission.bluetoothConnect]?.isGranted ?? false);
    if (!ok && mounted) {
      setState(() => _status = '권한 거부됨 — 시스템 설정 → legoagent → Bluetooth 허용');
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
        setState(
          () => _status = _results.isEmpty
              ? '스캔 완료 — Hub 미발견. 허브 켜고 노트북 BLE 끊었는지 확인'
              : '스캔 완료 — 목록에서 Hub 선택',
        );
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
          _refreshSettings?.call();
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
      _refreshSettings?.call();
      return;
    }
    setState(() => _lastHubLine = line);
    _refreshSettings?.call();
  }

  String _displayName(BluetoothDevice d) =>
      d.platformName.isEmpty ? '(unnamed)' : d.platformName;

  // ---- Write helpers ----

  Future<void> _writeCommand(List<int> bytes, String label) async {
    final char = _commandEvent;
    if (char == null) return;
    try {
      await char.write(bytes, withoutResponse: false);
      if (mounted) {
        setState(() => _lastWrite = '✓ $label');
        _refreshSettings?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _lastWrite = '✗ $label: $e');
        _refreshSettings?.call();
      }
    }
  }

  Future<void> _startSlot0() => _writeCommand([0x01, 0x00], 'START slot 0');

  Future<void> _writeLine(String line) async {
    if (widget.testSend != null) {
      await widget.testSend!(line);
      return;
    }
    await _writeCommand([0x06, ...utf8.encode('$line\n')], line);
  }

  Future<void> _emergencyStop() async {
    // 각각의 완전한 줄을 별도 패킷으로 보낸다 (기본 MTU 23 포함).
    for (final line in ['drv stp', 'aux stp']) {
      try {
        await _writeLine(line);
      } catch (_) {
        // 하나가 실패해도 다른 모터 정지는 계속 시도한다.
      }
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return _connectedDevice == null && widget.testSend == null
        ? _buildScanScaffold(context)
        : _buildConnectedScaffold(context);
  }

  // 연결 전: Scan / 결과 목록만. 사용자에게 보여줄 게 없을 때 군더더기를 줄인다.
  Widget _buildScanScaffold(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('레고 리모컨'),
        actions: [
          IconButton(
            icon: Icon(
              themeNotifier.value == ThemeMode.dark
                  ? Icons.light_mode
                  : Icons.dark_mode,
            ),
            tooltip: '테마 전환 (다크/라이트)',
            onPressed: _toggleTheme,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
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
              FilledButton.icon(
                onPressed: !_scanning ? _startScan : null,
                icon: _scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.bluetooth_searching),
                label: Text(_scanning ? 'Scanning…' : 'Scan'),
              ),
              const SizedBox(height: 12),
              Expanded(child: _scanResultsView(theme)),
            ],
          ),
        ),
      ),
    );
  }

  // 연결 후: AppBar에는 STOP / 설정 두 아이콘만. 본문은 탭 가득.
  // 디바이스 이름·MTU·배터리·last line 같은 메타는 설정 시트로 숨긴다.
  Widget _buildConnectedScaffold(BuildContext context) {
    final theme = Theme.of(context);
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Icon(
                Icons.bluetooth_connected,
                color: Colors.lightGreenAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _connectedDevice == null
                      ? 'Test hub'
                      : _displayName(_connectedDevice!),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(
                Icons.stop_circle,
                color: Colors.redAccent,
                size: 30,
              ),
              tooltip: 'STOP all motors',
              onPressed: _emergencyStop,
            ),
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Status / connection',
              onPressed: () => _openSettingsPage(context),
            ),
          ],
          bottom: TabBar(
            onTap: (_) => _emergencyStop(),
            tabs: const [
              Tab(icon: Icon(Icons.directions_car), text: '운전'),
              Tab(icon: Icon(Icons.piano), text: '피아노'),
              Tab(icon: Icon(Icons.text_fields), text: '글자'),
              Tab(icon: Icon(Icons.lightbulb), text: '조명'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: [_driveTab(theme), _pianoTab(), _textTab(), _fxTab()],
          ),
        ),
      ),
    );
  }

  void _openSettingsPage(BuildContext rootCtx) {
    _emergencyStop();
    Navigator.of(rootCtx)
        .push(
          MaterialPageRoute<void>(
            builder: (sheetCtx) {
              // sheet은 독립 위젯 트리라 부모 setState가 닿지 않는다.
              // Battery refresh 직후 한 번 setSheetState로 새 값을 끌어온다.
              return StatefulBuilder(
                builder: (ctx, setSheetState) {
                  _refreshSettings = () {
                    if (ctx.mounted) setSheetState(() {});
                  };
                  final theme = Theme.of(ctx);
                  final age = _batteryAt == null
                      ? ''
                      : '   (${DateTime.now().difference(_batteryAt!).inSeconds}s 전)';
                  final batLine = _batteryMv == null
                      ? '🔋 Battery: 🔄 Refresh를 누르면 허브가 알려줍니다'
                      : '🔋 ${(_batteryMv! / 1000).toStringAsFixed(2)} V'
                            '${_batteryMa == null ? '' : '   ⚡ $_batteryMa mA'}$age';
                  return Scaffold(
                    appBar: AppBar(title: const Text('리모컨 설정')),
                    body: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        Text(
                          '연결: ${_connectedDevice == null ? (widget.testSend == null ? '연결 끊김' : 'Test hub') : _displayName(_connectedDevice!)}  (MTU=${_mtu ?? (widget.testSend == null ? '미확인' : widget.testMtu)})',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 6),
                        Text(batLine, style: theme.textTheme.titleSmall),
                        if (_lastHubLine.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '↩ $_lastHubLine',
                            style: theme.textTheme.bodySmall,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        if (_lastWrite.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(_lastWrite, style: theme.textTheme.bodySmall),
                        ],
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            _quickButton('Start slot 0', _startSlot0),
                            _quickButton(
                              'Hub OK',
                              () => _writeLine('hub info'),
                            ),
                            _quickButton('🔄 Battery', () async {
                              await _writeLine('bat');
                              // emit가 비동기로 도착해 _batteryMv 가 갱신된 직후 sheet도 다시 그린다.
                              await Future<void>.delayed(
                                const Duration(milliseconds: 300),
                              );
                              if (ctx.mounted) setSheetState(() {});
                            }),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Divider(),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          secondary: Icon(
                            themeNotifier.value == ThemeMode.dark
                                ? Icons.dark_mode
                                : Icons.light_mode,
                          ),
                          title: const Text('다크 모드'),
                          subtitle: const Text('오래된 화면용 — 흰 바탕 줄이기'),
                          value: themeNotifier.value == ThemeMode.dark,
                          onChanged: (_) {
                            _toggleTheme();
                            setSheetState(() {});
                          },
                        ),
                        const SizedBox(height: 4),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.link_off),
                          label: const Text('Disconnect'),
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _disconnect();
                          },
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '⚠ Pybricks Code에서 main.py를 slot 0에 Run하고 허브를 정상 종료해 저장하세요.',
                          style: theme.textTheme.bodySmall,
                        ),
                        const Divider(height: 32),
                        Text('앱 정보', style: theme.textTheme.titleMedium),
                        Text('버전: $appVersion'),
                        Text('빌드 시각: $buildTime'),
                        const SizedBox(height: 16),
                        Text('변경 이력', style: theme.textTheme.titleMedium),
                        for (final entry in changelog) ...[
                          const SizedBox(height: 8),
                          Text(
                            '${entry.date} · ${entry.version}',
                            style: theme.textTheme.titleSmall,
                          ),
                          Text(entry.changes),
                        ],
                      ],
                    ),
                  );
                },
              );
            },
          ),
        )
        .then((_) => _refreshSettings = null);
  }

  Widget _scanResultsView(ThemeData theme) {
    if (_results.isEmpty) {
      return Center(
        child: Text('Hub 미검색. Scan 누르기', style: theme.textTheme.bodyMedium),
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

  Widget _driveTab(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, size) => Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: size.maxHeight < 300
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [_auxRow(theme), _drivePad()],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('누름 = 진행, 뗌 = 정지', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    _auxRow(theme),
                    const SizedBox(height: 8),
                    _drivePad(),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _pianoTab() {
    const notes = ['C4', 'D4', 'E4', 'F4', 'G4', 'A4', 'B4', 'C5'];
    const names = ['도', '레', '미', '파', '솔', '라', '시', '도'];
    const sharps = ['C#4', 'D#4', 'F#4', 'G#4', 'A#4'];
    const boundaries = [1, 2, 4, 5, 6];
    return Padding(
      padding: const EdgeInsets.all(8),
      child: LayoutBuilder(
        builder: (context, size) {
          final keyWidth = size.maxWidth / 8;
          final blackWidth = keyWidth * 0.6;
          return Stack(
            children: [
              Row(
                children: List.generate(
                  8,
                  (i) => Expanded(
                    child: _PianoKey(
                      key: ValueKey('note-${notes[i]}'),
                      label: names[i],
                      sharp: false,
                      onPress: () => _writeLine('snd note ${notes[i]} 200'),
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < sharps.length; i++)
                Positioned(
                  left: keyWidth * boundaries[i] - blackWidth / 2,
                  top: 0,
                  width: blackWidth,
                  height: size.maxHeight * 0.60,
                  child: _PianoKey(
                    key: ValueKey('note-${sharps[i]}'),
                    label: '',
                    sharp: true,
                    onPress: () => _writeLine('snd note ${sharps[i]} 200'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _sendText() {
    final raw = _textController.text;
    final text = raw.replaceAll(RegExp(r' +'), ' ').trim();
    final mtu = widget.testSend == null ? (_mtu ?? 23) : widget.testMtu;
    String? error;
    if (!raw.codeUnits.every((unit) => unit >= 0x20 && unit <= 0x7e)) {
      error = '지원하지 않는 글자가 있어요';
    } else if (text.isEmpty) {
      error = '글자를 입력해 주세요';
    } else if (text.length > 16 ||
        utf8.encode('dsp text $text\n').length + 1 > mtu - 3) {
      error = '글자가 너무 길어요';
    }
    setState(() => _textError = error);
    if (error == null) _writeLine('dsp text $text');
  }

  Widget _textTab() => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _textController,
          maxLines: 1,
          decoration: InputDecoration(
            labelText: '영어, 숫자와 기호',
            errorText: _textError,
          ),
          onChanged: (_) {
            if (_textError != null) setState(() => _textError = null);
          },
          onSubmitted: (_) => _sendText(),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _sendText,
                child: const Text('보여주기'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _writeLine('dsp clear'),
                child: const Text('지우기'),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _fxTab() {
    return Center(
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          _quickButton('Red', () => _writeLine('lit 255 0 0')),
          _quickButton('Green', () => _writeLine('lit 0 255 0')),
          _quickButton('Blue', () => _writeLine('lit 0 0 255')),
          _quickButton('Off', () => _writeLine('lit 0 0 0')),
        ],
      ),
    );
  }

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
    return FilledButton.tonal(onPressed: onTap, child: Text(label));
  }

  // A 포트 보조 모터 — 주행 좌우와 따로 노는 자기만의 좌우. 방향표와 헷갈리지
  // 않게 색(tertiary)과 아이콘(겹화살표)을 다르게 둔다. 데드맨은 `aux stp`.
  Widget _auxRow(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('가운데 모터', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PadCell(
              child: _DirButton(
                Icons.keyboard_double_arrow_left,
                'aux lft',
                this,
                stopLine: 'aux stp',
                tertiary: true,
              ),
            ),
            const SizedBox(width: 88),
            _PadCell(
              child: _DirButton(
                Icons.keyboard_double_arrow_right,
                'aux rgt',
                this,
                stopLine: 'aux stp',
                tertiary: true,
              ),
            ),
          ],
        ),
      ],
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
              _PadCell(child: _DirButton(Icons.arrow_forward, 'drv rgt', this)),
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

class _PianoKey extends StatefulWidget {
  const _PianoKey({
    super.key,
    required this.label,
    required this.sharp,
    required this.onPress,
  });
  final String label;
  final bool sharp;
  final VoidCallback onPress;

  @override
  State<_PianoKey> createState() => _PianoKeyState();
}

class _PianoKeyState extends State<_PianoKey> {
  bool pressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.key.toString(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          setState(() => pressed = true);
          widget.onPress();
        },
        onTapUp: (_) => setState(() => pressed = false),
        onTapCancel: () => setState(() => pressed = false),
        child: Container(
          decoration: BoxDecoration(
            color: pressed
                ? Colors.orange
                : (widget.sharp ? Colors.black : Colors.white),
            border: Border.all(color: Colors.black54),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(5),
            ),
          ),
          alignment: Alignment.bottomCenter,
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            widget.label,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
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
  final String stopLine;
  final bool tertiary;
  const _DirButton(
    this.icon,
    this.pressLine,
    this.owner, {
    this.stopLine = 'drv stp',
    this.tertiary = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTapDown: (_) => owner._writeLine(pressLine),
      onTapUp: (_) => owner._writeLine(stopLine),
      onTapCancel: () => owner._writeLine(stopLine),
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: tertiary
              ? scheme.tertiaryContainer
              : scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          icon,
          size: 40,
          color: tertiary
              ? scheme.onTertiaryContainer
              : scheme.onSecondaryContainer,
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
