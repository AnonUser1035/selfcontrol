# [SelfControl][website]

<p align="center">
    <img src="./.github/docs/screenshot.png" />
</p>

## About

SelfControl is a free and open-source application for macOS that lets you block **your own** access to distracting websites, your mail servers, or anything else on the Internet. Just set a period of time to block for, add sites to your blocklist, and click "Start Block". Until that timer expires, you will be unable to access those sites—even if you restart your computer or delete the application.

## This fork: scheduled blocks

This fork adds **recurring scheduled blocks** (e.g. weekdays 9:00–17:00, or every night 23:00–07:00).

- Schedules are stored and enforced by SelfControl's root daemon, so they start on time even when the app is closed, and survive reboots..
- Each schedule keeps its own copy of the sites to block (defaulting to your blocklist), so emptying your main blocklist can't weaken a schedule.
- If a block is already running when a schedule starts, the block is extended to the end of the schedule's window and the schedule's sites are added to it.
- A schedule can't be removed, turned off or shortened while it's active. You can still add sites to it.
- If the Mac is asleep when a window starts, the block starts on wake. If the Mac is off, that window is skipped.

Manage schedules from **SelfControl → Schedules…** (⌘⇧S) or the **Schedules…** button, or from the command line:

```sh
selfcontrol-cli schedule list
selfcontrol-cli schedule add --name "Work" --days mon-fri --start 9:00 --end 17:00
selfcontrol-cli schedule add --days sun-thu --start 23:00 --end 7:00 --sites reddit.com,youtube.com
selfcontrol-cli schedule disable work
selfcontrol-cli schedule remove work
```

One-off blocks: `selfcontrol-cli schedule add --date today --windows 10:00-12:00,14:00-16:30` (deleted once over).

**Passwords.** Anything that only makes blocking stricter and lasts at most 4 hours doesn't ask for a password: starting a block, extending it, adding sites, or adding/enabling a schedule whose window is 4 hours or less. Anything that loosens blocking (removing, disabling or editing a schedule) or adds a longer restriction still asks for an administrator password. The daemon makes this decision, using separate authorization rights (`org.eyebeam.SelfControl.startShortBlock`, `tightenShortBlock`, `tightenSchedules`) that default to "allow"; set them to `authenticate-admin` with `security authorizationdb` to require the password again. The daemon also stays loaded permanently now, so it never needs reinstalling.

**AI agents.** [`mcp/`](./mcp) has an MCP server so agents like Codex or Claude Code can start and schedule focus blocks of a fixed site list, within the 4-hour cap, but never stop one.

Other fork changes: builds with Xcode 27 / the macOS 27 SDK (deployment target 12.0), Sparkle auto-updates are off (they would replace this build with upstream's), and Sentry crash reporting is removed. To build it yourself you need your own signing certificate: replace the team ID `ST2ZP3Y3L5` throughout the project, the Info.plists and `Daemon/SCDaemon.m`, then follow the build steps below (`git submodule update --init` first). The privileged helper only works when the app, CLI and daemon are all signed by the same team.

## Credits

Developed by [Charlie Stigler](http://charliestigler.com), [Steve Lambert](http://visitsteve.com), and [others](https://github.com/SelfControlApp/selfcontrol/graphs/contributors). Your contributions very welcome!

SelfControl is now available in 12 languages thanks to [the fine translators credited here](https://github.com/SelfControlApp/selfcontrol/wiki/Translation-Credits).

## License

SelfControl is free software under the GPL. See [this file](./COPYING) for more details.

## Building For Development

Users should always download the latest version of SelfControl from [our website][website]. If you want to contribute to SelfControl, you'll need to learn to build it for development. This can only be done on a Mac running a modern version of macOS.

1. Clone the SelfControl repo from GitHub.
2. Make sure you have a recent version of Xcode and the Xcode command-line tools installed.
3. Install [CocoaPods](https://cocoapods.org/): `sudo gem install cocoapods`
4. Install the SelfControl dependencies using CocoaPods: `pod install`
5. Open the `selfcontrol.xcworkspace` file (**NOT** `selfcontrol.xcodeproj`)
6. Build and run (you may need to update/remove code signing settings to make it build properly)

[website]: https://selfcontrolapp.com/
