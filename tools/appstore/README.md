# App Store screenshot tools

1. `appstore-screenshots` workflow (macOS runner): patches a copy of the app with `patch_app.py`
   (adds `ScreenshotScene.swift`, hides the Demo badge, drops "(demo)" from fixture names),
   builds Debug for the 6.9-inch iPhone simulator, launches each scene with
   `-BMScreenshot <scene>` and commits raw PNGs to `appstore/screenshots/raw/`.
   None of this ships in the app.
2. `python3 compose.py <raw dir> <fonts dir> <icon png> <out dir>` builds one panorama
   (`panorama.html`) where phones, the climbing wall and the route line cross the seams.
3. `NODE_PATH=$(npm root -g) node render.cjs <out dir>` renders it with Playwright and slices
   it into `01.png`…`06.png` at 1320×2868.

Fonts: Nunito (SIL Open Font License) from Google Fonts, passed in as nunito-700/800/900.ttf.
Scenes: welcome, discover, profile, invites, invitation, chat, me.
