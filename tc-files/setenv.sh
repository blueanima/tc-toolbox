#!/bin/sh
# Static toolbox environment for the AirPort Time Capsule.
# All binaries under bin/ are statically linked, so no LD_LIBRARY_PATH is needed.
export PATH=/Volumes/dk2/.tc_tools/bin:/mnt/Flash/bin:$PATH
