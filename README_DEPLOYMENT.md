# Orchard Resend Daemon - Deployment Guide

## Quick Start

### 1. Configure Environment Variables

Copy the example environment file and configure it:

```bash
cd /opt/makafui/extras/orchard_resend
cp .env.prod.example .env.prod
nano .env.prod
```

Set your database credentials:
```bash
export M_DB_NAME="your_database_name"
export M_DB_USER="your_database_user"
export M_DB_PASSWORD="your_database_password"
export M_DB_HOST="localhost"
export M_DB_PORT="5432"
```

### 2. Build the Release

```bash
chmod +x build_release.sh
./build_release.sh
```

### 3. Start the Daemon

```bash
# Load environment variables
source .env.prod

# Start as daemon (runs in background)
_build/prod/rel/orchard_resend/bin/orchard_resend daemon
```

## Daemon Commands

```bash
# Start in foreground (for testing)
_build/prod/rel/orchard_resend/bin/orchard_resend start

# Start as daemon (background process)
_build/prod/rel/orchard_resend/bin/orchard_resend daemon

# Stop the daemon
_build/prod/rel/orchard_resend/bin/orchard_resend stop

# Restart the daemon
_build/prod/rel/orchard_resend/bin/orchard_resend restart

# Get daemon process ID
_build/prod/rel/orchard_resend/bin/orchard_resend pid

# Connect to running daemon (remote console)
_build/prod/rel/orchard_resend/bin/orchard_resend remote
```

## Monitoring the Daemon

### Check Status from Remote Console

```bash
_build/prod/rel/orchard_resend/bin/orchard_resend remote
```

Inside the remote console:
```elixir
# Check daemon status
OrchardResend.ResenderDaemon.status()

# Pause the daemon
OrchardResend.ResenderDaemon.pause()

# Resume the daemon
OrchardResend.ResenderDaemon.resume()

# Exit remote console (daemon keeps running)
# Press Ctrl+C twice
```

### View Logs

```bash
# Application logs
tail -f _build/prod/rel/orchard_resend/log/erlang.log.1

# Or check all log files
ls -lh _build/prod/rel/orchard_resend/log/
```

## Configuration

The daemon is configured in `lib/orchard_resend/application.ex`:

- **check_interval**: 60,000ms (1 minute) - How often to check for pending callbacks
- **batch_size**: 1000 - Number of callbacks to process per batch
- **concurrency**: 20 - Number of concurrent HTTP requests
- **timeout**: 60,000ms (60 seconds) - HTTP request timeout
- **batch_delay**: 1,000ms (1 second) - Delay between batches

## Manual Operations

You can still run manual resends for specific dates:

```bash
# Connect to running daemon
_build/prod/rel/orchard_resend/bin/orchard_resend remote
```

```elixir
# Check pending count for a date
OrchardResend.Resender.get_pending_count_for_date("2025-11-19")

# Resend for specific date
OrchardResend.Resender.resend_for_date("2025-11-19")

# Get all pending callbacks count
OrchardResend.Resender.get_pending_count()
```

## Troubleshooting

### Check if daemon is running
```bash
_build/prod/rel/orchard_resend/bin/orchard_resend pid
```

### View recent logs
```bash
tail -n 100 _build/prod/rel/orchard_resend/log/erlang.log.1
```

### Daemon won't start
1. Check environment variables are set
2. Verify database connection
3. Check logs for errors

### Rebuild after code changes
```bash
./build_release.sh
_build/prod/rel/orchard_resend/bin/orchard_resend restart
```

## Keeping Daemon Running

The daemon will continue running even after you disconnect from SSH. However, if the server reboots, you'll need to restart it manually or set up a systemd service (see separate documentation).

## Using with Screen/Tmux (Alternative)

If you want to monitor the daemon in foreground:

```bash
# Using screen
screen -S orchard_resend
source .env.prod
_build/prod/rel/orchard_resend/bin/orchard_resend start
# Press Ctrl+A then D to detach

# Reattach later
screen -r orchard_resend

# Using tmux
tmux new -s orchard_resend
source .env.prod
_build/prod/rel/orchard_resend/bin/orchard_resend start
# Press Ctrl+B then D to detach

# Reattach later
tmux attach -t orchard_resend
```
