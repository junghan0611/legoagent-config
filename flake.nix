{
  description = "legoagent-config — 레고 탈을 쓴 에이전트 (RC car MVP)";

  inputs = {
    # homeagent-config와 동일 핀 — Flutter 3.38.3 보장 (양쪽 앱 호환성)
    nixpkgs.url = "github:NixOS/nixpkgs/e576e3c9cf9b";
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

        # Android SDK (Flutter APK 빌드용) — homeagent-config flake.nix 참조
        # 라이센스 명시 수락.
        # NDK 28.2.13676358은 Flutter 3.38.3 기본값. nixpkgs androidSdk는 read-only라
        # Gradle 자동 설치가 실패하므로 여기서 미리 박는다.
        androidEnv = pkgs.androidenv.override { licenseAccepted = true; };
        androidComposition = androidEnv.composeAndroidPackages {
          buildToolsVersions = [ "34.0.0" "35.0.0" "36.0.0" ];
          platformVersions = [ "34" "35" "36" ];
          includeNDK = true;
          ndkVersions = [ "28.2.13676358" ];
          cmakeVersions = [ "3.22.1" ];
          includeEmulator = false;
          includeSystemImages = false;
        };
        androidSdk = androidComposition.androidsdk;
      in
      {
        # 기본 셸 — 노트북 ↔ 허브 BLE (Day 1 검증 환경)
        # 폰 단독 운용 검증, Pybricks Code 다운로드 흐름은 이 셸에서 진행
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
            echo "  Flutter APK 작업:  cd flutter  (자동 진입) 또는 nix develop .#flutter"
            echo ""
          '';
        };

        # Flutter APK 빌드 셸 — flutter/.envrc로 자동 진입
        # 폰 단독 운용 (노트북 빠진 모델). Pybricks Code = 설치, Flutter = 리모컨.
        devShells.flutter = pkgs.mkShell {
          name = "legoagent-flutter";

          packages = with pkgs; [
            flutter      # Flutter SDK 3.38.3 (homeagent와 동일)
            androidSdk   # Android SDK 34/35
            jdk17        # Gradle 빌드용 JDK
            just git
            ripgrep fd jq
          ];

          ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
          ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
          JAVA_HOME = pkgs.jdk17.home;
          # NixOS aapt2 호환 — Gradle이 Maven 다운로드 대신 nix store aapt2 사용
          GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${androidSdk}/libexec/android-sdk/build-tools/36.0.0/aapt2";

          shellHook = ''
            echo ""
            echo "  legoagent-flutter — Pybricks Hub 폰 BLE 리모컨 빌드"
            echo "  Flutter:        $(${pkgs.flutter}/bin/flutter --version --machine 2>/dev/null \
              | ${pkgs.jq}/bin/jq -r '.frameworkVersion' 2>/dev/null || echo unknown)"
            echo "  ANDROID_HOME:   $ANDROID_HOME"
            echo "  JAVA_HOME:      $JAVA_HOME"
            echo ""
            echo "  앱 생성 (한 번):  flutter create --project-name legoagent --org com.legoagent ."
            echo "  디버그 빌드:     flutter build apk --debug"
            echo "  폰 설치:         adb install -r build/app/outputs/flutter-apk/app-debug.apk"
            echo "  핫리로드:        flutter run -d <device-id>"
            echo ""
            echo "  주의: NixOS adb USB는 system-level programs.adb.enable 필요."
            echo "        대안 — 무선 디버깅(adb pair) 또는 APK 수동 전송."
            echo ""
          '';
        };
      });
}
