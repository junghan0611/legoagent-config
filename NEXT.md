# NEXT — legoagent-config

> 휘발성 후속. 지금 시점에 알고 있는 다음 한 걸음.
> 영속할 사실은 README / INVARIANTS / commit history 로 옮긴다.

# RAIL — 현재 좌표

- [x] **1. Stage 1 RC car** — 폰 단독 Flutter 앱 ↔ BLE ↔ SPIKE 허브 (노트북 불필요)
- [x] **2. 앱 다듬기** — UI declutter, elevator 탭, 다크모드
- [ ] **3. 리모컨 개편** ← CURRENT: Terra 형제 형성 → 화면/허브 경계 확정
- [ ] **4. 허브·폰 반영 / 실물 확인** — A 모터 포함, 피아노·메시지·운전 정지 확인
- [ ] **5. 여러 몸 / WiFi 영상 → 차체 합체** — 이번 리모컨 개편 뒤에 재개

현재 좌표: 2 완료 → 3 요구 정리 / 구현 전 → 4 실물 게이트 → 5 대기

# NOW

- 요구 원문: GLG의 2026-11-08 현재 세션 요청 — (1) 별도 탭 도레미파솔라시도 피아노,
  (2) 직접 입력한 글을 허브에서 슬라이드처럼 표시(예: "엄마 사랑해"),
  (3) A 모터 제어 유지, (4) 연결 뒤 첫 화면은 스크롤 없이 누르는 리모컨 중심.
  Claude 쿼터 대신 Terra 사용 요청. GLG는 11-08 기존 앱을 먼저 사용한다고 보고.
- 원본 사진: `/home/junghan/screenshot/Screenshot_20261108_170004_Gallery.jpg`,
  `/home/junghan/screenshot/20261108T165500--baron-lego-design.png`.
  로컬 축소 읽기본 `/tmp/lego-car.jpg`, `/tmp/lego-design.jpg` (일시 파일).
- Next: Terra 둘을 앱/허브 후보로 형성하고 원문·INVARIANTS를 읽힌다.
  구현 전 한글 5×5 표현 가능성, 표시/소리가 stop 처리를 막지 않는 프로토콜을 확정한다.
  제안 역할: 앱 화면/위젯 테스트 한 명, 허브 명령/비차단 처리/테스트 한 명; 부모가 통합.
  형제는 형성 보고 뒤 대기. GLG는 요구 정리 커밋과 작업 준비를 요청했다.
  push 및 실물 모터 실행은 요청되지 않았다.
- 이전 구현: A 포트에 새 모터가 달렸다. 코드는 들어갔다 (`main.py` `aux lft|rgt|stp`,
  앱 Drive 탭 방향표 위 "A 모터" ◀ ▶ 데드맨, 비상정지에 `aux stp` 포함).
  analyze / test / debug APK 빌드 통과(11-03 기록). **폰 설치 완료(11-08), 허브 반영 미확인.**
- 개편 뒤 실물 반영 순서:
  1. 노트북 크롬 `https://code.pybricks.com` → 허브 연결 → `pybricks/main.py`를
     slot 0에 **Download** (Run 아님) → Pybricks Code 연결 끊기
  2. `cd flutter && nix develop ..#flutter --command flutter build apk --debug`
     → `adb install -r build/app/outputs/flutter-apk/app-debug.apk`
  3. 앱에서 Start slot 0 → A ◀/▶ 누름=돎, 뗌=멈춤 확인. 반대로 돌면 `main.py`
     `AUX_DIR = -1` 후 다시 Download.
- Verify: 허브 응답 `ok aux lft` (설정 시트 ↩ 라인). `? aux lft`면 옛 main.py
  그대로 — 1번 Download가 안 된 것. `err aux missing`이면 A에 모터 인식 안 됨.
- 설치 확인(2026-11-08): adb에서 SM_G977N 연결 확인. 11-03 20:43 빌드된 기존
  `flutter/build/app/outputs/flutter-apk/app-debug.apk`를 `adb install -r`로 설치 성공,
  앱 실행 명령 성공(백그라운드 작업 #123, exit 0). 새 요구 기능은 아직 미구현.
- 미검증: 허브 5×5 LED 한글 가독성/지원, 현재 허브에 저장된 main.py 버전.
- Do not touch: 앱에서 업로드 시도 금지 (INVARIANTS D-8). 새 연속 동작 버튼은
  onTapUp/onTapCancel 둘 다 stop (D-1).

# RECENT

- [2026-11-03] A 모터 좌우 버튼 추가 (코드만, 허브/폰 미반영).
- [2026-06-13] 다크모드 토글 (`15d37f0`).
- [2026-05-29] 단일 앱 멀티바디 방향 확정 (`09c67d9`).

# LEDGER — 확정된 방향: 앱 하나가 여러 몸을 받아낸다

```text
legoagent (Flutter 앱, 폰 하나)
 ├─ BLE  → SPIKE Prime 허브   = 몸 (주행/모터/IMU)
 └─ WiFi → ESP32 / M5GO       = 감각·표정·눈 (카메라/소리/화면/RGB)
```

- 몸체를 늘려도 **앱은 하나**. 전송로(BLE/WiFi)가 둘이어도 인터페이스는 하나.
- SPIKE 허브에 다 우겨넣지 않는다(README 비목표). 카메라/소리/표정은 ESP32 쪽.
- M5GO 케이스가 8mm 레고 호환 → 감각 두뇌를 레고로 차체에 마운트, 무선 브리지로
  붙는다 (GROVE ≠ LEGO Powered Up 커넥터).

| 모델 | 정체 | 역할 |
|---|---|---|
| **M5GO v2.7** | ESP32 + 2" IPS + IMU + 마이크 + 스피커 + RGB×10. 카메라 없음 | 표정/소리/IMU 두뇌 |
| **TimerCamera X** | ESP32 + OV3660 3MP + 8MB PSRAM + WiFi 영상 | 눈 (카메라) |
| Unit-CAM / M5Camera / ESP32-CAM | 같은 GROVE 계열 ESP32 카메라 | 눈 대안 |

모두 ESP32 + WiFi 영상 → 앱은 **MJPEG/HTTP 스트림 한 경로**로 받는다.
ESP32/M5Stack 맥락은 edgeagent-config 쪽에도 있다.

병행 과제: Flutter 탭 허브측 채우기 — Display / Sound / Light / IMU / Hub 는 UI
골격뿐. `pybricks/main.py` 파서에 `disp/snd/lit/tlm imu` 보강.

## 메모

- 누르면 응답이 온다 — 자동 폴링 금지 (INVARIANTS D-10). 영상 스트림도 "보기 탭을
  열었을 때" 시작, 백그라운드 상시 스트림 없음.
- 폰 BLE 테스트 전 노트북 `just run` / `pybricksdev` / Pybricks Code 연결 반드시
  종료 (GATT 단일 점유).
- 새 기능 짜기 전 INVARIANTS.md 먼저 읽기.
