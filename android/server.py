"""
legoagent — 노트북 BLE 브리지 + 폰 컨트롤러 (FastAPI 단일 포트)

- /             : 폰 브라우저 컨트롤러 (controller.html)
- /ws           : 폰 ↔ 서버 실시간 채널 (텍스트 명령)
- /healthz      : 허브 연결 상태

서버는 BLE 한 채널로 허브를 들고 있고, 다수의 폰이 WS로 붙어 동일 허브를 공유.

실행 (반드시 venv 파이썬 — system uvicorn 바이너리는 venv 패키지 못 봄):
  python -m uvicorn android.server:app --host 0.0.0.0 --port 8888

처음엔 허브 미연결 상태로도 뜸 (UI 검증 가능). 허브 굴릴 땐:
  HUB_NAME=Pybricks_xxx python -m uvicorn android.server:app --host 0.0.0.0 --port 8888
"""

from __future__ import annotations

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse
from pybricksdev.ble import find_device
from pybricksdev.connections.pybricks import PybricksHubBLE

log = logging.getLogger("legoagent")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")

HERE = Path(__file__).parent
PROJECT_ROOT = HERE.parent

HUB_NAME = os.getenv("HUB_NAME")  # None이면 첫 발견된 Pybricks 허브
# 기본값을 1로 변경 — 노트북 단일 흐름에서 항상 자동 연결
AUTOCONNECT = os.getenv("LEGOAGENT_AUTOCONNECT", "1") == "1"
# 허브에 자동 업로드/실행할 프로그램. 빈 문자열이면 업로드 스킵 (수동 버튼 실행)
PROGRAM = os.getenv("LEGOAGENT_PROGRAM", str(PROJECT_ROOT / "pybricks" / "main.py"))


class HubBridge:
    """노트북-허브 BLE 연결을 들고 있는 단일 객체."""

    def __init__(self) -> None:
        self.hub: PybricksHubBLE | None = None
        self.lock = asyncio.Lock()
        self.run_task: asyncio.Task | None = None

    async def connect(self) -> None:
        device = await find_device(name=HUB_NAME)
        hub = PybricksHubBLE(device)
        await hub.connect()
        self.hub = hub
        log.info("hub connected: %s", device)

        if PROGRAM and Path(PROGRAM).exists():
            log.info("auto-uploading program: %s", PROGRAM)
            # hub.run은 wait=True 시 프로그램 종료까지 블로킹. 백그라운드 태스크로 굴린다.
            # line_handler=True: pybricksdev이 hub stdout(\r\n EOL)을 라인으로 분리해서 print.
            # print_output=True: 분리된 라인을 sys.stdout에 echo. (server console에서 hub의 ok/err/tlm 보임)
            # 키보드 stdin forwarding은 호출자(pybricksdev CLI)에만 있는 거고, lib 레벨에선 끼지 않음.
            self.run_task = asyncio.create_task(
                hub.run(PROGRAM, wait=True, print_output=True, line_handler=True),
                name="hub-program",
            )
            # 프로그램 시작 직후 stdin 채널이 안정될 때까지 살짝 대기
            await asyncio.sleep(0.5)

    async def disconnect(self) -> None:
        if self.run_task and not self.run_task.done():
            try:
                if self.hub is not None:
                    await self.hub.stop_user_program()
            except Exception as e:
                log.warning("stop_user_program: %s", e)
            self.run_task.cancel()
            try:
                await self.run_task
            except (asyncio.CancelledError, Exception):
                pass
            self.run_task = None
        if self.hub:
            try:
                await self.hub.disconnect()
            finally:
                self.hub = None

    async def send(self, line: str) -> None:
        """허브 stdin으로 한 줄 명령 전달. UI 설계 단계에서는 hub가 None이어도 NOP."""
        if self.hub is None:
            return
        data = (line.rstrip("\n") + "\n").encode()
        async with self.lock:
            await self.hub.write(data)


bridge = HubBridge()


@asynccontextmanager
async def lifespan(app: FastAPI):
    if AUTOCONNECT:
        try:
            await bridge.connect()
        except Exception as e:
            log.warning("autoconnect failed: %s", e)
    else:
        log.info("UI design mode — BLE not connected. POST /api/connect 또는 LEGOAGENT_AUTOCONNECT=1")
        log.info("프로그램 자동 업로드 비활성: LEGOAGENT_PROGRAM='' 또는 위 환경변수")
    yield
    await bridge.disconnect()


app = FastAPI(lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> JSONResponse:
    return JSONResponse({"hub_connected": bridge.hub is not None})


@app.post("/api/connect")
async def api_connect() -> JSONResponse:
    if bridge.hub is not None:
        return JSONResponse({"ok": True, "already": True})
    try:
        await bridge.connect()
        return JSONResponse({"ok": True})
    except Exception as e:
        return JSONResponse({"ok": False, "error": str(e)}, status_code=503)


@app.post("/api/disconnect")
async def api_disconnect() -> JSONResponse:
    await bridge.disconnect()
    return JSONResponse({"ok": True})


@app.get("/")
async def index() -> HTMLResponse:
    return HTMLResponse((HERE / "controller.html").read_text(encoding="utf-8"))


@app.websocket("/ws")
async def ws(ws: WebSocket) -> None:
    """폰 ↔ 서버 라인 프로토콜.

    클라이언트 → 서버 (UI에서 보내는 라인):
        drv fwd|rev|lft|rgt|stp
        mot <port:A-F> <speed:int>            # run at speed (deg/s)
        mot <port> stop|brake|hold
        mot <port> angle <deg> <speed>        # run by angle
        dsp icon <NAME>                       # ICON 상수명
        dsp pixel <row:0-4> <col:0-4> <0-100>
        dsp text <message>
        dsp clear
        lit <r:0-255> <g> <b>                 # hub light
        snd beep <freq:hz> <ms>
        snd note <note:str> <ms>              # e.g. C4 D#5
        imu                                   # 요청 (응답: imu pitch=.. roll=.. yaw=..)
        bat                                   # 요청 (응답: bat <%>)
        sub <topic>                           # 텔레메트리 구독
        raw <line>                            # 임의 라인 그대로 hub stdin

    서버 → 클라이언트:
        ok <원래 라인>
        err <메세지>
        log <텍스트>          # 허브 stdout 등
        tlm <topic> <kv...>   # 텔레메트리
    """
    await ws.accept()
    log.info("ws client connected")
    try:
        while True:
            line = (await ws.receive_text()).strip()
            if not line:
                continue
            try:
                # UI 설계 단계: 그대로 허브로 흘리고 ack. 허브 미연결이면 NOP.
                await bridge.send(line)
                await ws.send_text(f"ok {line}")
            except Exception as e:
                await ws.send_text(f"err {e}")
    except WebSocketDisconnect:
        log.info("ws client disconnected")
