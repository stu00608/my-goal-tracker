#!/usr/bin/env python3
"""Small regression checks for native developer commands; no device operations."""

import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import dev
from dev import choose_device, choose_iphone, test_summary, test_selection


class IPhoneTransportTests(unittest.TestCase):
    def setUp(self):
        self.phone = {
            "identifier": "fake-phone-id",
            "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected"},
        }

    def test_local_network(self):
        self.phone["connectionProperties"]["transportType"] = "localNetwork"
        self.assertEqual(dev.iphone_transport(self.phone), "Wi-Fi")

    def test_wired(self):
        self.phone["connectionProperties"]["transportType"] = "wired"
        self.assertEqual(dev.iphone_transport(self.phone), "USB")

    def test_missing_field(self):
        self.assertEqual(dev.iphone_transport(self.phone), "unknown")
        del self.phone["connectionProperties"]
        self.assertEqual(dev.iphone_transport(self.phone), "unknown")

    def test_unknown_value(self):
        self.phone["connectionProperties"]["transportType"] = "futureTransport"
        self.assertEqual(dev.iphone_transport(self.phone), "unknown")


phone = {"name": "iPhone QA", "udid": "owned-device", "isAvailable": True}
inventory = {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
        {"name": "iPhone old", "udid": "unavailable", "isAvailable": False}, phone],
    "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [
        {"name": "iPhone misleading", "udid": "wrong-platform", "isAvailable": True}],
}
assert choose_device(inventory) == phone
assert choose_device(inventory, "owned-device") == phone
for requested in ("unavailable", "wrong-platform", "missing"):
    try:
        choose_device(inventory, requested)
    except ValueError:
        pass
    else:
        raise AssertionError("An invalid requested device silently fell back: " + requested)

test_summary({"passedTests": 2, "failedTests": 0})
for summary in ({}, {"passedTests": 2}, {"passedTests": 0}, {"passedTests": 0, "skippedTests": 5},
                {"passedTests": 2, "failedTests": 1}, {"passedTests": "2"},
                {"passedTests": True, "failedTests": 0},
                {"passedTests": 2, "failedTests": 0, "skippedTests": 1}):
    try:
        test_summary(summary)
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid test result accepted: " + repr(summary))
assert test_selection("test", "GoalTracker", True) == ["-only-testing:GoalTrackerTests"]
assert test_selection("test", "GoalTracker", False) == []
for action, scheme in [("build", "GoalTracker"), ("run", "GoalTracker"), ("check", "GoalTracker"),
                       ("test", "GoalTrackerWithWidget")]:
    try:
        test_selection(action, scheme, True)
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid unit-only selection silently accepted: " + action + " " + scheme)

iphone = {"identifier": "phone-id",
          "hardwareProperties": {"deviceType": "iPhone", "udid": "phone-udid", "marketingName": "iPhone Test Model"},
          "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected", "transportType": "localNetwork"},
          "deviceProperties": {"name": "Test iPhone"}}
other = {**iphone, "identifier": "other-id", "hardwareProperties": {"deviceType": "iPhone", "udid": "other-udid"}}
ipad = {**iphone, "hardwareProperties": {"deviceType": "iPad", "udid": "ipad-udid"}}
offline = {**iphone, "connectionProperties": {"pairingState": "paired", "tunnelState": "unavailable"}}
unpaired = {**iphone, "connectionProperties": {"pairingState": "unpaired", "tunnelState": "connected"}}
assert choose_iphone([iphone, ipad, offline, unpaired]) == iphone
assert choose_iphone([iphone, other], "phone-id") == iphone
assert choose_iphone([iphone, other], "phone-udid") == iphone
for inventory, requested in [([], None), ([ipad, offline, unpaired], None),
                             ([iphone, other], None), ([iphone], "missing")]:
    try:
        choose_iphone(inventory, requested)
    except ValueError:
        pass
    else:
        raise AssertionError("Unsafe iPhone selection accepted")

with patch.object(dev.sys, "argv", ["dev.py", "install"]), patch.object(dev, "install") as install:
    dev.main()
    install.assert_called_once_with(None, "GoalTrackerWithWidget")

with tempfile.TemporaryDirectory(dir=dev.ROOT) as directory, patch("builtins.print") as output:
    root = Path(directory)
    calls = []

    def fake_run(*args, **kwargs):
        calls.append(tuple(str(arg) for arg in args))
        if args[:4] == ("xcrun", "devicectl", "list", "devices"):
            Path(args[-1]).write_text(json.dumps({"result": {"devices": [iphone]}}))

    with patch.object(dev, "ARTIFACTS", root), patch.object(dev, "DERIVED", root), \
            patch.object(dev.sys, "platform", "darwin"), patch.object(dev, "run", fake_run):
        with patch.object(dev, "xcode") as build:
            dev.install()
            build.assert_called_once_with("build", scheme="GoalTrackerWithWidget", physical=True)
            output.assert_any_call("Using iPhone: Test iPhone (iPhone Test Model); transport: Wi-Fi", flush=True)
        app = str(root / "Build/Products/Debug-iphoneos/GoalTrackerWithWidget.app")
        assert calls[-2] == ("codesign", "--verify", "--deep", "--strict", app)
        assert calls[-1] == ("xcrun", "devicectl", "device", "install", "app", "--device", "phone-id", app, "--timeout", "120")
        calls.clear()
        with patch.object(dev, "xcode", side_effect=subprocess.CalledProcessError(1, "xcodebuild")):
            try:
                dev.install()
            except subprocess.CalledProcessError:
                pass
            else:
                raise AssertionError("Build failure accepted")
        assert len(calls) == 1, "A failed build must not install or delete the app"

    with patch.object(dev, "ARTIFACTS", root), \
            patch.object(dev.subprocess, "Popen", return_value=SimpleNamespace(stdout=[], wait=lambda: 0)) as build:
        dev.xcode("build", scheme="GoalTrackerWithWidget", physical=True)
        command = build.call_args.args[0]
        assert command[command.index("-destination") + 1] == "generic/platform=iOS"
        assert "-allowProvisioningUpdates" in command
        assert not any(arg.startswith(("CODE_SIGNING_ALLOWED=", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM=")) for arg in command)
        dev.xcode("build", scheme="GoalTrackerWithWidget")
        command = build.call_args.args[0]
        assert command[command.index("-destination") + 1] == "generic/platform=iOS Simulator"
        assert "CODE_SIGN_IDENTITY=-" in command and "DEVELOPMENT_TEAM=" in command
        assert "-allowProvisioningUpdates" not in command

print("Developer tool regression checks passed (no native execution claimed).")

if __name__ == "__main__":
    unittest.main()
