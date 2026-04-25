from pybricks.hubs import PrimeHub
from pybricks.pupdevices import Motor
from pybricks.parameters import Port, Color
from pybricks.tools import wait

hub = PrimeHub()
hub.light.on(Color.ORANGE)

for port in (Port.B, Port.F):
    try:
        m = Motor(port)
        m.run(400)
        wait(700)
        m.brake()
        wait(300)
    except Exception as e:
        pass

hub.light.on(Color.GREEN)
wait(1000)
hub.light.off()
