#!/bin/sh -p
# Privileged shell mode suppresses inherited startup files, options and functions.
# This sets no uid/gid; it protects the interpreter before an env -i command runs.
exec /bin/sh -p "$@"
