"""Prepare a checkout of the app for App Store screenshots (CI only, never committed).

Usage: python3 patch_app.py <path to ios/BoulderMe>
"""
import pathlib
import shutil
import sys

app = pathlib.Path(sys.argv[1])
here = pathlib.Path(__file__).parent


def replace(rel, old, new):
    path = app / rel
    text = path.read_text()
    if old not in text:
        sys.exit(f"{rel}: expected text not found: {old!r}")
    path.write_text(text.replace(old, new))


shutil.copy(here / "ScreenshotScene.swift", app / "App" / "ScreenshotScene.swift")
replace("App/AppModel.swift", "        if config.startInDemo {\n",
        "        if ScreenshotScene.isActive && ScreenshotScene.name != \"welcome\" {\n"
        "            ScreenshotScene.apply(to: self)\n"
        "        } else if config.startInDemo {\n")
replace("DesignSystem/Components/DemoBadge.swift", "if app.isDemo {", "if app.isDemo && !ScreenshotScene.isActive {")
replace("Demo/DemoFixtures.swift", "Cozy Crimp Collective (demo)", "Cozy Crimp Collective")
replace("Demo/DemoFixtures.swift", "Sloper Social Club (demo)", "Sloper Social Club")
replace("Demo/DemoFixtures.swift", "displayName: \"You (demo)\"", "displayName: \"Alex\"")
replace("Demo/DemoFixtures.swift", "\"Exploring BoulderMe in demo mode.\"", "\"Slab first, coffee after. Always up for a Tuesday session.\"")
print("patched", app)
