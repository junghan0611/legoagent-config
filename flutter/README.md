# legoagent Flutter MVP 계획

목표: 노트북 없이 안드로이드폰 하나가 LEGO SPIKE Prime 허브에 BLE로 직접 붙는다.

노트북 ↔ 허브 BLE 경로는 Day 1에 검증 끝났다. 이제 같은 일을 폰이 단독으로 한다.

이번 MVP는 **주행 제어가 아니다.** 우선순위는 오직 다음 한 줄이다.

> Flutter 앱에서 Pybricks Hub를 스캔하고, 연결하고, Command/Event characteristic에 접근한다.

## 역할 분리 (이 한 줄을 흔들지 마라)

```text
Pybricks Code = 펌웨어/프로그램 설치 도구
Flutter App   = 바론이 리모컨 (시작 + stdin)
```

Flutter가 업로드까지 하려는 순간 Pybricks 전송 프로토콜(WRITE_USER_PROGRAM_META, COMMAND_WRITE_USER_RAM, MicroPython 컴파일 등)을 직접 짜야 하고 MVP가 무너진다. **앱은 업로드를 모른다.**

## 중요 전제 / 필수 검증 (1단계 들어가기 전)

> `pybricksdev run ble`는 **RAM 실행 경로**로 보이며, 전원 사이클 후 프로그램이 남지 않을 가능성이 높다.

증거 (`pybricksdev` 2.3.2 소스):

- `connections/pybricks.py:502` — `start_user_program` 독스트링: *"Starts the user program that is already in **RAM** on the hub."*
- 같은 파일의 `download_user_program`은 `WRITE_USER_PROGRAM_META` + `COMMAND_WRITE_USER_RAM`만 쓴다 — **이름 그대로 RAM 적재**

따라서 폰 단독 운용 MVP는 다음 전제에서 시작한다.

- `main.py`는 **Pybricks Code 웹앱**(`https://code.pybricks.com/`)에서 hub의 **slot 0**에 Download 한다 (영구 저장).
- Flutter는 업로드가 아니라 **START_USER_PROGRAM + WRITE_STDIN**만 담당한다.
- 일회성 실행 도구인 `just upload` (= `pybricksdev run ble`)는 폰 단독 운용에 부적합하다 — 노트북 디버그용으로만 쓴다.

### 0.5단계 — 영구 저장 검증 (Flutter 코드 한 줄 짜기 전)

이 검증이 통과해야 Flutter MVP에 의미가 있다. **이걸 먼저 한다.**

1. 노트북 크롬에서 `https://code.pybricks.com/` 열기 → 허브 BLE 연결
2. `pybricks/main.py` 내용을 슬롯 0에 **Download** (Run 아님)
3. 노트북 BLE 연결 끊기 (Pybricks Code 탭 닫거나 Disconnect)
4. 허브 전원 OFF → ON
5. 같은 노트북/다른 폰에서 BLE 다시 붙여 START_USER_PROGRAM 보내기 (Pybricks Code의 ▶ 버튼 또는 nRF Connect 같은 도구로 `0x01 0x00` write)
6. `pybricks/main.py`가 다시 실행되는지 확인 (예: 부팅 직후 `tlm` 텔레메트리 라인이 stdout으로 나오는지)

| 결과 | 다음 액션 |
|---|---|
| ✓ 살아남음 | Flutter MVP 1~5단계 그대로 진행. 본 README 유효. |
| ✗ 못 살아남음 | 폰 단독 모델 재검토. 옵션: (A) `pybricksdev`에 슬롯 download 패치, (B) Flutter에서 다운로드 프로토콜 구현 (난이도 급상승, 비추), (C) ESP32 브리지를 Stage 2로 조기 도입. |

## 노트북과의 BLE 점유 충돌 (먼저 알아둘 것)

Pybricks Hub의 BLE GATT 연결은 동시에 **하나만** 가능하다.

- `just run` 등으로 노트북이 허브에 붙어 있으면 폰은 절대 스캔에 안 잡히거나 connect에서 실패한다.
- 폰에서 BLE 테스트하기 전에 노트북 측 `pybricksdev` / `just run` 프로세스를 **반드시** 종료한다.
- 허브 측 `pybricks/main.py`는 한 번 hub slot에 download되어 있으면 노트북 없이도 START 가능하다. 따라서 운영 흐름은 다음과 같다.
  1. 노트북 크롬에서 Pybricks Code로 `main.py`를 slot 0에 **Download** (위 0.5단계 검증 완료 전제)
  2. 노트북 BLE 끊기 (Pybricks Code 탭 Disconnect 또는 닫기)
  3. 폰 앱 실행 → BLE 스캔 → 연결 → START → stdin write

## 왜 Flutter인가

현재 동작하는 노트북 구조는 다음과 같다.

```text
폰 브라우저 → 노트북 FastAPI/WebSocket → pybricksdev BLE → SPIKE Prime
```

바론이가 혼자 들고 다니려면 노트북이 빠져야 한다.

```text
Flutter 앱(WebView + BLE) → Android BLE → SPIKE Prime
```

Termux는 Python 서버는 가능하지만 BLE가 Android BLE 스택이 아니라 BlueZ/dbus 기대 코드와 충돌할 가능성이 높다. Flutter는 Android BLE 권한과 GATT를 정식 경로로 쓴다.

## 참고할 기존 코드

`/home/junghan/repos/gh/homeagent-config/flutter` 에 Flutter 기반 WebView/BLE 작업이 이미 있다. 단, **클래스를 통째로 이식하지 말고 패턴 스니펫만 가져온다.**

### 통째로 못 가져오는 이유

homeagent의 `lib/ble_relay.dart`는 단순한 BLE 헬퍼가 아니라 **WebSocket 중계 클라이언트**다.

- Flutter가 `ws://host:5581`로 matterjs-server에 붙고
- 서버가 `ble_scan_start` / `ble_connect` / `ble_write` 명령을 WS로 보내면
- Flutter가 Android BLE API로 그걸 수행하고 결과를 다시 WS로 되돌린다

legoagent의 목표는 정반대 — **노트북/서버를 빼고** 폰이 BLE 작업의 주체가 된다. 따라서 `BleRelay` 클래스도, WS 중계 자동 연결을 하는 `_initBleRelay()` 호출이 들어간 `ShellWebView`도 그대로 못 쓴다.

### 가져올 것 (패턴 스니펫 단위)

- `pubspec.yaml` 의존성 — homeagent와 동일 버전 사용 가능
  - `webview_flutter: ^4.13.1`
  - `flutter_blue_plus: ^1.35.0`
  - `web_socket_channel`은 이번 MVP에 **불필요** (WS 중계 안 함)
- `android/app/src/main/AndroidManifest.xml` 권한 블록
  - `BLUETOOTH_SCAN` (`neverForLocation`)
  - `BLUETOOTH_CONNECT`
  - `ACCESS_FINE_LOCATION`
  - `<uses-feature android:name="android.hardware.bluetooth_le" android:required="true"/>` — homeagent는 차량 IVI 타깃이라 `false`지만 legoagent는 폰만 타깃이므로 `true`
  - `BLUETOOTH_ADVERTISE`는 **빼라** — homeagent는 Matter commissioning advertise용이고 legoagent에는 불필요
- `lib/ble_relay.dart`에서 패턴만:
  - 어댑터 상태 체크: `FlutterBluePlus.adapterState.first` (51-58줄)
  - 스캔: `FlutterBluePlus.startScan(withServices: [Guid(...)])` (182-186줄)
  - 연결 시퀀스: `device.connect()` → `requestMtu(247)` → `discoverServices()` → characteristics 검색 → `setNotifyValue(true)` (198-243줄)
  - 쓰기: `characteristic.write(data, withoutResponse: false)` (265줄)
- `lib/shell_webview.dart`에서 패턴만:
  - `WebViewController` 초기화 + `JavaScriptMode.unrestricted` + `loadRequest`
  - **`_initBleRelay()` 호출은 빼라** — 이게 WS 중계를 자동으로 띄우는 부분이다

UUID 차이도 당연히 있다 — Matter는 FFF6, Pybricks는 c5f50001/0002/0003.

## Pybricks BLE 정보

Pybricks Hub BLE service:

```text
service UUID:        c5f50001-8280-46da-89f4-6d8051e4aeef
command/event UUID:  c5f50002-8280-46da-89f4-6d8051e4aeef
capabilities UUID:   c5f50003-8280-46da-89f4-6d8051e4aeef
```

명령 바이트 (`pybricksdev` 소스의 `Command` IntEnum 기준):

```text
0x00 STOP_USER_PROGRAM
0x01 START_USER_PROGRAM
0x03 WRITE_USER_PROGRAM_META   # 업로드용 — Flutter는 안 씀
0x04 COMMAND_WRITE_USER_RAM    # 업로드용 — Flutter는 안 씀
0x06 WRITE_STDIN
```

START_USER_PROGRAM은 허브의 슬롯 지원에 따라 페이로드가 다르다.

```text
구형/슬롯 미지원 허브:  [0x01]
슬롯 지원 허브 (현행):  [0x01, <slot>]   ; 보통 [0x01, 0x00]
```

`pybricksdev`는 capabilities notification에서 `_num_of_slots`를 받아 분기하는데 (`connections/pybricks.py:520-522`), Flutter는 양쪽을 다 시도할 수 있도록 **버튼 두 개**로 두는 게 안전하다.

```text
[Start default] → [0x01]
[Start slot 0]  → [0x01, 0x00]
```

현재 `pybricks/main.py`는 줄 단위 텍스트를 받는다.

예:

```text
drv fwd\n
snd beep 440 200\n
lit 255 0 0\n
```

Flutter에서 stdin에 쓰려면:

```dart
await commandEvent.write(
  [0x06, ...utf8.encode('drv fwd\n')],
  withoutResponse: false,
);
```

사용자 프로그램 시작은 (슬롯 지원 허브 권장 형태):

```dart
await commandEvent.write([0x01, 0x00], withoutResponse: false); // start slot 0
// 폴백: 슬롯 미지원이면 [0x01]
```

단, 첫 MVP에서는 `START_USER_PROGRAM`까지 무리하지 말고 연결/characteristic 탐색까지만 성공해도 된다.

## MVP 단계

### 0. Flutter 프로젝트 생성

이미 `flutter/README.md`가 있으므로 `flutter create flutter`로 디렉토리를 새로 만들면 충돌하거나 README를 덮을 수 있다. 안전한 경로는 디렉토리 안에서 `.`로 생성하는 것이다.

```bash
cd /home/junghan/repos/gh/legoagent-config/flutter
# README.md 백업
cp README.md /tmp/legoagent-flutter-README.md
flutter create --project-name legoagent --org com.legoagent .
# README.md가 덮였으면 복원
cp /tmp/legoagent-flutter-README.md README.md
```

### 1. 의존성 추가

`flutter/pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_blue_plus: ^1.35.0
  webview_flutter: ^4.13.1
```

MVP 연결만 할 거면 WebView는 나중으로 미뤄도 된다.

### 2. Android 권한 추가

`flutter/android/app/src/main/AndroidManifest.xml`에 추가:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-feature android:name="android.hardware.bluetooth_le" android:required="true"/>
```

Android 12+에서는 런타임 권한 요청도 필요할 수 있다. `flutter_blue_plus` 예제와 homeagent 구현을 참고한다.

### 3. BLE 스캔

필터는 Pybricks service UUID:

```dart
final pybricksService = Guid('c5f50001-8280-46da-89f4-6d8051e4aeef');
await FlutterBluePlus.startScan(withServices: [pybricksService]);
```

목표 로그:

```text
Found Pybricks Hub: <device id> <name> RSSI=<n>
```

### 4. GATT 연결

```dart
await device.connect(timeout: const Duration(seconds: 10));
await device.requestMtu(247); // stdin 라인이 패킷 분할 없이 가도록
final services = await device.discoverServices();
```

찾을 characteristic:

```text
c5f50002-8280-46da-89f4-6d8051e4aeef
```

목표 로그:

```text
Connected
Pybricks command/event characteristic found
```

여기까지가 1차 MVP 완료.

### 5. 선택: 프로그램 시작/명령 쓰기

전제: 위 **0.5단계** 가 통과했고, `pybricks/main.py`가 Pybricks Code로 slot 0에 영구 download되어 있다. 노트북 BLE는 끊겨 있다.

Flutter에서:

```dart
// start slot 0 (슬롯 지원 허브 — 현행 SPIKE Prime 펌웨어)
await commandEvent.write([0x01, 0x00], withoutResponse: false);
await Future.delayed(const Duration(milliseconds: 500));
await commandEvent.write(
  [0x06, ...utf8.encode('snd beep 440 200\n')],
  withoutResponse: false,
);
```

성공하면 허브에서 비프음이 난다. 만약 START에서 에러가 나면 슬롯 미지원 폴백으로 `[0x01]`만 보내는 버튼을 같이 둔다.

## 최종 목표 구조

1차 MVP 이후:

```text
Flutter
 ├─ BLE controller: Pybricks service connect/write/notify
 └─ WebView: 기존 android/controller.html 재사용
      send(line) → JavascriptChannel → BLE WRITE_STDIN
```

기존 HTML의 `send(line)`를 다음처럼 바꿀 수 있다.

```js
function send(line) {
  LegoBle.postMessage(line);
  logLine('→ ' + line, 'in');
}
```

Flutter 쪽은 `JavascriptChannel(name: 'LegoBle', onMessageReceived: ...)`에서 받아 BLE로 쓴다.

## Claude에게 맡길 작업 단위

0. **0.5단계 검증** — Pybricks Code로 slot 0 download → 전원 사이클 → START 살아남는지 확인. 이 게이트를 통과해야 1번부터 의미 있다.
1. `flutter create --project-name legoagent --org com.legoagent .` 후 homeagent의 최소 설정 이식
2. `flutter_blue_plus`로 Pybricks service scan 화면 만들기
3. device connect + `requestMtu(247)` + services discovery + command/event characteristic 찾기
4. 연결 상태를 화면에 크게 표시
5. 선택 작업: `[0x01, 0x00]` START + `[0x01]` 폴백 버튼, `snd beep 440 200` write 테스트
6. 이후 WebView로 기존 `android/controller.html` 포팅

## 성공 기준

MVP 성공 기준은 세 가지다.

- 앱에서 Pybricks Hub가 보인다.
- 앱에서 Hub에 연결된다.
- `c5f50002-8280-46da-89f4-6d8051e4aeef` characteristic을 찾는다.

선택 성공 기준:

- 앱 버튼을 누르면 허브가 `snd beep 440 200`에 반응한다.

## 주의

- Flutter 앱은 **업로드를 모른다.** `main.py`를 hub slot에 영구 저장하는 책임은 Pybricks Code 웹앱의 것이다.
- `just upload` (= `pybricksdev run ble`)는 RAM 적재 + 즉시 실행이라 노트북 디버그용이다. 폰 단독 운용 검증에 쓰면 안 된다.
- 앱은 "이미 슬롯에 깔린 Pybricks 프로그램을 시작하고 stdin 명령을 보내는 리모컨"으로 시작한다.
- Pybricks stdout/notify 파싱은 후순위다. 먼저 write path를 살린다.
- **노트북 BLE를 끊고 폰을 붙인다.** 동시 GATT 연결은 안 된다 (위 "노트북과의 BLE 점유 충돌" 섹션 참조).
- homeagent의 `BleRelay` 클래스를 통째로 import하지 않는다 — WS 중계 패턴이라 legoagent의 "직접 BLE" 모델과 맞지 않는다.
- START_USER_PROGRAM은 슬롯 허브에서 `[0x01, slot]` 2바이트가 정식이다. 단순 `[0x01]`은 폴백.
