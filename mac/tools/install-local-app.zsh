#!/bin/zsh
set -euo pipefail

export LC_ALL=C

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"
product_name='jgalbs cod4'
bundle_name="${product_name}.app"
bundle_identifier='com.joshgalbreath.jgalbs-cod4'
applications_dir='/Applications'
destination="${applications_dir}/${bundle_name}"
previous_destination="${destination}.previous"
source_path="${repo_dir}/dist/${bundle_name}"
replace_existing=0
add_to_dock=0
dry_run=0
mounted_dmg=''
mount_dir=''
work_dir=''

usage() {
    cat <<'EOF'
usage: install-local-app.zsh [options]

Safely install a local jgalbs cod4 app or DMG into /Applications.

Options:
  --source PATH   Source app bundle or DMG (default: dist/jgalbs cod4.app)
  --replace       Replace an existing install, preserving it as .app.previous
  --add-to-dock   Add the installed app to the current user's Dock using dockutil
  --dry-run       Validate the source and show the plan without changing the system
  --help          Show this help

Dock placement is opt-in. This script does not remove quarantine attributes.
EOF
}

fail() {
    print -u2 -- "install-local-app: $*"
    exit 1
}

cleanup() {
    if [[ -n "${mounted_dmg}" && -n "${mount_dir}" && -d "${mount_dir}" ]]; then
        if ! /usr/bin/hdiutil detach -quiet "${mount_dir}" >/dev/null 2>&1; then
            if /sbin/mount | /usr/bin/grep -F " on ${mount_dir} (" >/dev/null; then
                print -u2 -- "Could not detach ${mount_dir}; preserving its temporary directory."
                work_dir=''
            fi
        fi
    fi
    if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
        /bin/rm -rf -- "${work_dir}"
    fi
}
trap cleanup EXIT INT TERM

validate_app() {
    local app="$1"
    local plist="${app}/Contents/Info.plist"
    local display_name executable identifier minimum_version architectures

    [[ -d "${app}" && -f "${plist}" ]] || {
        print -u2 -- "Invalid app bundle: ${app}"
        return 1
    }
    display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${plist}" 2>/dev/null)" || return 1
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${plist}" 2>/dev/null)" || return 1
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" 2>/dev/null)" || return 1
    minimum_version="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${plist}" 2>/dev/null)" || return 1

    [[ "${display_name}" == "${product_name}" ]] || {
        print -u2 -- "Unexpected app name: ${display_name}"
        return 1
    }
    [[ "${executable}" == "${product_name}" ]] || {
        print -u2 -- "Unexpected executable name: ${executable}"
        return 1
    }
    [[ "${identifier}" == "${bundle_identifier}" ]] || {
        print -u2 -- "Unexpected bundle identifier: ${identifier}"
        return 1
    }
    [[ "${minimum_version}" == '15.5' ]] || {
        print -u2 -- "Unexpected minimum macOS version: ${minimum_version}"
        return 1
    }
    [[ -x "${app}/Contents/MacOS/${executable}" ]] || {
        print -u2 -- "App executable is missing or not executable."
        return 1
    }
    architectures="$(/usr/bin/lipo -archs "${app}/Contents/MacOS/${executable}" 2>/dev/null)" || return 1
    [[ " ${architectures} " == *' arm64 '* ]] || {
        print -u2 -- "App executable does not contain arm64."
        return 1
    }
    /usr/bin/codesign --verify --deep --strict "${app}" >/dev/null 2>&1 || {
        print -u2 -- "Code-signature verification failed."
        return 1
    }
    local required_notice
    for required_notice in \
        'GPL-3.0.txt' \
        'NOTICE.txt' \
        'THIRD-PARTY-NOTICES.txt' \
        'SOURCE-NOTICE.txt'; do
        [[ -s "${app}/Contents/Resources/${required_notice}" ]] || {
            print -u2 -- "Required notice is missing: ${required_notice}"
            return 1
        }
    done
}

run_for_applications() {
    if [[ -w "${applications_dir}" ]]; then
        "$@"
    else
        /usr/bin/sudo "$@"
    fi
}

while (( $# > 0 )); do
    case "$1" in
        (--source)
            (( $# >= 2 )) || fail '--source requires a path'
            source_path="$2"
            shift 2
            ;;
        (--replace)
            replace_existing=1
            shift
            ;;
        (--add-to-dock)
            add_to_dock=1
            shift
            ;;
        (--dry-run)
            dry_run=1
            shift
            ;;
        (--help|-h)
            usage
            exit 0
            ;;
        (*)
            fail "unknown option: $1"
            ;;
    esac
done

(( EUID != 0 )) || fail 'run as your normal login user; the script invokes sudo only when /Applications requires it'
[[ -e "${source_path}" ]] || fail "source does not exist: ${source_path}"
[[ ! -L "${source_path}" ]] || fail 'source must not be a symbolic link'
source_path="${source_path:A}"
[[ ! -L "${destination}" ]] || fail "refusing symbolic-link destination: ${destination}"
[[ ! -L "${previous_destination}" ]] || fail "refusing symbolic-link rollback path: ${previous_destination}"

if (( add_to_dock )); then
    (( $+commands[dockutil] )) || fail 'Dock placement requires dockutil; install it with: brew install dockutil'
fi

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jgalbs-cod4-install.XXXXXX")"
staged_app="${work_dir}/${bundle_name}"

if [[ -d "${source_path}" && "${source_path:t}" == "${bundle_name}" ]]; then
    /usr/bin/ditto "${source_path}" "${staged_app}"
elif [[ -f "${source_path}" && "${source_path:l}" == *.dmg ]]; then
    /usr/bin/hdiutil verify "${source_path}" >/dev/null || fail 'DMG verification failed'
    if /usr/bin/hdiutil info | /usr/bin/grep -F "${source_path}" >/dev/null; then
        fail 'DMG is already attached; detach its existing volume before installing'
    fi
    mount_dir="${work_dir}/mounted"
    /bin/mkdir "${mount_dir}"
    mounted_dmg="${source_path}"
    /usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "${mount_dir}" "${source_path}"
    [[ -d "${mount_dir}/${bundle_name}" ]] || fail "DMG does not contain ${bundle_name} at its root"
    /usr/bin/ditto "${mount_dir}/${bundle_name}" "${staged_app}"
    /usr/bin/hdiutil detach -quiet "${mount_dir}"
    mounted_dmg=''
else
    fail 'source must be the exact app bundle or a .dmg file'
fi

validate_app "${staged_app}" || fail 'staged app validation failed'

if [[ -e "${destination}" && ${replace_existing} -eq 0 ]]; then
    fail "${destination} already exists; rerun with --replace to preserve and replace it"
fi
if [[ -e "${destination}" && -e "${previous_destination}" ]]; then
    fail "refusing to overwrite existing rollback copy: ${previous_destination}"
fi

if (( dry_run )); then
    print "Validated: ${source_path}"
    if [[ -e "${destination}" ]]; then
        print "Would preserve: ${destination} -> ${previous_destination}"
    fi
    print "Would install: ${destination}"
    if (( add_to_dock )); then
        print "Would add to current user's Dock: ${destination}"
    fi
    print 'Dry run complete; no system changes were made.'
    exit 0
fi

preserved_previous=0
if [[ -e "${destination}" ]]; then
    run_for_applications /bin/mv "${destination}" "${previous_destination}"
    preserved_previous=1
fi

install_ok=1
run_for_applications /usr/bin/ditto "${staged_app}" "${destination}" || install_ok=0
if (( install_ok )); then
    validate_app "${destination}" || install_ok=0
fi

if (( ! install_ok )); then
    print -u2 'Installation validation failed; rolling back.'
    if [[ -e "${destination}" ]]; then
        run_for_applications /bin/rm -rf -- "${destination}"
    fi
    if (( preserved_previous )); then
        run_for_applications /bin/mv "${previous_destination}" "${destination}"
    fi
    fail 'installation failed; the previous app was restored when one existed'
fi

print "Installed: ${destination}"
if (( preserved_previous )); then
    print "Preserved rollback copy: ${previous_destination}"
fi

if (( add_to_dock )); then
    if dockutil --find "${product_name}" >/dev/null 2>&1; then
        print 'Dock already contains jgalbs cod4; left it unchanged.'
    else
        dockutil --add "${destination}" --no-restart
        /usr/bin/killall Dock >/dev/null 2>&1 || true
        print "Added jgalbs cod4 to the current user's Dock."
    fi
else
    print 'Dock unchanged. Use --add-to-dock to opt in.'
fi
