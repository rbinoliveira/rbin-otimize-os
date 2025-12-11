# Scheduling Guide

This guide provides comprehensive instructions for scheduling OS optimization scripts to run automatically on macOS and Linux systems.

## Table of Contents

- [Cron Examples (Linux/macOS)](#cron-examples-linuxmacos)
- [Systemd Timer Examples (Linux)](#systemd-timer-examples-linux)
- [Launchd Examples (macOS)](#launchd-examples-macos)
- [Best Practices](#best-practices)
- [Safety Considerations](#safety-considerations)

---

## Cron Examples (Linux/macOS)

Cron is available on both Linux and macOS systems and provides a simple way to schedule tasks.

### Weekly Optimization

Run full system optimization every Sunday at 3 AM:

```bash
0 3 * * 0 /path/to/run.sh --scheduled >> /var/log/os-optimize.log 2>&1
```

### Daily Memory Cleanup

Run memory cleanup every day at 2 AM:

```bash
0 2 * * * /path/to/mac/clean-memory.sh --quiet >> ~/.os-optimize/logs/daily-clean.log 2>&1
```

### Bi-weekly with Logging

Run optimization on Sundays and Wednesdays at 4 AM:

```bash
0 4 * * 0,3 /path/to/run.sh --scheduled >> /var/log/os-optimize.log 2>&1
```

### Installing Cron Jobs

1. **Edit crontab:**
   ```bash
   crontab -e
   ```

2. **Add your cron entry** (use one of the examples above)

3. **Verify installation:**
   ```bash
   crontab -l
   ```

4. **Check cron service status:**
   - Linux: `systemctl status cron` or `systemctl status crond`
   - macOS: Cron runs automatically via launchd

### Cron Syntax

```
* * * * * command
│ │ │ │ │
│ │ │ │ └─── Day of week (0-7, 0 and 7 = Sunday)
│ │ │ └───── Month (1-12)
│ │ └─────── Day of month (1-31)
│ └───────── Hour (0-23)
└─────────── Minute (0-59)
```

---

## Systemd Timer Examples (Linux)

Systemd timers provide more advanced scheduling features than cron, including randomized delays and better logging integration.

### Weekly Optimization Timer

**1. Create service file** (`/etc/systemd/system/os-optimize.service`):

```ini
[Unit]
Description=OS Optimization Script
After=network.target

[Service]
Type=oneshot
User=root
WorkingDirectory=/path/to/project
ExecStart=/path/to/linux/optimize-all.sh --scheduled
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**2. Create timer file** (`/etc/systemd/system/os-optimize.timer`):

```ini
[Unit]
Description=Weekly OS Optimization Timer
Requires=os-optimize.service

[Timer]
OnCalendar=weekly
OnCalendar=Sun 03:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

**3. Install and start:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable os-optimize.timer
sudo systemctl start os-optimize.timer
```

**4. Check status:**

```bash
sudo systemctl status os-optimize.timer
sudo systemctl list-timers os-optimize.timer
```

**5. View logs:**

```bash
sudo journalctl -u os-optimize.service -f
```

### Daily Memory Cleanup Timer

**Service file** (`/etc/systemd/system/os-clean-memory.service`):

```ini
[Unit]
Description=Daily Memory Cleanup
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/path/to/linux/clean-memory.sh --quiet
StandardOutput=journal
StandardError=journal
```

**Timer file** (`/etc/systemd/system/os-clean-memory.timer`):

```ini
[Unit]
Description=Daily Memory Cleanup Timer
Requires=os-clean-memory.service

[Timer]
OnCalendar=daily
OnCalendar=02:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
```

### Timer Calendar Format

- `OnCalendar=weekly` - Every week
- `OnCalendar=daily` - Every day
- `OnCalendar=hourly` - Every hour
- `OnCalendar=Sun 03:00` - Every Sunday at 3 AM
- `OnCalendar=Mon..Fri 02:00` - Weekdays at 2 AM
- `OnCalendar=*-*-01 00:00:00` - First day of every month

---

## Launchd Examples (macOS)

Launchd is macOS's native scheduling system, replacing cron for most use cases.

### Weekly Optimization

**Create plist file** (`~/Library/LaunchAgents/com.optimize.weekly.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.optimize.weekly</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/mac/optimize-all.sh</string>
        <string>--scheduled</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>0</integer>
        <key>Hour</key>
        <integer>3</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>~/.os-optimize/logs/weekly-optimize.log</string>
    <key>StandardErrorPath</key>
    <string>~/.os-optimize/logs/weekly-optimize-error.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
```

**Load and start:**

```bash
launchctl load ~/Library/LaunchAgents/com.optimize.weekly.plist
launchctl start com.optimize.weekly
```

**Check status:**

```bash
launchctl list | grep optimize
```

**Unload (to disable):**

```bash
launchctl unload ~/Library/LaunchAgents/com.optimize.weekly.plist
```

### Daily Memory Cleanup

**Plist file** (`~/Library/LaunchAgents/com.optimize.daily.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.optimize.daily</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/mac/clean-memory.sh</string>
        <string>--quiet</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>2</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>~/.os-optimize/logs/daily-clean.log</string>
    <key>StandardErrorPath</key>
    <string>~/.os-optimize/logs/daily-clean-error.log</string>
</dict>
</plist>
```

### Launchd Key Fields

- `Label` - Unique identifier for the job
- `ProgramArguments` - Array of command and arguments
- `StartCalendarInterval` - Schedule timing (Weekday 0=Sunday, Hour 0-23, Minute 0-59)
- `StandardOutPath` - Log file for stdout
- `StandardErrorPath` - Log file for stderr
- `RunAtLoad` - Run immediately when loaded (usually false for scheduled jobs)

---

## Best Practices

### Optimal Scheduling Times

- **Late night/early morning (2-4 AM)**: System is typically idle, minimal user impact
- **Weekends**: Lower system usage, safer for full optimization
- **Avoid peak hours**: Don't schedule during business hours or high-usage periods
- **Consider time zones**: For servers, schedule in server's local time zone

### Monitoring and Alerts

1. **Check logs regularly:**
   ```bash
   # View recent logs
   tail -f ~/.os-optimize/logs/*.log

   # Check for errors
   grep ERROR ~/.os-optimize/logs/*.log
   ```

2. **Set up email notifications:**
   - Configure email in `config/optimize.conf`
   - Use `--email` flag for automated reports

3. **Monitor exit codes:**
   - Exit code 0 = success
   - Non-zero = failure (check logs)

4. **Set up alerts for failures:**
   - Use cron/systemd/launchd to check exit codes
   - Send alerts if optimization fails

### Resource Considerations

- **Disk space**: Ensure sufficient free space (>5GB recommended)
- **Avoid during backups**: Don't run optimization during system backups
- **Network availability**: Some operations may require network access
- **System load**: Monitor system load before scheduling heavy operations

---

## Safety Considerations

### Testing Before Automation

1. **Always test manually first:**
   ```bash
   # Test with dry-run
   ./run.sh --dry-run

   # Test actual execution
   ./run.sh
   ```

2. **Verify paths are correct:**
   - Use absolute paths in cron/systemd/launchd configs
   - Test paths before scheduling

3. **Check permissions:**
   - Ensure scripts are executable (`chmod +x`)
   - Verify sudo access if required

### Configuration for Automated Runs

1. **Use conservative settings:**
   - Avoid `--aggressive` flag in automated runs
   - Use `--scheduled` flag for non-interactive mode
   - Set conservative thresholds in `config/optimize.conf`

2. **Enable logging:**
   - Always log to files for troubleshooting
   - Set up log rotation to prevent disk fill

3. **Email notifications:**
   - Configure email alerts for failures
   - Review email reports regularly

### Rollback Procedures

1. **Maintain backups:**
   - System creates snapshots before optimization
   - Keep recent backups available

2. **Document rollback steps:**
   - Know how to restore from snapshots
   - Test rollback procedure before needing it

3. **Monitor system stability:**
   - Watch for unusual behavior after optimization
   - Have rollback plan ready

### Log Rotation

Prevent log files from filling disk:

```bash
# Add to crontab for log cleanup
0 0 * * 0 find ~/.os-optimize/logs -name "*.log" -mtime +30 -delete
```

Or configure in `config/optimize.conf`:
```
log_retention_days=30
```

---

## Troubleshooting

### Cron Issues

- **Cron not running**: Check cron service status
- **Paths not found**: Use absolute paths in cron entries
- **Permissions**: Ensure user has execute permissions

### Systemd Timer Issues

- **Timer not starting**: Check `systemctl status os-optimize.timer`
- **Service failing**: Check `journalctl -u os-optimize.service`
- **Syntax errors**: Validate with `systemd-analyze verify`

### Launchd Issues

- **Plist syntax**: Validate with `plutil -lint ~/Library/LaunchAgents/com.optimize.weekly.plist`
- **Not loading**: Check file permissions and paths
- **Not running**: Check with `launchctl list | grep optimize`

---

## Examples Summary

| Schedule | Method | Command/Config |
|----------|--------|----------------|
| Weekly (Sun 3 AM) | Cron | `0 3 * * 0 /path/to/run.sh --scheduled` |
| Daily (2 AM) | Cron | `0 2 * * * /path/to/clean-memory.sh --quiet` |
| Weekly (Sun 3 AM) | Systemd | `OnCalendar=Sun 03:00` in timer file |
| Daily (2 AM) | Systemd | `OnCalendar=02:00` in timer file |
| Weekly (Sun 3 AM) | Launchd | `StartCalendarInterval` with `Weekday=0, Hour=3` |
| Daily (2 AM) | Launchd | `StartCalendarInterval` with `Hour=2` |

---

For more information, see the main [README.md](../README.md) file.
