"""
legoagent — 허브 측 프로그램 (SPIKE Prime / Pybricks)

PC가 BLE NUS로 보내는 3바이트 커맨드를 stdin에서 읽어 모터를 돌린다.
PC 측 프로토콜과 짝을 이룬다 (../android/server.py).

업로드:
  pybricksdev run usb pybricks/main.py     # 케이블 검증
  pybricksdev run ble pybricks/main.py     # 차 굴릴 때
"""

from pybricks.pupdevices import Motor
from pybricks.parameters import Port, Direction
from pybricks.tools import wait
from usys import stdin, stdout
from uselect import poll

# TODO: 실제 차체에 맞춰 포트/방향 조정
LEFT = Motor(Port.A, Direction.COUNTERCLOCKWISE)
RIGHT = Motor(Port.B, Direction.CLOCKWISE)

SPEED = 500   # deg/s — 일단 보수적
TURN = 300

p = poll()
p.register(stdin)

stdout.buffer.write(b"rdy\n")

while True:
    p.poll()
    cmd = stdin.buffer.read(3)
    if cmd is None or len(cmd) < 3:
        continue

    if cmd == b"fwd":
        LEFT.run(SPEED); RIGHT.run(SPEED)
    elif cmd == b"rev":
        LEFT.run(-SPEED); RIGHT.run(-SPEED)
    elif cmd == b"lft":
        LEFT.run(-TURN); RIGHT.run(TURN)
    elif cmd == b"rgt":
        LEFT.run(TURN); RIGHT.run(-TURN)
    elif cmd == b"stp":
        LEFT.brake(); RIGHT.brake()
    elif cmd == b"bye":
        LEFT.brake(); RIGHT.brake()
        break
    else:
        stdout.buffer.write(b"?:" + cmd + b"\n")
        continue

    stdout.buffer.write(b"ok:" + cmd + b"\n")
