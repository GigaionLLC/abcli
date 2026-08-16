# Run any flutter command against abgui-flutter inside the dev container, so a machine with
# no Flutter SDK can still analyze and test. macOS and Windows BUILDS cannot run here — see
# the note in docker-compose.yml.
#
# Usage:
#   ./tool/flutter.ps1 --version
#   ./tool/flutter.ps1 pub get
#   ./tool/flutter.ps1 analyze
#   ./tool/flutter.ps1 test
docker compose run --rm flutter flutter @args
