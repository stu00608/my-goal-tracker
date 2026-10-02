#!/usr/bin/env python3
"""Small regression check for Simulator selection and false-positive test results."""

from dev import choose_device, test_summary

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
print("Developer tool regression checks passed (no native execution claimed).")
