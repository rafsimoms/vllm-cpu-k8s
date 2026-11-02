#!/bin/sh
set -eu

TCMALLOC="$(find /usr/lib -name 'libtcmalloc_minimal.so.4' -print -quit)"
IOMP="$(find /opt/venv -name 'libiomp5.so' -print -quit)"

PRELOAD=""
if [ -n "$TCMALLOC" ]; then PRELOAD="$TCMALLOC"; fi
if [ -n "$IOMP" ]; then PRELOAD="${PRELOAD:+$PRELOAD:}$IOMP"; fi
if [ -n "$PRELOAD" ]; then export LD_PRELOAD="$PRELOAD"; fi

exec vllm serve "$@"