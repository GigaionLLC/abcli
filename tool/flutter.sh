#!/usr/bin/env bash
# Run any flutter command against abgui-flutter inside the dev container, so a machine with
# no Flutter SDK can still analyze and test. macOS and Windows BUILDS cannot run here — see
# the note in docker-compose.yml.
#
# Usage:
#   ./tool/flutter.sh --version
#   ./tool/flutter.sh pub get
#   ./tool/flutter.sh analyze
#   ./tool/flutter.sh test
exec docker compose run --rm flutter flutter "$@"
