# legoagent Flutter MVP 계획

목표: 노트북 없이 안드로이드폰 하나가 LEGO SPIKE Prime 허브에 BLE로 직접 붙는지 검증한다.

이번 MVP는 **주행 제어가 아니다.** 우선순위는 오직 다음 한 줄이다.

> Flutter 앱에서 Pybricks Hub를 스캔하고, 연결하고, Command/Event characteristic에 접근한다.

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

`/home/junghan/repos/gh/homeagent-config/flutter` 에 이미 Flutter 기반 WebView/BLE 작업이 있다.

가져올 것:

- `pubspec.yaml`
  - `webview_flutter`
  - `flutter_blue_plus`
  - `web_socket_channel`은 이번 MVP에는 필수 아님
- `android/app/src/main/AndroidManifest.xml`
  - `BLUETOOTH_SCAN`
  - `BLUETOOTH_CONNECT`
  - `ACCESS_FINE_LOCATION`
  - `android.hardware.bluetooth_le`
- `lib/shell_webview.dart` 구조
- `lib/ble_relay.dart`의 스캔/연결/characteristic 탐색 패턴

주의: homeagent의 `ble_relay.dart`는 Matter FFF6 서비스용이다. legoagent에서는 Pybricks UUID로 바꿔야 한다.

## Pybricks BLE 정보

Pybricks Hub BLE service:

```text
service UUID:        c5f50001-8280-46da-89f4-6d8051e4aeef
command/event UUID:  c5f50002-8280-46da-89f4-6d8051e4aeef
capabilities UUID:   c5f50003-8280-46da-89f4-6d8051e4aeef
```

명령 바이트:

```text
0x01 START_USER_PROGRAM
0x06 WRITE_STDIN
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

사용자 프로그램 시작은:

```dart
await commandEvent.write([0x01], withoutResponse: false);
```

단, 첫 MVP에서는 `START_USER_PROGRAM`까지 무리하지 말고 연결/characteristic 탐색까지만 성공해도 된다.

## MVP 단계

### 0. Flutter 프로젝트 생성

이 폴더에서 새 Flutter 앱을 만든다.

```bash
cd /home/junghan/repos/gh/legoagent-config
flutter create flutter
```

이미 `flutter/README.md`가 있으므로 생성 후 보존하거나 다시 복사한다.

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

허브에 `pybricks/main.py`가 이미 올라가 있어야 한다. 처음 업로드는 노트북에서 한다.

```bash
just run
# 또는
just upload pybricks/main.py
```

Flutter에서:

```dart
await commandEvent.write([0x01], withoutResponse: false); // start user program
await Future.delayed(const Duration(milliseconds: 500));
await commandEvent.write([0x06, ...utf8.encode('snd beep 440 200\n')], withoutResponse: false);
```

성공하면 허브에서 비프음이 난다.

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

1. `flutter create flutter` 후 homeagent의 최소 설정 이식
2. `flutter_blue_plus`로 Pybricks service scan 화면 만들기
3. device connect + services discovery + command/event characteristic 찾기
4. 연결 상태를 화면에 크게 표시
5. 선택 작업: `START_USER_PROGRAM`, `snd beep 440 200` write 테스트
6. 이후 WebView로 기존 `android/controller.html` 포팅

## 성공 기준

MVP 성공 기준은 세 가지다.

- 앱에서 Pybricks Hub가 보인다.
- 앱에서 Hub에 연결된다.
- `c5f50002-8280-46da-89f4-6d8051e4aeef` characteristic을 찾는다.

선택 성공 기준:

- 앱 버튼을 누르면 허브가 `snd beep 440 200`에 반응한다.

## 주의

- Flutter 앱은 처음부터 `main.py` 업로드까지 담당하지 않는다.
- 업로드는 당분간 노트북/pybricksdev로 한다.
- 앱은 “이미 올라간 Pybricks 프로그램을 시작하고 stdin 명령을 보내는 리모컨”으로 시작한다.
- Pybricks stdout/notify 파싱은 후순위다. 먼저 write path를 살린다.
