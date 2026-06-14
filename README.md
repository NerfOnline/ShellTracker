# ShellTracker
### Linkshell Attendance Tracker (Ashita v4)
Addon for Ashita v4 that creates a log file to track linkshell attendance and copies the list to clipboard. For linkshells with over 40 members, it is recommended to use linkshell mode by opening the in game linkshell roster before using the linkshell command.

### Commands
The following commands may be used:

    /st format                     -- Toggle detailed log format (csv or txt).
    /st pt [detailed]              -- Log party and alliance members to file and clipboard.
    /st ls | ls2 [detailed] [all]  -- Log linkshell roster to file and clipboard.

### Command Flags
The command flags may be used:

    detailed  -- Include job, time, and zone.
    all       -- Include members in all zones, omit for current zone only.
