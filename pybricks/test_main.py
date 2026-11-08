"""Host-side protocol checks; no hub, BLE, or motors are touched."""
import io
import pathlib
import sys
import types
import unittest
from unittest.mock import MagicMock, call, patch


def load_handler():
    """Execute definitions without hardware startup or the infinite stdin loop."""
    source = pathlib.Path(__file__).with_name("main.py").read_text()
    source = source[source.index('def motor_run('):source.index('\np = poll()')]
    hub = types.SimpleNamespace(
        display=MagicMock(), speaker=MagicMock(), light=MagicMock(),
        imu=MagicMock(), battery=MagicMock(),
    )
    motors = {name: MagicMock() for name in ("A", "B", "F")}
    output = []
    namespace = {
        'hub': hub, 'motors': motors, 'emit': output.append,
        'LEFT': 'B', 'RIGHT': 'F', 'AUX': 'A',
        'LEFT_DIR': -1, 'RIGHT_DIR': 1, 'AUX_DIR': 1,
        'SPEED': 800, 'TURN': 500, 'AUX_SPEED': 400,
        'Color': types.SimpleNamespace(RED=1, GREEN=2, BLUE=3),
    }
    exec(compile(source, 'main.py', 'exec'), namespace)
    return namespace['handle'], hub, motors, output


class StartupTests(unittest.TestCase):
    def run_startup(self, missing=()):
        source = pathlib.Path(__file__).with_name('main.py').read_text()
        source = source[:source.index('\nwhile True:')]
        motor = MagicMock(side_effect=lambda port: MagicMock())
        color = MagicMock(side_effect=OSError('missing') if 'color' in missing else None)
        distance = MagicMock(side_effect=OSError('missing') if 'distance' in missing else None)
        hub = types.SimpleNamespace(light=MagicMock(), speaker=MagicMock(), display=MagicMock())
        output = io.StringIO()
        modules = {
            'pybricks': types.ModuleType('pybricks'),
            'pybricks.hubs': types.SimpleNamespace(PrimeHub=lambda: hub),
            'pybricks.pupdevices': types.SimpleNamespace(Motor=motor, ColorSensor=color, UltrasonicSensor=distance),
            'pybricks.parameters': types.SimpleNamespace(
                Port=types.SimpleNamespace(A='A', B='B', C='C', E='E', F='F'),
                Color=types.SimpleNamespace(RED=1, GREEN=2, BLUE=3)),
            'pybricks.tools': types.SimpleNamespace(wait=lambda ms: None),
            'usys': types.SimpleNamespace(stdin=io.StringIO(), stdout=output),
            'uselect': types.SimpleNamespace(poll=MagicMock()),
        }
        namespace = {}
        with patch.dict(sys.modules, modules):
            exec(compile(source, 'main.py', 'exec'), namespace)
        return namespace, motor, color, distance, hub, output.getvalue()

    def test_sensor_and_motor_port_mapping(self):
        ns, motor, color, distance, _, output = self.run_startup()
        self.assertEqual(motor.call_args_list, [call('B'), call('F'), call('A')])
        color.assert_called_once_with('C')
        distance.assert_called_once_with('E')
        self.assertEqual(set(ns['motors']), {'A', 'B', 'F'})
        self.assertIn('sensor color ok', output)
        self.assertIn('sensor distance ok', output)

    def test_missing_sensors_do_not_block_drive_or_piano(self):
        for missing in (('color',), ('distance',), ('color', 'distance')):
            with self.subTest(missing=missing):
                ns, motor, color, distance, hub, output = self.run_startup(missing)
                for name in ('color', 'distance'):
                    self.assertEqual(ns['sensors'][name] is None, name in missing)
                    self.assertIn('sensor ' + name + (' err' if name in missing else ' ok'), output)
                self.assertIn('rdy\r\n', output)
                ns['handle']('drv fwd')
                ns['motors']['B'].run.assert_called_with(-800)
                ns['handle']('snd note C#4 200')
                hub.speaker.beep.assert_called_once_with(277, 200)


class ExistingProtocolTests(unittest.TestCase):
    def setUp(self):
        self.handle, self.hub, self.motors, self.output = load_handler()

    def test_piano_notes(self):
        for note, frequency in zip(('C4', 'C#4', 'D4', 'D#4', 'E4', 'F4', 'F#4',
                                    'G4', 'G#4', 'A4', 'A#4', 'B4', 'C5'),
                                   (262, 277, 294, 311, 330, 349, 370,
                                    392, 415, 440, 466, 494, 523)):
            self.handle('snd note ' + note + ' 200')
            self.hub.speaker.beep.assert_called_with(frequency, 200)
            self.assertEqual(self.output[-1], 'ok snd note ' + note + ' 200')

    def test_display_and_clear(self):
        self.handle('dsp text Hello world!')
        self.hub.display.text.assert_called_once_with('Hello world!')
        self.handle('dsp clear')
        self.hub.display.off.assert_called_once_with()

    def test_playback_brakes_every_motor_before_output(self):
        calls = []
        for name, motor in self.motors.items():
            motor.brake.side_effect = lambda name=name: calls.append(name)
        self.hub.display.text.side_effect = lambda text: calls.append('text')
        self.hub.speaker.beep.side_effect = lambda *args: calls.append('beep')
        self.handle('dsp text hi')
        self.assertEqual(calls, ['B', 'F', 'A', 'text'])
        calls.clear()
        self.handle('snd note C4 200')
        self.assertEqual(calls, ['B', 'F', 'A', 'beep'])

    def test_failed_brake_attempts_others_and_refuses_play(self):
        self.motors['F'].brake.side_effect = RuntimeError('motor failed')
        for command in ('dsp text HI', 'snd beep 440 200'):
            self.handle(command)
            self.assertEqual(self.output[-1], 'err brake')
        for motor in self.motors.values():
            self.assertEqual(motor.brake.call_count, 2)
        self.hub.display.text.assert_not_called()
        self.hub.speaker.beep.assert_not_called()

    def test_missing_motor_is_skipped(self):
        self.handle.__globals__['motors']['A'] = None
        self.handle('snd note C4 200')
        self.hub.speaker.beep.assert_called_once_with(262, 200)

    def test_display_validation_and_normalization(self):
        for command in ('dsp text', 'dsp text ' + 'A' * 17,
                        'dsp text 한글', 'dsp text a\tb', 'dsp text abc\r'):
            self.handle(command)
            self.assertEqual(self.output[-1], 'err dsp text', command)
        self.hub.display.text.assert_not_called()
        for text in ('0123456789 ~', 'A' * 16, 'a  b'):
            self.handle('dsp text ' + text)
            self.hub.display.text.assert_called_with(' '.join(text.split()))
        self.assertEqual(self.hub.display.text.call_count, 3)

    def test_every_printable_ascii_character(self):
        # Upstream at c860b6a00301fb7c6ecd429da11dcb5a6c557c7a:
        # https://github.com/pybricks/pybricks-micropython/blob/c860b6a00301fb7c6ecd429da11dcb5a6c557c7a/pybricks/common/pb_type_lightmatrix_fonts.c
        # https://github.com/pybricks/pybricks-micropython/blob/c860b6a00301fb7c6ecd429da11dcb5a6c557c7a/pybricks/common/pb_type_lightmatrix.c
        # Font/iterator cover ASCII 32..126; actual hub firmware is unverified.
        # Space alone is intentionally empty input; exercise it between glyphs.
        for code in range(32, 127):
            text = 'X' + chr(code) + 'Y'
            self.handle('dsp text ' + text)
            self.hub.display.text.assert_called_with(text)
        self.assertEqual(self.hub.display.text.call_count, 95)

    def test_other_display_commands_still_work(self):
        self.handle('dsp pixel 1 2 50')
        self.hub.display.pixel.assert_called_once_with(1, 2, 50)
        self.handle('dsp icon smile')
        self.hub.display.icon.assert_called_once()
        for motor in self.motors.values():
            motor.brake.assert_not_called()

    def test_sound_validation(self):
        for command in ('snd note Z9 200', 'snd note C4 0', 'snd note C4 -1',
                        'snd note C4 2001', 'snd beep 440 0',
                        'snd beep 440 2001', 'snd note C4 nope'):
            self.handle(command)
            self.assertTrue(self.output[-1].startswith('err '), command)
        self.hub.speaker.beep.assert_not_called()
        for command, args in (('snd beep 440 1', (440, 1)),
                              ('snd note A5 2000', (880, 2000))):
            self.handle(command)
            self.hub.speaker.beep.assert_called_with(*args)

    def test_drive_and_stop(self):
        self.handle('drv fwd')
        self.motors['B'].run.assert_called_once_with(-800)
        self.motors['F'].run.assert_called_once_with(800)
        self.handle('drv stp')
        self.motors['B'].brake.assert_called_once_with()
        self.motors['F'].brake.assert_called_once_with()

    def test_lift_unavailable_and_aux(self):
        for command in ('lift', 'lift up', 'lift dn', 'lift stp'):
            self.handle(command)
            self.assertEqual(self.output[-1], 'err lift unavailable')
        self.handle('mot E 400')
        self.assertEqual(self.output[-1], 'err mot E missing')
        self.handle('aux lft')
        self.motors['A'].run.assert_called_once_with(-400)
        self.handle('aux rgt')
        self.motors['A'].run.assert_called_with(400)
        self.handle('aux stp')
        self.motors['A'].brake.assert_called_once_with()


if __name__ == '__main__':
    unittest.main()
