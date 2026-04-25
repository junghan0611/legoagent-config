"""
4바퀴 방향 맞추기 검사 스크립트.

이 스크립트를 허브에 올리면 A → B → C → D 순서로 각 모터를 1초씩 정방향(+) 회전시킨다.
바퀴가 *차 앞쪽*으로 굴러가면 그 포트는 그대로 두면 되고,
뒤로 굴러가면 main.py 에서 `Direction.COUNTERCLOCKWISE` 로 바꾼다.

사용:
  pybricksdev run usb pybricks/calibrate.py

각 모터 사이에 1초 정지 — 어느 바퀴인지 눈으로 따라가기 좋은 간격.
"""

from pybricks.pupdevices import Motor
from pybricks.parameters import Port
from pybricks.tools import wait
from usys import stdout

PORTS_TO_TEST = [Port.A, Port.B, Port.C, Port.D]
SPEED = 300   # deg/s — 천천히. 바닥에 닿아 있으면 차가 살짝 움직일 수 있으니 주의
DURATION = 1000  # ms

for port in PORTS_TO_TEST:
    name = str(port).split(".")[-1]
    stdout.buffer.write(b"port=" + name.encode() + b" run+\n")
    try:
        m = Motor(port)            # 기본 Direction.CLOCKWISE
        m.run(SPEED)
        wait(DURATION)
        m.brake()
        stdout.buffer.write(b"port=" + name.encode() + b" done\n")
    except OSError as e:
        # 포트에 모터가 없거나 다른 종류
        stdout.buffer.write(b"port=" + name.encode() + b" skip:" + str(e).encode() + b"\n")
    wait(1000)

stdout.buffer.write(b"calibrate done\n")
