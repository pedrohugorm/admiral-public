# README screenshots

Real renders of Admiral's SwiftUI views, drawn by the app from invented fixtures (no live sessions, no real data).
Always run them isolated, from the build products and never the installed app:

```bash
APP=admiral/App/build/Build/Products/Release/Admiral.app
iso(){ t=$(uuidgen|cut -c1-8); open -n -W --env ADMIRAL_SUPPORT_DIR=/tmp/admiral-iso-$t --env ADMIRAL_PROFILE=shots-$t "$@"; }
iso $APP --args -probeGroupsUI /tmp/shots/groups      # sidebar, group chat, @ picker, ask, members, new group, footprint
iso $APP --args -probeSheets   /tmp/shots/sheets      # schedules + every Settings section
# main window: the REAL window (demo fleet, "Scheduled ordering" open in Chat), captured by window id
S=/tmp/admiral-iso-main; mkdir -p $S; echo '{"version":1,"features":{"chatView":true,"groups":true}}' > $S/config.json
open -n --env ADMIRAL_SUPPORT_DIR=$S --env ADMIRAL_PROFILE=shots-main --env ADMIRAL_DEMO=1 $APP; sleep 8
screencapture -x -o -l <windowID of that pid, via CGWindowListCopyWindowInfo> /tmp/shots/main-window.png   # dark mode; quit it after
# screencapture embeds the display's ICC profile, which names the monitor model: convert to sRGB before committing
sips -m "/System/Library/ColorSync/Profiles/sRGB Profile.icc" /tmp/shots/main-window.png
```

Mapping: `main-window`←main; `sidebar`/`sidebar-rail`/`group-*`/`new-group`/`footprint*`←groups;
`schedules`/`settings-*`←sheets (`settings-eye`=watchdog, `bell`=notifications, `ticket`=tickets,
`terminal`=sessions, `flask`=experimental, `circle.lefthalf.filled`=appearance).
