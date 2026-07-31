#!/bin/bash
# Verify (and where needed, rewrite) Mach-O load paths in the staged runtime.
# python-build-standalone ships @executable_path-relative already; wheel
# extension modules occasionally leak absolute build-machine paths. Anything
# pointing outside the runtime or the OS is rewritten to @loader_path, then
# every LC_RPATH is printed for the record.
source "$(dirname "$0")/config.sh"

fail=0
while IFS= read -r -d '' macho; do
    file "$macho" | grep -q "Mach-O" || continue

    # Absolute references outside /usr/lib and /System are not relocatable.
    bad_refs=$(otool -L "$macho" | tail -n +2 | awk '{print $1}' \
        | grep -Ev '^(@|/usr/lib|/System)' || true)
    for ref in $bad_refs; do
        base="$(basename "$ref")"
        echo "REWRITE $macho: $ref -> @loader_path/$base"
        install_name_tool -change "$ref" "@loader_path/$base" "$macho"
    done

    # Any absolute LC_RPATH into a build machine path is a portability bug.
    bad_rpaths=$(otool -l "$macho" | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}' \
        | grep -Ev '^(@|/usr/lib|/System)' || true)
    for rp in $bad_rpaths; do
        echo "DELETE RPATH $macho: $rp"
        install_name_tool -delete_rpath "$rp" "$macho" || fail=1
    done

    # install_name_tool invalidates the existing code signature; an invalid
    # (as opposed to ad-hoc) signature gets the process SIGKILLed on load.
    # Re-sign ad hoc here; 05_codesign.sh replaces these for release.
    if [[ -n "$bad_refs$bad_rpaths" ]]; then
        codesign --force --sign - "$macho"
    fi
done < <(find "$PYTHON_DIR" -type f \( -name "*.so" -o -name "*.dylib" -o -perm +111 \) -print0)

echo "--- LC_RPATH audit (should all be @-relative or empty) ---"
find "$PYTHON_DIR" \( -name "*.so" -o -name "*.dylib" \) -o \( -type f -perm +111 -path "*/bin/*" \) \
    | while read -r f; do
        file "$f" | grep -q "Mach-O" || continue
        rp=$(otool -l "$f" | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}')
        [[ -n "$rp" ]] && echo "$f: $rp"
    done
exit $fail
