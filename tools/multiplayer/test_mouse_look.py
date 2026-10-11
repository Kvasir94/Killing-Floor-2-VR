import unittest

from friends import disable_mouse_look

ROW = 'Bindings=(Name="{name}",Command="{command}",Control=False,Shift=False,Alt=False,bIgnoreCtrl=False,bIgnoreShift=False,bIgnoreAlt=False)'
INPUT = "\r\n".join([
    "[Engine.PlayerInput]",
    "MouseSensitivity=30.000000",
    ROW.format(name="MouseX", command="Count bXAxis | Axis aMouseX"),
    ROW.format(name="MouseY", command="Count bYAxis | Axis aMouseY"),
    ROW.format(name="LeftMouseButton", command="GBA_Fire | SpectatePrevPlayer"),
    ROW.format(name="MouseScrollUp", command="GBA_NextWeapon"),
    "[KFGame.KFPlayerInput]",
    ROW.format(name="MouseX", command="Count bXAxis | Axis aMouseX"),
    ROW.format(name="MouseY", command="Count bYAxis | Axis aMouseY"),
    ROW.format(name="XboxTypeS_RightX", command="Axis aTurn Speed=1.0 DeadZone=0.2"),
    "[GameFramework.DebugCameraInput]",
    'Bindings=(Name="MouseX",Command="Count bXAxis | Axis aMouseX")',
    ""])


class MouseLookTest(unittest.TestCase):
    def test_mouse_axes_lose_look_only(self):
        text = disable_mouse_look(INPUT)
        for section in ("[Engine.PlayerInput]", "[KFGame.KFPlayerInput]"):
            block = text.split(section, 1)[1].split("\r\n[", 1)[0]
            self.assertIn(ROW.format(name="MouseX", command="Count bXAxis"), block)
            self.assertIn(ROW.format(name="MouseY", command="Count bYAxis"), block)
            self.assertNotIn("aMouse", block)
        self.assertIn(ROW.format(name="LeftMouseButton", command="GBA_Fire | SpectatePrevPlayer"), text)
        self.assertIn(ROW.format(name="MouseScrollUp", command="GBA_NextWeapon"), text)
        self.assertIn(ROW.format(name="XboxTypeS_RightX", command="Axis aTurn Speed=1.0 DeadZone=0.2"), text)
        self.assertIn('Bindings=(Name="MouseX",Command="Count bXAxis | Axis aMouseX")', text)
        self.assertEqual(text.count("\r\n"), INPUT.count("\r\n"))

    def test_repeat_is_unchanged(self):
        once = disable_mouse_look(INPUT)
        self.assertEqual(disable_mouse_look(once), once)


if __name__ == "__main__":
    unittest.main()
