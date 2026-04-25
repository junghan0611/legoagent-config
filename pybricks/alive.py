"""연결 검증 — stdout + 허브 라이트 빨강 3초.
LED가 빨강으로 켜지면 program 시작 OK (stdout 채널 무관).
터미널에 L1/L2/L3 줄도 보이면 stdout 채널까지 OK.
"""

from pybricks.hubs import PrimeHub
from pybricks.parameters import Color
from pybricks.tools import wait
from usys import stdout

stdout.buffer.write(b"L1 boot\r\n")
hub = PrimeHub()
hub.light.on(Color.RED)
stdout.buffer.write(b"L2 light_on\r\n")
wait(3000)
hub.light.off()
stdout.buffer.write(b"L3 done\r\n")
