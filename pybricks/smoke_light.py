"""smoke test — 허브 라이트만 빨강 2초. 가장 단순한 동작 검증."""

from pybricks.hubs import PrimeHub
from pybricks.parameters import Color
from pybricks.tools import wait

print("smoke: start")
hub = PrimeHub()
hub.light.on(Color.RED)
wait(2000)
hub.light.off()
print("smoke: done")
