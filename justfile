FIRMWARE := "firmware/pybricks-primehub-v3.6.1.zip"
PROGRAM := "pybricks/main.py"
HOST_IP := `ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -1`

default:
    @just --list

# udev 규칙 임시 설치 (재부팅까지 유지) — NixOS에서 /etc는 read-only라 /run에 넣음
udev-install:
    sudo mkdir -p /run/udev/rules.d
    sudo cp etc/99-pybricks.rules /run/udev/rules.d/99-pybricks.rules
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    @echo "→ USB 케이블 뽑았다 다시 꽂으세요. 그러면 권한이 새 규칙으로 적용됩니다."

# 펌웨어 플래시 (DFU 모드 허브 필요)
flash:
    pybricksdev flash {{FIRMWARE}}

# BLE 스캔 (bluetoothctl 5초)
scan:
    bluetoothctl --timeout 5 scan on

# BT 어댑터 stuck 풀기 (LE scan IO error 시)
bt-reset:
    sudo systemctl restart bluetooth
    sleep 1
    @echo "→ BT 재시작됨. 허브 한 번 껐다 켜고 다시 just run"

# 풀 스택: 서버 + 허브 BLE + main.py 자동 업로드/실행
# 노트북 브라우저: http://localhost:8888  (또는 폰: http://{{HOST_IP}}:8888)
run program=PROGRAM:
    @echo "→ http://localhost:8888  /  http://{{HOST_IP}}:8888"
    LEGOAGENT_AUTOCONNECT=1 LEGOAGENT_PROGRAM={{program}} \
        python -m uvicorn android.server:app --host 0.0.0.0 --port 8888

# 허브에 .py 직접 업로드+실행 (서버 없이, 디버그용)
upload script=PROGRAM:
    pybricksdev run ble {{script}}

# 채널 검증 — 허브에서 단순 stdout 한 줄. ALIVE/BYE 두 줄 보이면 연결 OK
alive:
    pybricksdev run ble pybricks/alive.py

# 모터 없이 허브 단독 테스트 — 디스플레이 + 부저
hello:
    pybricksdev run ble pybricks/hello.py

# B/F 모터 단독 스모크 테스트 — 서버/UI 없이 바퀴가 도는지 먼저 확인
smoke-motor:
    pybricksdev run ble pybricks/smoke_motor_bf.py

# 서버만 (자동 연결 OFF) — UI 디자인 단계
server-only:
    LEGOAGENT_AUTOCONNECT=0 LEGOAGENT_PROGRAM= \
        python -m uvicorn android.server:app --host 0.0.0.0 --port 8888

firmware-download version="3.6.1":
    mkdir -p firmware
    curl -sL -o firmware/pybricks-primehub-v{{version}}.zip \
        https://github.com/pybricks/pybricks-micropython/releases/download/v{{version}}/pybricks-primehub-v{{version}}.zip

usb-info:
    lsusb | grep -i lego || echo "허브가 USB로 잡히지 않습니다 (DFU 모드 진입: 전원 6초 누르기)"
