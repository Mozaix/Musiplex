#!/usr/bin/env bash
# Builds the Mac installer: Musiplex-<version>-Mac.pkg, where people tick Musiplex,
# Workload or both. Both apps go to /Applications.
#
#   Installer/Mac/build_pkg.sh <version> <out-dir> <Musiplex.app> [Workload.app]
#
# Use public builds (ad-hoc signed, no personal paths); see the release notes in README.
# The package itself is unsigned, so the first time people right-click it → Open.
set -euo pipefail
version="$1"; out="$2"; musiplex="$3"; workload="${4:-}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

component() {   # name app id
  local root="$work/root-$1"
  mkdir -p "$root"
  ditto "$2" "$root/$(basename "$2")"
  # Not relocatable: always install to /Applications, even if another copy exists elsewhere.
  pkgbuild --analyze --root "$root" "$work/$1.plist" >/dev/null
  plutil -replace 0.BundleIsRelocatable -bool NO "$work/$1.plist"
  pkgbuild --root "$root" --install-location /Applications --identifier "$3" --version "$version" \
    --component-plist "$work/$1.plist" "$work/$1.pkg" >/dev/null
}

component musiplex "$musiplex" com.musiplex.pkg.musiplex
[ -n "$workload" ] && component workload "$workload" com.musiplex.pkg.workload

{
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Musiplex $version</title>
  <welcome mime-type="text/plain"><![CDATA[Musiplex $version

Choose the apps to install on the next page:
• Musiplex: your music library, player, notch and the server for your phones.
$( [ -n "$workload" ] && echo "• Workload: school tasks and deadlines, synced through Musiplex." )

Nothing about you is built in. Each Mac makes its own pairing PIN and key the first time it runs.]]></welcome>
  <options customize="always" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_localSystem="true"/>
  <choices-outline>
    <line choice="musiplex"/>
XML
  [ -n "$workload" ] && echo '    <line choice="workload"/>'
  cat <<XML
  </choices-outline>
  <choice id="musiplex" title="Musiplex" description="Your music: library, player, notch, mini player and the server for your iPhone, Android and Watch." start_selected="true">
    <pkg-ref id="com.musiplex.pkg.musiplex"/>
  </choice>
  <pkg-ref id="com.musiplex.pkg.musiplex" version="$version">musiplex.pkg</pkg-ref>
XML
  if [ -n "$workload" ]; then cat <<XML
  <choice id="workload" title="Workload" description="School tasks and deadlines (Toddle imports), with a menu bar companion. Syncs through your Musiplex server." start_selected="true">
    <pkg-ref id="com.musiplex.pkg.workload"/>
  </choice>
  <pkg-ref id="com.musiplex.pkg.workload" version="$version">workload.pkg</pkg-ref>
XML
  fi
  echo '</installer-gui-script>'
} > "$work/distribution.xml"

productbuild --distribution "$work/distribution.xml" --package-path "$work" "$out/Musiplex-$version-Mac.pkg" >/dev/null
echo "$out/Musiplex-$version-Mac.pkg"
