# README images

These are real HQ for Mac windows with the bundled sample workspace. Names,
messages, projects and tasks are fictional. No company data is shown.

The app icon comes from the native client's existing HQLogo asset. Screenshot
PNGs are optimized without changing their pixels.

To capture a screen, build the Debug Mac app as described in
[`clients/apple`](../../clients/apple), then run its executable with:

```sh
HQ_UI_SCENARIO=chat \
HQ_UI_APPEARANCE=dark \
HQ_UI_OPAQUE=1 \
HQ_NO_SYSTEM_REGISTRATION=1 \
HQ_UI_SNAPSHOT_SIZE=1120x700 \
HQ_UI_SNAPSHOT=/tmp/hq-chat.png \
  .dd/Build/Products/Debug/HQ.app/Contents/MacOS/HQ
```

Run that command from `clients/apple/`. For the board, use
`HQ_UI_SCENARIO=projects` and `HQ_UI_ROUTE=project:site`. The app writes the PNG
and exits. It does not connect to a live server.
