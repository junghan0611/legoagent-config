"""
legoagent — PrimeHub stdin 라인 명령 처리기.
B/F 모터 차체 기준. 서버/UI는 줄 단위 문자열을 보낸다.
"""

from pybricks.hubs import PrimeHub
from pybricks.pupdevices import Motor
from pybricks.parameters import Port, Color
from pybricks.tools import wait
from usys import stdin, stdout
from uselect import poll

hub = PrimeHub()


def emit(s):
    # bytes/str 섞지 않는다. Pybricks stdin은 str로 들어올 수 있음.
    stdout.write(str(s) + "\r\n")


hub.light.on(Color.RED)
wait(300)
hub.light.off()

motors = {}
for name, port in (("B", Port.B), ("F", Port.F)):
    try:
        motors[name] = Motor(port)
        emit("mot " + name + " ok")
    except Exception as e:
        motors[name] = None
        emit("mot " + name + " err " + str(e))

LEFT = "B"
RIGHT = "F"
LEFT_DIR = -1
RIGHT_DIR = 1
SPEED = 500
TURN = 320


def motor_run(name, speed):
    m = motors.get(name)
    if m:
        m.run(speed)
        return True
    return False


def motor_brake(name):
    m = motors.get(name)
    if m:
        m.brake()
        return True
    return False


def drive(l, r):
    motor_run(LEFT, l * LEFT_DIR)
    motor_run(RIGHT, r * RIGHT_DIR)


def brake_all():
    motor_brake(LEFT)
    motor_brake(RIGHT)


def handle(line):
    parts = line.strip().split()
    if not parts:
        return

    if parts[0] == "drv" and len(parts) >= 2:
        sub = parts[1]
        if sub == "fwd":
            drive(SPEED, SPEED)
        elif sub == "rev":
            drive(-SPEED, -SPEED)
        elif sub == "lft":
            drive(-TURN, TURN)
        elif sub == "rgt":
            drive(TURN, -TURN)
        elif sub == "stp":
            brake_all()
        else:
            emit("? " + line); return
        emit("ok " + line)
        return

    if parts[0] == "mot" and len(parts) >= 3:
        name = parts[1].upper()
        m = motors.get(name)
        if not m:
            emit("err mot " + name + " missing"); return
        arg = parts[2]
        try:
            if arg == "stop":
                m.stop()
            elif arg == "brake":
                m.brake()
            elif arg == "hold":
                m.hold()
            elif arg == "angle" and len(parts) >= 5:
                m.run_angle(int(parts[4]), int(parts[3]), wait=False)
            else:
                spd = int(arg)
                if spd == 0:
                    m.brake()
                else:
                    m.run(spd)
            emit("ok " + line)
        except Exception as e:
            emit("err " + str(e))
        return

    if parts[0] == "dsp" and len(parts) >= 2:
        try:
            sub = parts[1]
            if sub == "clear":
                hub.display.off()
            elif sub == "pixel" and len(parts) >= 5:
                hub.display.pixel(int(parts[2]), int(parts[3]), int(parts[4]))
            elif sub == "text" and len(parts) >= 3:
                hub.display.text(" ".join(parts[2:]))
            elif sub == "icon" and len(parts) >= 3:
                # Pybricks 버전별 Icon 상수 차이를 피하려고 검증용 고정 스마일.
                hub.display.icon([
                    [0, 100, 0, 100, 0],
                    [0, 0, 0, 0, 0],
                    [0, 0, 0, 0, 0],
                    [100, 0, 0, 0, 100],
                    [0, 100, 100, 100, 0],
                ])
            else:
                emit("? " + line); return
            emit("ok " + line)
        except Exception as e:
            emit("err " + str(e))
        return

    if parts[0] == "snd" and len(parts) >= 2:
        try:
            if parts[1] == "beep":
                freq = int(parts[2]) if len(parts) >= 3 else 440
                ms = int(parts[3]) if len(parts) >= 4 else 200
            elif parts[1] == "note":
                note = parts[2] if len(parts) >= 3 else "C4"
                ms = int(parts[3]) if len(parts) >= 4 else 200
                freq = {"C4": 262, "D4": 294, "E4": 330, "F4": 349, "G4": 392, "A4": 440, "B4": 494,
                        "C5": 523, "D5": 587, "E5": 659, "F5": 698, "G5": 784, "A5": 880}.get(note, 440)
            else:
                emit("? " + line); return
            hub.speaker.beep(freq, ms)
            emit("ok " + line)
        except Exception as e:
            emit("err " + str(e))
        return

    if parts[0] == "lit" and len(parts) >= 4:
        try:
            r = int(parts[1]); g = int(parts[2]); b = int(parts[3])
            if r == 0 and g == 0 and b == 0:
                hub.light.off()
            elif r >= g and r >= b:
                hub.light.on(Color.RED)
            elif g >= r and g >= b:
                hub.light.on(Color.GREEN)
            else:
                hub.light.on(Color.BLUE)
            emit("ok " + line)
        except Exception as e:
            emit("err " + str(e))
        return

    if parts[0] == "imu":
        # UI 연결 검증용: 가능한 센서값은 읽고, 실패하면 0으로 채워 응답한다.
        pitch = roll = yaw = ax = ay = az = gx = gy = gz = 0
        try:
            pitch, roll = hub.imu.tilt()
        except Exception:
            pass
        try:
            ax, ay, az = hub.imu.acceleration()
        except Exception:
            pass
        try:
            gx, gy, gz = hub.imu.angular_velocity()
        except Exception:
            pass
        emit("tlm imu pitch=" + str(pitch) + " roll=" + str(roll) + " yaw=" + str(yaw) +
             " ax=" + str(ax) + " ay=" + str(ay) + " az=" + str(az) +
             " gx=" + str(gx) + " gy=" + str(gy) + " gz=" + str(gz))
        return

    if parts[0] == "hub" and len(parts) >= 2:
        if parts[1] == "info":
            hub.display.text("OK")
            emit("ok hub info")
        elif parts[1] == "shutdown":
            emit("ok hub shutdown ignored")
        elif parts[1] == "reboot":
            emit("ok hub reboot ignored")
        else:
            emit("? " + line)
        return

    if parts[0] == "bat":
        emit("tlm bat v=" + str(hub.battery.voltage()) + " i=" + str(hub.battery.current()))
        return

    emit("? " + line)


p = poll()
p.register(stdin)
emit("rdy")
hub.light.on(Color.GREEN)
wait(200)
hub.light.off()

buf = ""
while True:
    if not p.poll(0):
        wait(10)
        continue
    ch = stdin.read(1)
    if not ch:
        continue
    buf += ch
    if ch == "\n":
        line = buf.strip()
        buf = ""
        if line:
            hub.light.on(Color.BLUE)
            try:
                handle(line)
            except Exception as e:
                emit("err " + str(e))
            wait(30)
            hub.light.off()
