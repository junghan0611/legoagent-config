# 인바리언트 체크 가이드

> AGENTS.md / README.md는 **방향과 금지** (뭘 안 만들 것).
> 이 문서는 **런타임 검증 규칙** (코드가 지켜야 할 불변 조건 + 체크 방법).
>
> 새 기능/버그 수정 시 해당 섹션을 읽고, 위반 가능성을 코드에서 확인한다.

이 저장소는 **레고 자동차를 폰으로 직접 제어**한다. 사람(특히 어린이)이 손에 들고 움직인다. 그래서 인바리언트의 무게중심은 두 가지다.

1. **Safety** — 차가 의도 없이 움직이면 안 된다. 의도가 끊기면 즉시 멈춘다.
2. **Layering** — Flutter 앱은 업로드를 모른다. Pybricks 프로토콜을 우회하지 않는다.

---

## Dart (Flutter)

### D-1: Drive 제어는 deadman — 손 떼면 무조건 `drv stp`

**위반 패턴**:
```dart
GestureDetector(
  onTapDown: (_) => owner._writeLine('drv fwd'),
  onTapUp: (_) => owner._writeLine('drv stp'),
  // onTapCancel 빠짐 ← 손가락이 버튼 밖으로 슬라이드하면 차가 계속 달림
)
```

**규칙**: 방향 명령을 시작한 모든 제스처는 **세 콜백 모두**에서 stop을 보낸다.
- `onTapUp` — 정상적으로 손 뗌
- `onTapCancel` — 제스처 취소 (스크롤, 다른 위젯이 가로챔, 손가락이 hit 영역 밖으로 이동)
- 필요하면 `onPanEnd`도 동일

```dart
// ✅ 올바른 패턴
onTapDown: (_) => owner._writeLine('drv fwd'),
onTapUp: (_) => owner._writeLine('drv stp'),
onTapCancel: () => owner._writeLine('drv stp'),
```

**적용 대상**: `flutter/lib/main.dart`의 `_DirButton`, 추후 추가될 모든 연속 동작 컨트롤(스로틀 슬라이더, 조이스틱 등).

---

### D-2: 앱이 시야에서 사라지면 즉시 stop

**위반 패턴**:
```dart
class _State extends State<...> {
  // WidgetsBindingObserver 없음 → 화면 꺼져도 차는 계속 달림
}
```

**규칙**: 명령을 보내는 화면은 `WidgetsBindingObserver`를 mixin으로 달고, `paused / inactive / hidden / detached` 어느 하나라도 들어오면 emergency stop을 발사. `dispose()`에서 observer 제거.

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.paused ||
      state == AppLifecycleState.inactive ||
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.detached) {
    _emergencyStop();
  }
}
```

**왜**: 폰을 떨어뜨리거나 알림 창을 내리거나 홈으로 빠져나가도 차는 멈춰야 한다. 바론이가 제어한다.

**적용 대상**: `flutter/lib/main.dart`의 `_HomeScreenState`. 추후 분리되는 모든 제어 화면.

---

### D-3: Disconnect / 연결 종료 전에 emergency stop 먼저

**위반 패턴**:
```dart
Future<void> _disconnect() async {
  await device.disconnect();  // 차가 마지막 명령(예: drv fwd) 상태로 굳어버림
}
```

**문제**: BLE 끊긴 직후의 허브 동작은 `main.py` 구현에 따라 다르다. 프로토콜 레벨에서 자동 stop을 가정하지 않는다.

**규칙**: 모든 disconnect 경로(사용자 누름, 에러, dispose) 직전에 best-effort `drv stp` 한 번. 실패해도 무시 (이미 끊긴 상태일 수 있음).

**적용 대상**: `_disconnect()`, 향후 추가될 자동 재연결 로직.

---

### D-4: BLE characteristic write — `withoutResponse: false` 고정

**위반 패턴**:
```dart
await _commandEvent!.write(bytes, withoutResponse: true);
// 또는 인자 누락 (기본값이 플랫폼/버전에 따라 다름)
```

**문제**: Pybricks command/event characteristic은 **with-response**가 정상 경로. without-response로 보내면 전송 순서/유실이 생기고, 특히 `WRITE_STDIN(0x06)`에서 라인이 깨진다.

**규칙**: command/event characteristic write는 항상 `withoutResponse: false` 명시.

```dart
await _commandEvent!.write(
  [0x06, ...utf8.encode('$line\n')],
  withoutResponse: false,
);
```

**적용 대상**: `_writeCommand`, `_emergencyStop`, 추후 추가될 모든 write 헬퍼.

---

### D-5: MTU 협상 — 줄 단위 명령은 한 패킷에 들어가야 한다

**위반 패턴**:
```dart
await device.connect(...);
await device.discoverServices();  // requestMtu 없이 바로 서비스 탐색
```

**문제**: 기본 MTU 23이면 한 write가 20바이트 페이로드로 잘려, `WRITE_STDIN`의 줄이 패킷 분할되며 `main.py`의 `readline()`이 부서진 라인을 받는다.

**규칙**: connect 직후 `discoverServices()` **전에** `requestMtu(247)` 호출. 결과 MTU를 상태에 저장해두고, 협상이 떨어지면 화면에 노출 (잘림 디버깅용).

**적용 대상**: `_connect()`. homeagent 패턴과 동일.

---

### D-6: 권한 — Scan 시작 전에 런타임 요청, 결과 검증

**위반 패턴**:
```dart
Future<void> _startScan() async {
  await FlutterBluePlus.startScan(...);  // 권한 거부 시 빈 결과 → "Hub 미검색"으로 오인
}
```

**규칙**: `_startScan` 첫 줄에서 `_ensurePermissions()` await. `BLUETOOTH_SCAN`과 `BLUETOOTH_CONNECT` 둘 다 granted 확인 후에만 진행. 거부 시 사용자에게 **시스템 설정 경로** 안내(거부 후 재요청은 다이얼로그가 뜨지 않을 수 있음).

**적용 대상**: `_startScan`, 추후 추가될 background scan / re-scan.

---

### D-7: StreamSubscription — 만들면 닫아라

**위반 패턴**:
```dart
@override
void initState() {
  FlutterBluePlus.isScanning.listen((v) { ... });  // 핸들 안 잡음 → cancel 불가
}
```

**규칙**: 모든 `listen()` 결과는 필드에 저장하고 `dispose()`에서 `cancel()`. 재연결 경로에서 기존 sub를 덮어쓸 때도 이전 sub를 먼저 cancel.

**적용 대상**: `_scanSub`, `_connSub`, `_scanningSub`. 향후 notify 구독 추가 시 동일.

---

### D-8: Pybricks 프로토콜 우회 금지 — Flutter 앱은 업로드를 모른다

**위반 패턴**:
```dart
// main.py 바이너리를 BLE로 직접 push하려고 시도
await _commandEvent!.write([0x05 /* WRITE_USER_PROGRAM_META? */, ...]);
```

**문제**: `WRITE_USER_PROGRAM_META`, `COMMAND_WRITE_USER_RAM`, MicroPython 컴파일 등 전송 프로토콜을 직접 짜는 순간 MVP가 무너진다 (`flutter/README.md` 참조).

**규칙**: Flutter 앱이 보내는 byte는 **두 종류만**.
- `[0x01]` 또는 `[0x01, slot]` — `START_USER_PROGRAM`
- `[0x06, ...utf8.encode('$line\n')]` — `WRITE_STDIN`

업로드는 Pybricks Code에서 한다. 새 명령이 필요하면 `pybricks/main.py`의 `handle()`에 라인 명령으로 추가하는 게 정공법.

**적용 대상**: `flutter/lib/main.dart` 전체. 새 버튼/기능을 만들 때 가장 먼저 위반 여부 확인.

---

### D-10: 자동 폴링 / 자동 갱신 금지 — 상태는 사용자 액션 뒤에 온다

**위반 패턴**:
```dart
_batteryTimer = Timer.periodic(
  const Duration(seconds: 5),
  (_) => _writeLine('bat'),
);
```

**문제**: 효율을 추구하는 어른의 리듬이다. 레고에이전트는 *"눌렀더니 허브가 응답했다"*는 흐름 자체가 작품이다. 자동화가 깔리는 순간 아이는 *자기 행동의 결과*가 아니라 *앱이 알아서 채우는 숫자*를 보게 된다. 나중에 들어올 진짜 에이전트/자동화도 이 기초 위에 얹어야 거부감이 없다.

**규칙**: 새 상태를 가져오는 모든 명령은 사용자 버튼 누름 뒤에서만 발사. `Timer.periodic`/`Stream` 기반 자동 갱신은 **금지**. notify 구독은 OK — 그건 허브가 자발적으로 보내는 흐름이지 앱이 만드는 폴링이 아니다.

예외: 안전 관련(emergency stop의 lifecycle 트리거, 권한 변화 감지)은 자동이어도 된다. 사용자 의도 없이 차가 움직이지 않게 하는 자동화는 항상 허용.

**적용 대상**: 배터리/IMU/허브 정보 등 모든 텔레메트리 요청. 향후 추가될 모든 "상태 보기" 기능.

> 디자인 원칙으로 한 단계 위에서 [flutter/README.md "상호작용 원칙"](./flutter/README.md), [AGENTS.md](./AGENTS.md)에 같은 내용이 더 풀어져 있다.

---

### D-9: 명령은 한 곳을 통과한다 — `_writeLine` / `_writeCommand` 우회 금지

**위반 패턴**:
```dart
// 어느 핸들러에서 char.write(...)를 직접 호출
await _commandEvent!.write([0x06, 0x64, 0x72, 0x76, ...], withoutResponse: false);
```

**문제**: write 인자/withoutResponse/에러 처리/마지막 write 표시가 분산되면 D-4 위반과 디버그 불가 상태가 동시에 온다.

**규칙**: write는 `_writeCommand(bytes, label)` 또는 `_writeLine(line)` 헬퍼 한 통로로만. UI 콜백은 헬퍼만 호출.

---

## Python (pybricks/main.py)

### P-1: `handle(line)`는 알 수 없는 명령을 침묵으로 무시하지 않는다

**위반 패턴**:
```python
def handle(line):
    parts = line.strip().split()
    if not parts: return
    if parts[0] == "drv": ...
    # else: pass  ← 오타 / 신규 명령 디버깅 불가
```

**규칙**: 매칭 실패 시 `emit("ERR unknown:" + parts[0])` 같은 한 줄 로그. 폰에서 notify로 받으면 즉시 보임.

---

### P-2: 모터 호출은 안전 가드 뒤에서

**규칙**: BLE 라인 처리는 신뢰할 수 없는 입력으로 본다. 속도/방향 인자는 `int()` 변환 실패, 범위 초과 모두 try/except로 잡고 `brake_all()`로 폴백. 명령 하나가 예외를 던지면서 stdin 루프가 죽으면 차가 마지막 상태로 굳는다.

---

### P-3: 기동 직후 모터 출력 금지 — 사용자 확인 후

**규칙**: `START_USER_PROGRAM` 직후 자동으로 바퀴를 돌리지 않는다. `alive.py`처럼 LED/소리 등 비주얼/오디오 신호로 "준비됨"만 표시. 첫 모터 출력은 폰에서 명령이 들어와야 시작.

---

## 운영 / 검증 게이트

### O-1: 0.5 검증 게이트 미통과 상태에서 write path를 켜는 변경은 UI에 명시한다

`flutter/README.md`의 0.5단계(전원 사이클 후 slot 0 잔존)가 통과하기 전까지, write를 활성화하더라도 **연결 카드에 경고**를 표시한다. 검증이 통과하면 경고를 제거하고 README 0.5 섹션도 업데이트한다.

---

### O-2: 빌드/테스트 체크리스트

새 PR/커밋 전에:

```bash
nix develop .#flutter --command bash -c "cd flutter && flutter analyze"
nix develop .#flutter --command bash -c "cd flutter && flutter test"
nix develop .#flutter --command bash -c "cd flutter && flutter build apk --debug"
```

세 개 모두 통과해야 한다. APK 크기가 크게 변하면 (>20MB) 의존성 추가 의도 검토.

---

## 추가 인바리언트가 떠오르면

이 문서에 직접 추가한다. 항목은 **위반 패턴 → 문제 → 규칙 → 적용 대상** 4단 구조를 유지한다. 코드 한 곳에서 발견된 버그가 다시 안 일어나게 하는 것이 목표다.
