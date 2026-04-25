{
  description = "legoagent-config — 레고 탈을 쓴 에이전트 (RC car MVP)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        # SPIKE Prime BLE 통신 + 로컬 웹 서버에 필요한 Python 묶음
        # pybricksdev는 nixpkgs에 없어 shellHook에서 venv로 설치
        python = pkgs.python3.withPackages (ps: with ps; [
          bleak        # BLE 클라이언트 (SPIKE 허브)
          fastapi      # 로컬 컨트롤 서버
          uvicorn      # ASGI 런너
          websockets   # 폰 ↔ 노트북 실시간 조종 채널
          jinja2       # 미니 HTML
          pip
        ]);
      in
      {
        devShells.default = pkgs.mkShell {
          name = "legoagent";

          packages = with pkgs; [
            python
            just         # 태스크 러너
            git
            ripgrep fd   # 검색
            jq           # 응답 디버깅
            bluez        # bluetoothctl — 허브 페어링/스캔 확인용
            libusb1      # pybricksdev USB backend (PyUSB)
            dfu-util     # SPIKE Prime DFU 모드 펌웨어 플래시
          ];

          shellHook = ''
            # 프로젝트 venv — pybricksdev (PyPI only) 격리 설치
            if [ ! -d .venv ]; then
              echo "[legoagent] .venv 부트스트랩 — pybricksdev 설치"
              ${python}/bin/python -m venv .venv --system-site-packages
              .venv/bin/pip install --quiet --upgrade pip
              .venv/bin/pip install --quiet pybricksdev
            fi
            export PATH="$PWD/.venv/bin:$PATH"
            export LD_LIBRARY_PATH="${pkgs.libusb1}/lib:${pkgs.stdenv.cc.cc.lib}/lib:$LD_LIBRARY_PATH"

            HOST_IP=$(${pkgs.iproute2}/bin/ip -4 -o route get 1.1.1.1 2>/dev/null \
              | awk '{print $7}' | head -1)

            echo ""
            echo "  legoagent — 오늘의 MVP"
            echo "  허브 연결:  pybricksdev run ble pybricks/main.py"
            echo "  허브 스캔:  pybricksdev ble"
            echo "  로컬 서버:  python -m uvicorn android.server:app --host 0.0.0.0 --port 8888"
            echo "  폰 접속:    http://''${HOST_IP:-<host-ip>}:8888"
            echo ""
            echo "  BLE 권한이 안 잡히면 → systemctl --user status, bluetoothctl power on"
            echo ""
          '';
        };
      });
}
