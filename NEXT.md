# NEXT — legoagent-config

> 휘발성 후속. 지금 시점에 알고 있는 다음 한 걸음.
> 영속할 사실은 README / INVARIANTS / commit history 로 옮긴다.

## 지금 어디까지 왔나 (2026-05-29)

- **Stage 1 (RC car) 닫힘** — 폰 단독 Flutter 앱이 BLE로 SPIKE Prime 허브를
  스캔/연결하고 slot 0 프로그램을 START + WRITE_STDIN으로 제어한다. 노트북 불필요.
- Flutter UI declutter 완료(최소 AppBar, 전용 탭). elevator 탭 추가 + 차속 상향.
- Baron elevator hoist v1 기록됨 (모터 직결 줄감기).

## 확정된 방향 — 앱 하나가 여러 몸을 받아낸다

레고에이전트의 다음 진화는 **단일 Flutter 앱 = 멀티바디 컨트롤러**다.

```text
legoagent (Flutter 앱, 폰 하나)
 ├─ BLE  → SPIKE Prime 허브   = 몸 (주행/모터/IMU)
 └─ WiFi → ESP32 / M5GO       = 감각·표정·눈 (카메라/소리/화면/RGB)
```

- 몸체를 늘려도 **앱은 하나**다. 아이는 같은 앱에서 자동차도 부르고, 눈으로
  앞도 본다. 전송로(BLE/WiFi)가 둘이어도 인터페이스는 하나여야 한다.
- SPIKE 허브에 다 우겨넣지 않는다(README 비목표). 카메라/소리/표정은 ESP32 쪽.
- 물리: M5GO 케이스가 8mm 레고 호환 → 감각 두뇌를 **레고로 차체에 마운트**.
  케이블 직결이 아니라 무선 브리지로 붙는다 (GROVE ≠ LEGO Powered Up 커넥터).

### 검토 끝난 하드웨어 (2026-05-29)

| 모델 | 정체 | 우리 역할 |
|---|---|---|
| **M5GO v2.7** | ESP32 + 2" IPS + IMU + 마이크 + 1W 스피커 + RGB×10 + 배터리. 카메라 없음 | 표정/소리/IMU 두뇌 |
| **TimerCamera X** | ESP32 + OV3660 3MP + 8MB PSRAM + WiFi 영상 + GROVE 출력 | 눈 (Stage 2 카메라) |
| Unit-CAM / M5Camera / ESP32-CAM | 같은 GROVE 계열 ESP32 카메라 | 눈 대안 |

모두 ESP32 + WiFi 영상이라 앱은 **MJPEG/HTTP 스트림 한 경로**로 다 받아낼 수 있다.

## 다음 한 걸음 (순서)

1. **앱에 "몸 목록" 개념 도입** — 지금은 BLE 단일 허브 가정. 연결 대상을 추상화해
   BLE 몸(SPIKE)과 WiFi 몸(ESP32 카메라)을 같은 화면에서 다루는 골격부터.
2. **WiFi 영상 탭** — TimerCamera X 한 대를 WiFi에 올리고 앱에서 MJPEG 스트림 보기.
   (카메라 펌웨어는 M5Stack CameraTool/예제 그대로, 우리는 앱에서 받기만)
3. **Flutter 탭 허브측 채우기** (병행) — Display / Sound / Light / IMU / Hub 는 아직
   UI 골격뿐. `pybricks/main.py` 라인 파서에 `disp/snd/lit/tlm imu` 추가.
4. 그다음 — 카메라를 SPIKE 차체에 레고로 마운트해서 "부르면 오고, 앞을 보는" 첫 합체.

## 메모

- 누르면 응답이 온다 원칙 유지 — 자동 폴링 금지 (INVARIANTS.md). 영상 스트림도
  "보기 탭을 열었을 때" 시작하고, 백그라운드 상시 스트림은 두지 않는다.
- 폰 BLE 테스트 전 노트북 `just run` / `pybricksdev` 프로세스 반드시 종료 (GATT 단일 점유).
- 새 기능 짜기 전 INVARIANTS.md 먼저 읽기.
</content>
</invoke>
