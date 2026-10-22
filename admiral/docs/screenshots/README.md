# README screenshots

Real renders of Admiral's SwiftUI views, drawn by the app from invented fixtures (no live sessions, no real data).
Always run them isolated, from the build products and never the installed app:

```bash
APP=admiral/App/build/Build/Products/Release/Admiral.app
iso(){ t=$(uuidgen|cut -c1-8); open -n -W --env ADMIRAL_SUPPORT_DIR=/tmp/admiral-iso-$t --env ADMIRAL_PROFILE=shots-$t "$@"; }
iso $APP --args -probeGroupsUI /tmp/shots/groups      # sidebar, group chat, @ picker, ask, members, new group, footprint
iso $APP --args -probeSheets   /tmp/shots/sheets      # schedules + every Settings section
iso --env ADMIRAL_DEMO=1 --env ADMIRAL_SNAPSHOT=/tmp/shots/main-window.png $APP   # main window
```

Mapping: `main-window`←main; `sidebar`/`sidebar-rail`/`group-*`/`new-group`/`footprint*`←groups;
`schedules`/`settings-*`←sheets (`settings-eye`=watchdog, `bell`=notifications, `ticket`=tickets,
`terminal`=sessions, `flask`=experimental, `circle.lefthalf.filled`=appearance).
