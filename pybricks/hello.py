"""
모터 없이 허브 단독 테스트 — 펌웨어/BLE 통합 확인용
  just hello
"""

from pybricks.hubs import PrimeHub
from pybricks.tools import wait

hub = PrimeHub()

hub.display.text("HI")
hub.speaker.beep(440, 150)
wait(120)
hub.speaker.beep(660, 150)
wait(120)
hub.speaker.beep(880, 200)

hub.display.icon([
    [0, 100,   0, 100, 0],
    [0,   0,   0,   0, 0],
    [0,   0,   0,   0, 0],
    [100, 0,   0,   0, 100],
    [0, 100, 100, 100, 0],
])

wait(1500)
