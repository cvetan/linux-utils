#!/usr/bin/env bash
# =============================================================================
# setup/test-php.sh — scratch script for eyeballing lib/ui.sh output
# =============================================================================
# Sources the library relative to this file, so it works from any working
# directory.

_setup_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_setup_dir/../lib/ui.sh"

info 'Testing...'
