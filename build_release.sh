#!/bin/bash
set -e

echo "Building Orchard Resend Release..."

cd /opt/makafui/extras/orchard_resend

# Load environment variables from ~/.env if exists
if [ -f ~/.env ]; then
    echo "Loading environment variables from ~/.env..."
    source ~/.env
elif [ -f .env.prod ]; then
    echo "Loading environment variables from .env.prod..."
    source .env.prod
else
    echo "Warning: No environment file found. Ensure environment variables are set."
fi

# Clean previous build
echo "Cleaning previous build..."
rm -rf _build/prod

# Get dependencies
echo "Fetching dependencies..."
MIX_ENV=prod mix deps.get --only prod

# Compile
echo "Compiling..."
MIX_ENV=prod mix compile

# Build release
echo "Building release..."
MIX_ENV=prod mix release --overwrite

echo ""
echo "✓ Release built successfully!"
echo ""
echo "To start the daemon, run:"
echo "  _build/prod/rel/orchard_resend/bin/orchard_resend daemon"
echo ""
echo "Other commands:"
echo "  _build/prod/rel/orchard_resend/bin/orchard_resend start      # Start in foreground"
echo "  _build/prod/rel/orchard_resend/bin/orchard_resend stop       # Stop the daemon"
echo "  _build/prod/rel/orchard_resend/bin/orchard_resend restart    # Restart the daemon"
echo "  _build/prod/rel/orchard_resend/bin/orchard_resend remote     # Connect to running daemon"
echo "  _build/prod/rel/orchard_resend/bin/orchard_resend pid        # Get daemon PID"
echo ""
