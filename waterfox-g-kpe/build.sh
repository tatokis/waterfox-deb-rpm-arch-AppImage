#!/bin/bash

# Upstream modifies version_display.txt using script included in GitHub Actions (version=git_tag),
# without patching. Debhelper won't allow us to do that by same way and
# patching won't be much convenient, so we need to create new files.
mkdir -p "$(pwd)"/debian/app_version

cp "$(pwd)"/browser/config/version.txt "$(pwd)"/debian/app_version/version.txt
echo "$WF_VERSION" >"$(pwd)"/debian/app_version/version_display.txt

# LTO needs more open files
ulimit -n 4096
# Do 3-tier PGO
export GEN_PGO=1
./mach build

echo "Profiling instrumented browser..."
./mach package
LLVM_PROFDATA=llvm-profdata JARLOG_FILE="$(pwd)/jarlog" xvfb-run -s "-screen 0 1920x1080x24 -nolisten local" ./mach python build/pgo/profileserver.py

stat -c "Profile data found (%s bytes)" merged.profdata
test -s merged.profdata

stat -c "Jar log found (%s bytes)" jarlog
test -s jarlog

echo "Removing instrumented browser..."
./mach clobber

echo "Building optimized browser..."
unset GEN_PGO
export USE_PGO=1
./mach build

# Build langpacks
mkdir -p "$(pwd)"/extensions
# langpack-build can not be done in parallel easily (see https://bugzilla.mozilla.org/show_bug.cgi?id=1660943)
# Therefore, we have to have a separate obj-dir for each language
# We do this, by creating a mozconfig-template with the necessary switches
# and a placeholder obj-dir, which gets copied and modified for each language
sed -r '/^(ja-JP-mac|en-US|)$/d;s/ .*$//' debian/locales.shipped | cut -f1 -d":" |
    xargs -n 1 -P $JOBS -I {} /bin/sh -c '
        locale=$1
        cp debian/mozconfig_LANG ${PWD}/mozconfig_$locale
        sed -i "s|obj_LANG|obj_$locale|" ${PWD}/mozconfig_$locale
        export MOZCONFIG=${PWD}/mozconfig_$locale
        ./mach build config/nsinstall langpack-$locale
        cp -L ../obj_$locale/dist/linux-*/xpi/waterfox-g-$WF_VERSION.$locale.langpack.xpi \
            "$(pwd)"/extensions/langpack-$locale@l10n.waterfox.net.xpi
' -- {}
