#!/bin/sh
# pad.sh BUTTON [BUTTON...] - taps virtual controller buttons in order (needs scripts/webpad.py running).
for b in "$@"; do
  case "$b" in
    wait) sleep 1 ;;
    *) curl -s -o /dev/null -X POST "http://127.0.0.1:8777/d/$b"; sleep 0.15
       curl -s -o /dev/null -X POST "http://127.0.0.1:8777/u/$b"; sleep 0.5 ;;
  esac
done
