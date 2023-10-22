#!/bin/sh
#
# NOTE: This script is intentionally written with portable shell constructs
#       with the aim and hope to work in different interpreters, so it is a
#       bit dumber and less efficient than could be achieved with the more
#       featured shells in the spectrum.
# NOTE ALSO: The configuration parser in this script is not meant to be a
#       reference or 100% compliant with what the binary code uses; its aim
#       is to just pick out some strings relevant for tracking config changes.
#
# Copyright (C) 2016-2020 Eaton
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
#! \file    nut-driver-enumerator.sh(.in)
#  \author  Jim Klimov <EvgenyKlimov@eaton.com>
#  \brief   Enumerate NUT devices for service-unit instance configuration
#  \details This script allows to enumerate UPSes in order to produce the
#           individual service unit instances for each defined configuration.
#           It assumes the user has adequate permissions to inspect and create
#           services (e.g. is a root or has proper RBAC profiles to do so).
#           It helps service frameworks such as Linux systemd and Solaris SMF.
#           When executed, this script looks for all configured ups.conf
#           sections and registered service instances, and makes these two
#           lists match up. It has also a mode to do this in a loop, to keep
#           checking for differences and applying them, on systems where it's
#           problematic to trigger it in response to FS event notifications.
#           Returns exit codes:
#               0   Sections and services already match up
#               42  Sections and services differed, but now match up -
#                   now the caller should likely restart some services.
#                   Note that the drivers' service instances were started or
#                   stopped as required (by AUTO_START=yes) - but maybe the
#                   upsd or upsmon services should restart. If you pass envvar
#                   REPORT_RESTART_42=no then this codepath would return 0.
#                   In default mode, such non-null reconfiguration should cause
#                   the nut-driver-enumerator service to restart and this would
#                   propagate to other NUT services that depend on it.
#               13  Sections and services differed, and still do not match up
#               1   Bad inputs, e.g. unrecognized service management framework
#               2   Absent or unreadable ups.conf file
#

# NOTE: Currently found caveats that might be solved later but require
# considerable effort:
# * Solaris SMF constrains the syntax of valid strings for instance names
#   (e.g. not starting with a digit, no period chars) which blocks creation
#   of some UPS driver instances. This might be worked around by hashing
#   the device name e.g. to base64 (and un-hashing instance name when calling
#   upsdrvctl), but is not quite user-friendly. Also can store device name
#   in a service attribute while mangling the instance name to a valid subset.
#   Comparisons (if devices are already wrapped) becomes more complicated in
#   the script in either case, as well as in the service startup method.
# ** The `+` `/` `=` characters from base64 are also invalid for SMF instance
#    name, but the first two can be sed'ed to `-` `_`  and back, for example.
#    Some prefix word is also needed (avoid starting with a digit).
#    The trailing padding `=` can be dropped, and added until we get a
#    non-empty decode. Conversions can be done by
#    `echo "$string" | openssl base64 -e|-d`
# * Dummy-UPS services that "proxy" another locally defined section are
#   essentially a circular dependency for upsd. While the system might
#   start-up lacking a driver, there should be some timer to re-enable
#   failed not-disabled drivers (would be useful in any case though).

# Directory where NUT configs are located, e.g. /etc/nut or /etc/ups
# Set at package configuration, compiled into daemons and drivers
prefix="/usr/local"
[ -n "${NUT_CONFPATH-}" ] || NUT_CONFPATH="${prefix}/etc"
# Technically this should be a distribution-dependent value configured
# during package build. But everyone has it the same from systemd defaults:
[ -n "${SYSTEMD_CONFPATH-}" ] || SYSTEMD_CONFPATH="/etc/systemd/system"

if [ -n "$ZSH_VERSION" ]; then
    ### Problem: loops like `for UPS in $UPSLIST` do not separate
    ### the UPSLIST into many tokens but use it as one string.
    echo "FATAL: zsh is not supported in this script" >&2
    exit 1
#    setopt noglob
#    setopt +F
#    IFS="`printf ' \t\r\n'`" ; export IFS
fi

if set | egrep '^(shell|version|t?csh)' | egrep 't?csh' >/dev/null ; then
    echo "FATAL: csh or tcsh is not supported in this script" >&2
    exit 1
fi

# Third-party services to depend on (can be overridden by config file)
### Note that for systemd+udev integration, it may be better to set up
### triggers in udev, see e.g.
###   http://stackoverflow.com/questions/18463755/linux-start-daemon-on-connected-usb-serial-dongle
### Also can tune whether a driver "Wants" another service (would consider
### ordering if that one is enabled, but live if it is disabled), or if it
### "Requires" that (would cause that to start).
DEPSVC_USB_SYSTEMD="systemd-udev.service systemd-udev-settle.service"
DEPREQ_USB_SYSTEMD="Wants"
DEPSVC_NET_FULL_SYSTEMD="network-online.target systemd-resolved.service ifplugd.service"
DEPREQ_NET_FULL_SYSTEMD="Wants"
DEPSVC_NET_LOCAL_SYSTEMD="network.target"
DEPREQ_NET_LOCAL_SYSTEMD="Wants"
SVCNAME_SYSTEMD="nut-driver"

# Some or all of these FMRIs may be related to dynamically changing hardware
#   require_all) ;; # All cited services are running (online or degraded)
#   require_any) ;; # At least one of the cited services is running
#   optional_all) ;; # (All) cited services are running or would not run
#                  # without administrative action (disabled, maintenance,
#                  # not present, or are waiting for dependencies which do
#                  # not start without administrative action).
DEPSVC_USB_SMF="svc:/system/hotplug:default svc:/system/dbus:default svc:/system/hal:default svc:/milestone/devices:default"
DEPREQ_USB_SMF="optional_all"
# By default there are several physical network FMRIs shipped and at most
# only one is enabled on a particular system (e.g. :default or :nwam)
DEPSVC_NET_FULL_SMF="svc:/network/physical svc:/milestone/name-services"
DEPREQ_NET_FULL_SMF="optional_all"
DEPSVC_NET_LOCAL_SMF="svc:/network/loopback:default"
DEPREQ_NET_LOCAL_SMF="optional_all"
SVCNAME_SMF="svc:/system/power/nut-driver"

[ -z "${NUT_DRIVER_ENUMERATOR_CONF-}" ] && \
    NUT_DRIVER_ENUMERATOR_CONF="${NUT_CONFPATH}/nut-driver-enumerator.conf"

[ -s "${NUT_DRIVER_ENUMERATOR_CONF}" ] && \
    echo "Sourcing config file: ${NUT_DRIVER_ENUMERATOR_CONF}" && \
    . "${NUT_DRIVER_ENUMERATOR_CONF}"

[ -z "${UPSCONF-}" ] && \
    UPSCONF="${NUT_CONFPATH}/ups.conf"

# Start a freshly-registered unit?
[ -z "${AUTO_START-}" ] && AUTO_START=yes

# We avoid regex '\t' which gets misinterpreted by some tools
TABCHAR="`printf '\t'`" || TABCHAR='	'

if [ -z "${SERVICE_FRAMEWORK-}" ] ; then
    [ -x /usr/sbin/svcadm ] && [ -x /usr/sbin/svccfg ] && [ -x /usr/bin/svcs ] && [ -x /usr/bin/svcprop ] && \
        SERVICE_FRAMEWORK="smf"
    [ -z "${SERVICE_FRAMEWORK-}" ] && \
        [ -x /bin/systemctl ] && \
        SERVICE_FRAMEWORK="systemd"
fi

# Optionally use Coreutils timeout to limit the
# (potentially hanging) calls to systemd tools...
# Should not hurt with SMF too, if it ever misbehaves.
if [ -z "${TIMEOUT_CMD+x}" ]; then
    # Envvar not set at all (set but empty is okay, caller wants that then)
    TIMEOUT_CMD=""
    TIMEOUT_ARGS=""
    if which timeout 2>/dev/null >/dev/null ; then
        # Systemd default timeout for unit start/stop
        TIMEOUT_CMD="timeout"
        TIMEOUT_ARGS="90s"
    fi
fi

# Cache needed bits of ups.conf to speed up later parsing. Note that these
# data are needed for most operations, and populated by upslist_readFile()
UPSCONF_DATA=""
# Subset of normalized data above that only has sections, drivers and ports
UPSCONF_DATA_SDP=""

# List of configured UPSes in the config-file
UPSLIST_FILE=""
# List of configured service instances for UPS drivers
UPSLIST_SVCS=""

# Framework-specific implementations are generally hooked here:
hook_registerInstance=""
hook_unregisterInstance=""
hook_refreshSupervizor=""
hook_listInstances=""
hook_listInstances_raw=""
hook_validInstanceName=""
hook_validFullUnitName=""
hook_validInstanceSuffixName=""
hook_getSavedMD5=""
hook_setSavedMD5=""
hook_restart_upsd=""
hook_restart_drv=""

case "${SERVICE_FRAMEWORK-}" in
    smf)
        hook_registerInstance="smf_registerInstance"
        hook_unregisterInstance="smf_unregisterInstance"
        hook_refreshSupervizor="smf_refreshSupervizor"
        hook_listInstances="smf_listInstances"
        hook_listInstances_raw="smf_listInstances_raw"
        hook_validInstanceName="smf_validInstanceName"
        hook_validFullUnitName="smf_validFullUnitName"
        hook_validInstanceSuffixName="smf_validInstanceSuffixName"
        hook_getSavedMD5="smf_getSavedMD5"
        hook_setSavedMD5="smf_setSavedMD5"
        hook_restart_upsd="smf_restart_upsd"
        hook_restart_drv="smf_restart_drv"
        ;;
    systemd)
        hook_registerInstance="systemd_registerInstance"
        hook_unregisterInstance="systemd_unregisterInstance"
        hook_refreshSupervizor="systemd_refreshSupervizor"
        hook_listInstances="systemd_listInstances"
        hook_listInstances_raw="systemd_listInstances_raw"
        hook_validInstanceName="systemd_validInstanceName"
        hook_validFullUnitName="systemd_validFullUnitName"
        hook_validInstanceSuffixName="systemd_validInstanceSuffixName"
        hook_getSavedMD5="systemd_getSavedMD5"
        hook_setSavedMD5="systemd_setSavedMD5"
        hook_restart_upsd="systemd_restart_upsd"
        hook_restart_drv="systemd_restart_drv"
        ;;
    selftest)
        hook_registerInstance="selftest_NOOP"
        hook_unregisterInstance="selftest_NOOP"
        hook_refreshSupervizor="selftest_NOOP"
        hook_listInstances="selftest_NOOP"
        hook_listInstances_raw="selftest_NOOP"
        hook_validInstanceName="selftest_NOOP"
        hook_validFullUnitName="selftest_NOOP"
        hook_validInstanceSuffixName="selftest_NOOP"
        hook_getSavedMD5="selftest_NOOP"
        hook_setSavedMD5="selftest_NOOP"
        hook_restart_upsd="selftest_NOOP"
        hook_restart_drv="selftest_NOOP"
        ;;
    "")
        echo "Error detecting the service-management framework on this OS" >&2
        exit 1
        ;;
    *)
        echo "Error: User provided an unknown service-management framework '$SERVICE_FRAMEWORK'" >&2
        exit 1
        ;;
esac

selftest_NOOP() {
    echo "NO-OP: Self-testing context does not do systems configuration" >&2
    return 0
}

common_isFiled() {
    [ -n "$UPSLIST_FILE" ] && \
    for UPSF in $UPSLIST_FILE ; do
        [ "$1" = "$UPSF" ] && return 0
        [ "`$hook_validInstanceName "$UPSF"`" = "$1" ] && return 0
    done
    return 1
}

common_isRegistered() {
    [ -n "$UPSLIST_SVCS" ] && \
    for UPSS in $UPSLIST_SVCS ; do
        [ "$1" = "$UPSS" ] && return 0
        [ "`$hook_validInstanceName "$1"`" = "$UPSS" ] && return 0
    done
    return 1
}

upslist_equals() {
    # Compare pre-sorted list of DEVICES ($1) and SVCINSTs ($2) including
    # the possible mangling for service names. Return 0 if lists describe
    # exactly same set of devices and their services.
    # Note: This logic only checks the names, not the contents of device
    # sections, so re-definitions of an existing device configuration
    # would not trigger a service restart by itself. Such deeper check
    # belongs in a different routine, see upssvcconf_checksum_unchanged().

    # Trivial case 0: one string is empty, another is not
    # Note: `echo '' | wc -l` == "1" not "0"!
    [ -n "$1" -a -z "$2" ] && return 1
    [ -z "$1" -a -n "$2" ] && return 1

    # Trivial case 1: equal strings
    [ "$1" = "$2" ] && return 0
    # Trivial case 2: different amount of entries
    [ "`echo "$1" | wc -l`" = "`echo "$2" | wc -l`" ] || return $?

    _TMP_DEV_SVC=""
    for _DEV in $1 ; do
        DEVINST="`$hook_validInstanceName "$_DEV"`"
        for _SVC in $2 ; do
            [ "$_DEV" = "$_SVC" ] \
            || [ "$DEVINST" = "$_SVC" ] \
            && { [ -z "$_TMP_DEV_SVC" ] \
                 && _TMP_DEV_SVC="$_DEV = $_SVC" \
                 || _TMP_DEV_SVC="$_TMP_DEV_SVC
$_DEV = $_SVC" ; }
        done
    done

    # Input was not empty; did anything in output fit?
    [ -z "$_TMP_DEV_SVC" ] && return 1

    # Exit code : is the built mapping as long as the source list(s)?
    [ "`echo "$1" | wc -l`" = "`echo "$_TMP_DEV_SVC" | wc -l`" ]
}

upssvcconf_checksum_unchanged() {
    # $1 = dev, $2 = svc
    # compare checksums of the configuration section from the file and the
    # stashed configuration in a service instance (if any).
    # FIXME : optimize by caching, we likely have quite a few requests
    [ "`upsconf_getSection_MD5 "$1"`" = "`$hook_getSavedMD5 "$2"`" ]
}

upslist_checksums_unchanged() {
    # For each device and its corresponding unit, compare checksums of the
    # configuration section from the file and the stashed configuration in
    # a service instance. Prints a list of mismatching service names that
    # should get reconfigured.
    [ -z "$1" -o -z "$2" ] && return 1

    _TMP_SVC=""
    for _DEV in $1 ; do
        DEVINST="`$hook_validInstanceName "$_DEV"`"
        for _SVC in $2 ; do
            if [ "$_DEV" = "$_SVC" ] \
            || [ "$DEVINST" = "$_SVC" ] \
            ; then
                upssvcconf_checksum_unchanged "$_DEV" "$_SVC" || \
                { [ -z "$_TMP_SVC" ] \
                  && _TMP_SVC="$_SVC" \
                  || _TMP_SVC="$_TMP_SVC
$_SVC" ; }
            fi
        done
    done
    [ -z "$_TMP_SVC" ] && return 0
    echo "$_TMP_SVC"
    return 1
}

upsconf_getSection_content() {
    # "$1" = name of ups.conf section to display in whole, from whatever
    # comes on stdin (file or a pre-made normalized variable)
    # empty "$1" means the global config (before any sections)
    #
    # NOTE (TODO?): This routine finds the one NUT device section, prints it
    # and returns when the section is over. It currently does not cover (in
    # a way allowing to do it efficiently) selection of several sections,
    # or storing each section content in some array or dynamic variables
    # (as would be better fit for portable shells) to later address them
    # quickly without re-parsing the file or big envvar many times.
    #

    CURR_SECTION=""
    SECTION_CONTENT=""
    RES=1
    [ -n "$1" ] || RES=0
    while read LINE ; do
        case "$LINE" in
            \["$1"\])
                if [ "$RES" = 0 ]; then
                    # We have already displayed a section, here is a new one,
                    # and this routine only displays one (TODO: toggle?)
                    break
                fi
                SECTION_CONTENT="$LINE"
                CURR_SECTION="$1"
                RES=0
                continue
                ;;
            \[*\ *\]|\[*"$TABCHAR"*\])
                # Note that section-name brackets should contain a single token
                # Fall through to add the line to contents of existing section
                ;;
            \[*\])
                [ "$CURR_SECTION" = "$1" ] && break
                # Use a value that can not be a section name here:
                CURR_SECTION="[]"
                continue
                ;;
            "") continue ;;
            *)  ;; # Fall through to add the line to contents of existing section
        esac
        if [ "$CURR_SECTION" = "$1" ]; then
            if [ -n "$SECTION_CONTENT" ]; then
                SECTION_CONTENT="$SECTION_CONTENT
$LINE"
            else
                SECTION_CONTENT="$LINE"
            fi
        fi
    done

    if [ -n "$SECTION_CONTENT" ]; then
        echo "$SECTION_CONTENT"
    fi

    [ "$RES" = 0 ] || echo "ERROR: Section [$1] was not found in the '$UPSCONF' file" >&2
    return $RES
}

upsconf_getSection() {
    # Use the whole output of normalization parser
    upslist_normalizeFile_once || return    # Propagate errors upwards
    upsconf_getSection_content "$@" << EOF
${UPSCONF_DATA}
EOF
}

upsconf_getSection_MD5() {
    calc_md5 "`upsconf_getSection "$@"`"
}

upsconf_getSection_SDP() {
    # Use the section-driver-port subset
    upslist_normalizeFile_once || return    # Propagate errors upwards
    upsconf_getSection_content "$@" << EOF
${UPSCONF_DATA_SDP}
EOF
}

upsconf_getValue() {
    # "$1" = name of ups.conf section, may be empty for global config
    # "$2..$N" = name of config key; we will echo its value
###    [ -n "$1" ] || return $?
    [ -n "$2" ] || return $?
    [ -n "$GETSECTION" ] || GETSECTION="upsconf_getSection"
    CURR_SECTION="" # Gets set by a GETSECTION implementation
    RES=0

    # Note: Primary aim of this egrep is to pick either assignments or flags
    # As a by-product it can be used to test if a particular value is set ;)
    SECTION_CONTENT="`$GETSECTION "$1"`" || return
    shift
    KEYS="$*"

    while [ "$#" -gt 0 ] ; do
        RES_L=0
        VALUE=""

        LINE="`echo "$SECTION_CONTENT" | egrep '(^'"$1"'=|^'"$1"'$)'`" \
        && VALUE="$(echo "$LINE" | sed -e "s,^$1=,," -e 's,^\"\(.*\)\"$,\1,' -e "s,^'\(.*\)'$,\1,")" \
        || RES_L=$?

        [ "$RES_L" = 0 ] || { RES="$RES_L" ; echo "ERROR: Section [$CURR_SECTION] or key '$1' in it was not found in the '$UPSCONF' file" >&2 ; }

        echo "$VALUE"
        shift
    done

    [ "$RES" = 0 ] || echo "ERROR: Section [$CURR_SECTION] or key(s) '$KEYS' in it was not found in the '$UPSCONF' file" >&2
    return $RES
}

upsconf_getDriver() {
    # "$1" = name of ups.conf section; return (echo) the driver name used there
    # In the context this function is used, UPSCONF exists and section is there
    GETSECTION="upsconf_getSection_SDP" upsconf_getValue "$1" "driver"
    return $?
}

upsconf_getPort() {
    # "$1" = name of ups.conf section; return (echo) the "port" name used there
    # In the context this function is used, UPSCONF exists and section is there
    GETSECTION="upsconf_getSection_SDP" upsconf_getValue "$1" "port"
    return $?
}

upsconf_getDriverMedia() {
    # "$1" = name of ups.conf section; return (echo) name and type of driver as
    # needed for dependency evaluation (what services we must depend on for this
    # unit), newline-separated (drvname<EOL>type). Empty type for unclassified
    # results, assuming no known special dependencies (note that depending on
    # particular system's physics, both serial and network media may need USB).
    CURR_DRV="`upsconf_getDriver "$1"`" || return $?
    case "$CURR_DRV" in
        *netxml*|*snmp*|*ipmi*|*powerman*|*-mib*|*avahi*|*apcupsd*)
            printf '%s\n%s\n' "$CURR_DRV" "network" ; return ;;
        *usb*)
            printf '%s\n%s\n' "$CURR_DRV" "usb" ; return ;;
        nutdrv_qx) # May be direct serial or USB
            CURR_PORT="`upsconf_getPort "$1"`" || CURR_PORT=""
            case "$CURR_PORT" in
                auto|/dev/*usb*|/dev/*hid*)
                    printf '%s\n%s\n' "$CURR_DRV" "usb" ; return ;;
                /dev/*)
                    # See drivers/nutdrv_qx.c :: upsdrv_initups() for a list
                    if [ -n "`upsconf_getValue "$1" 'subdriver' 'vendorid' 'productid' 'vendor' 'product' 'serial' 'bus' 'langid_fix'`" ] \
                    ; then
                        printf '%s\n%s\n' "$CURR_DRV" "usb" ; return
                    else
                        printf '%s\n%s\n' "$CURR_DRV" "serial" ; return
                    fi
                    ;;
                *)
                    printf '%s\n%s\n' "$CURR_DRV" "" ; return ;;
            esac
            ;;
        *dummy*|*clone*) # May be networked (proxy to remote NUT)
            CURR_PORT="`upsconf_getPort "$1"`" || CURR_PORT=""
            case "$CURR_PORT" in
                *@localhost|*@|*@127.0.0.1|*@::1)
                    printf '%s\n%s\n' "$CURR_DRV" "network-localhost" ; return ;;
                *@*)
                    printf '%s\n%s\n' "$CURR_DRV" "network" ; return ;;
                *)
                    printf '%s\n%s\n' "$CURR_DRV" "" ; return ;;
            esac
            ;;
        *)  printf '%s\n%s\n' "$CURR_DRV" "" ; return ;;
    esac
}

upsconf_getMedia() {
    _DRVMED="`upsconf_getDriverMedia "$1"`" || return
    echo "$_DRVMED" | tail -n +2
    return 0
}

upsconf_debug() {
    _DRV="`upsconf_getDriver "$1"`"
    _PRT="`upsconf_getPort "$1"`"
    _MED="`upsconf_getMedia "$1"`"
    _MD5="`upsconf_getSection_MD5 "$1"`"
    NAME_MD5="`calc_md5 "$1"`"
    echo "INST: ${NAME_MD5}~[$1]: DRV='$_DRV' PORT='$_PRT' MEDIA='$_MED' SECTIONMD5='$_MD5'"
}

calc_md5() {
    # Tries several ways to produce an MD5 of the "$1" argument
    _MD5="`echo "$1" | md5sum 2>/dev/null | awk '{print $1}'`" && [ -n "$_MD5" ] || \
    { _MD5="`echo "$1" | openssl dgst -md5 2>/dev/null | awk '{print $NF}'`" && [ -n "$_MD5" ]; } || \
    return 1

    echo "$_MD5"
}

calc_md5_file() {
    # Tries several ways to produce an MD5 of the file named by "$1" argument
    [ -s "$1" ] || return 2

    _MD5="`md5sum 2>/dev/null < "$1" | awk '{print $1}'`" && [ -n "$_MD5" ] || \
    { _MD5="`openssl dgst -md5 2>/dev/null < "$1" | awk '{print $NF}'`" && [ -n "$_MD5" ]; } || \
    return 1

    echo "$_MD5"
}

smf_validFullUnitName() {
    case "$1" in
        *:*) echo "$1" ;;
        *)   echo "$SVCNAME_SMF:$1" ;;
    esac
}
smf_validInstanceName() {
    echo "MD5_`calc_md5 "$1"`"
}
smf_validInstanceSuffixName() {
    case "$1" in
        *:*) echo "$1" | sed 's,^.*:\([^:]*\)$,\1,' ;;
        *)   echo "$1" ;;
    esac
}
smf_registerInstance() {
    DEVICE="$1"
    SVCINST="$1"
    /usr/sbin/svccfg -s nut-driver add "$DEVICE" || \
    { SVCINST="`smf_validInstanceName "$1"`" && \
      /usr/sbin/svccfg -s nut-driver add "$SVCINST" || return ; }
    echo "Added instance: 'nut-driver:$SVCINST' for NUT configuration section '$DEVICE'" >&2

    DEPSVC=""
    DEPREQ=""
    _MED="`upsconf_getMedia "$DEVICE"`"
    case "$_MED" in
        usb)
            DEPSVC="$DEPSVC_USB_SMF"
            DEPREQ="$DEPREQ_USB_SMF" ;;
        network-localhost)
            DEPSVC="$DEPSVC_NET_LOCAL_SMF"
            DEPREQ="$DEPREQ_NET_LOCAL_SMF" ;;
        network)
            DEPSVC="$DEPSVC_NET_FULL_SMF"
            DEPREQ="$DEPREQ_NET_FULL_SMF" ;;
        serial) ;;
        '') ;;
        *)  echo "WARNING: Unexpected NUT media type ignored: '$_MED'" >&2 ;;
    esac

    TARGET_FMRI="nut-driver:$SVCINST"
    if [ -n "$DEPSVC" ]; then
        [ -n "$DEPREQ" ] || DEPREQ="optional_all"
        echo "Adding '$DEPREQ' dependency for '$SVCINST' on '$DEPSVC'..."

        DEPPG="nut-driver-enumerator-generated"
        RESTARTON="refresh"
        /usr/sbin/svccfg -s "$TARGET_FMRI" addpg "$DEPPG" dependency && \
        /usr/sbin/svccfg -s "$TARGET_FMRI" setprop "$DEPPG"/grouping = astring: "$DEPREQ" && \
        /usr/sbin/svccfg -s "$TARGET_FMRI" setprop "$DEPPG"/restart_on = astring: "$RESTARTON" && \
        /usr/sbin/svccfg -s "$TARGET_FMRI" setprop "$DEPPG"/type = astring: service && \
        /usr/sbin/svccfg -s "$TARGET_FMRI" setprop "$DEPPG"/entities = fmri: "($DEPSVC)" && \
        echo "OK" || echo "FAILED to define the dependency" >&2
    fi

    smf_setSavedMD5 "$SVCINST" "`upsconf_getSection_MD5 "$DEVICE"`"

    /usr/sbin/svcadm refresh "${TARGET_FMRI}" || return
    if [ "$AUTO_START" = yes ] ; then
        /usr/sbin/svcadm clear "${TARGET_FMRI}" 2>/dev/null || true
        /usr/sbin/svcadm enable "${TARGET_FMRI}" || return
        echo "Started instance: 'nut-driver:$SVCINST' for NUT configuration section '$DEVICE'" >&2
    fi
}
smf_unregisterInstance() {
    echo "Removing instance: 'nut-driver:$1' ..." >&2
    /usr/sbin/svcadm disable -ts 'nut-driver:'"$1" || false
    /usr/sbin/svccfg -s nut-driver delete "$1"
}
smf_refreshSupervizor() {
    :
}
smf_listInstances_raw() {
    # Newer versions have pattern matching; older SMF might not have this luxury
    /usr/bin/svcs -a -H -o fmri | egrep '/nut-driver:'
}
smf_listInstances() {
    smf_listInstances_raw | sed 's/^.*://' | sort -n
}
smf_getSavedMD5() {
    # Query service instance $1
    PG="nut-driver-enumerator-generated-checksum"
    PROP="SECTION_CHECKSUM"

    if [ -n "$1" ]; then
        TARGET_FMRI="nut-driver:$1"
    else
        # Global section
        TARGET_FMRI="nut-driver"
        PROP="SECTION_CHECKSUM_GLOBAL"
    fi

    # Note: lookups for GLOBAL cause each service instance to show up
    /usr/bin/svcprop -p "$PG/$PROP" "$TARGET_FMRI" | head -1 | awk '{print $NF}'
}
smf_setSavedMD5() {
    # Save checksum value $2 into service instance $1
    PG="nut-driver-enumerator-generated-checksum"
    PROP="SECTION_CHECKSUM"

    if [ -n "$1" ]; then
        TARGET_FMRI="nut-driver:$1"
    else
        # Global section
        TARGET_FMRI="nut-driver"
        PROP="SECTION_CHECKSUM_GLOBAL"
    fi

    /usr/sbin/svccfg -s "$TARGET_FMRI" delprop "$PG" || true
    /usr/sbin/svccfg -s "$TARGET_FMRI" addpg "$PG" application && \
    /usr/sbin/svccfg -s "$TARGET_FMRI" setprop "$PG/$PROP" = astring: "$2"
    [ $? = 0 ] && echo "OK" || { echo "FAILED to stash the checksum">&2 ; return 1 ; }
    /usr/sbin/svcadm refresh "${TARGET_FMRI}" || return
}
smf_restart_upsd() {
    echo "Restarting NUT data server to make sure it knows new configuration..."
    /usr/sbin/svcadm enable "nut-server" 2>/dev/null
    /usr/sbin/svcadm clear "nut-server" 2>/dev/null
    /usr/sbin/svcadm refresh "nut-server" || \
    /usr/sbin/svcadm restart "nut-server"
}
smf_restart_drv() {
    echo "Restarting NUT driver instance '$1' to make sure it knows new configuration..."
    /usr/sbin/svcadm enable "nut-driver:$1" 2>/dev/null
    /usr/sbin/svcadm clear "nut-driver:$1" 2>/dev/null
    /usr/sbin/svcadm refresh "nut-driver:$1" || \
    /usr/sbin/svcadm restart "nut-driver:$1"
}

systemd_validFullUnitName() {
    case "$1" in
        *@*.*) echo "$1" ;;
        *@*) echo "$1.service" ;;
        *)   echo "$SVCNAME_SYSTEMD@$1.service" ;;
    esac
}
systemd_validInstanceName() {
    echo "MD5_`calc_md5 "$1"`"
}
systemd_validInstanceSuffixName() {
    echo "$1" | sed -e 's,^.*@,,' -e 's,\.service$,,'
}
systemd_registerInstance() {
    # Instance is registered by device section name; ultimate name in systemd may differ
    DEVICE="$1"
    SVCINST="$1"
    /bin/systemctl enable 'nut-driver@'"$DEVICE".service || \
    { SVCINST="`systemd_validInstanceName "$1"`" && \
      /bin/systemctl enable 'nut-driver@'"$SVCINST".service || return ; }
    echo "Enabled instance: 'nut-driver@$SVCINST' for NUT configuration section '$DEVICE'" >&2

    DEPSVC=""
    DEPREQ=""
    _MED="`upsconf_getMedia "$DEVICE"`"
    case "$_MED" in
        usb)
            DEPSVC="$DEPSVC_USB_SYSTEMD"
            DEPREQ="$DEPREQ_USB_SYSTEMD" ;;
        network-localhost)
            DEPSVC="$DEPSVC_NET_LOCAL_SYSTEMD"
            DEPREQ="$DEPREQ_NET_LOCAL_SYSTEMD" ;;
        network)
            DEPSVC="$DEPSVC_NET_FULL_SYSTEMD"
            DEPREQ="$DEPREQ_NET_FULL_SYSTEMD" ;;
        serial) ;;
        '') ;;
        *)  echo "WARNING: Unexpected NUT media type ignored: '$_MED'" >&2 ;;
    esac
    if [ -n "$DEPSVC" ]; then
        [ -n "$DEPREQ" ] || DEPREQ="#Wants"
        echo "Adding '$DEPREQ'+After dependency for '$SVCINST' on '$DEPSVC'..."
        mkdir -p "${SYSTEMD_CONFPATH}/nut-driver@$SVCINST.service.d" && \
        cat > "${SYSTEMD_CONFPATH}/nut-driver@$SVCINST.service.d/nut-driver-enumerator-generated.conf" <<EOF
# Customization generated `date -u` by nut-driver-enumerator for NUT device '$DEVICE'
# DO NOT EDIT: This file would be removed or overwritten by that service
[Unit]
Description=Network UPS Tools - device driver for NUT device '$DEVICE'
${DEPREQ}=${DEPSVC}
After=${DEPSVC}
EOF
        [ $? = 0 ] && echo "OK" || echo "FAILED to define the dependency" >&2
    fi

    systemd_setSavedMD5 "$SVCINST" "`upsconf_getSection_MD5 "$DEVICE"`"

    if [ "$AUTO_START" = yes ] ; then
        systemd_refreshSupervizor || echo "WARNING: Somehow managed to fail systemd_refreshSupervizor()" >&2
        $TIMEOUT_CMD $TIMEOUT_ARGS /bin/systemctl start --no-block 'nut-driver@'"$SVCINST".service || return
        echo "Started instance: 'nut-driver@$SVCINST' for NUT configuration section '$DEVICE'" >&2
    fi
}
systemd_unregisterInstance() {
    echo "Removing instance: 'nut-driver@$1' ..." >&2
    $TIMEOUT_CMD $TIMEOUT_ARGS /bin/systemctl stop 'nut-driver@'"$1".service || \
    $TIMEOUT_CMD $TIMEOUT_ARGS /bin/systemctl stop 'nut-driver@'"$1".service || \
    $TIMEOUT_CMD $TIMEOUT_ARGS /bin/systemctl stop 'nut-driver@'"$1".service || false

    /bin/systemctl disable 'nut-driver@'"$1".service
    rm -rf "${SYSTEMD_CONFPATH}/nut-driver@$1.service.d"
    /bin/systemctl reset-failed 'nut-driver@'"$1".service
}
systemd_refreshSupervizor() {
    /bin/systemctl daemon-reload
}
systemd_listInstances_raw() {
    /bin/systemctl show 'nut-driver@*' -p Id | egrep '=nut-driver' | sed 's,^Id=,,'
}
systemd_listInstances() {
    systemd_listInstances_raw | sed -e 's/^.*@//' -e 's/\.service$//' | sort -n
}
systemd_getSavedMD5() {
    # Query service instance $1 or global section
    PROP="SECTION_CHECKSUM"
    [ -n "$1" ] || PROP="SECTION_CHECKSUM_GLOBAL"
    [ -s "${SYSTEMD_CONFPATH}/nut-driver@$1.service.d/nut-driver-enumerator-generated-checksum.conf" ] \
    && grep "Environment='$PROP=" "${SYSTEMD_CONFPATH}/nut-driver@$1.service.d/nut-driver-enumerator-generated-checksum.conf" | sed -e "s,^Environment='$PROP=,," -e "s,'\$,," \
    || { echo "Did not find '${SYSTEMD_CONFPATH}/nut-driver@$1.service.d/nut-driver-enumerator-generated-checksum.conf' with a $PROP" ; return 1; }
}
systemd_setSavedMD5() {
    # Save checksum value $2 into service instance $1
    PROP="SECTION_CHECKSUM"
    [ -n "$1" ] || PROP="SECTION_CHECKSUM_GLOBAL"
    mkdir -p "${SYSTEMD_CONFPATH}/nut-driver@$1.service.d" && \
    cat > "${SYSTEMD_CONFPATH}/nut-driver@$1.service.d/nut-driver-enumerator-generated-checksum.conf" << EOF
[Service]
Environment='$PROP=$2'
EOF
    [ $? = 0 ] && echo "OK" || { echo "FAILED to stash the checksum">&2 ; return 1 ; }
}
systemd_restart_upsd() {
    # Do not restart/reload if not already running
    case "`/bin/systemctl is-active "nut-server"`" in
        active|unknown) ;; # unknown meant "starting" in our testing...
        failed) echo "Note: nut-server unit was 'failed' - not disabled by user, so (re)starting it (probably had no config initially)" >&2 ;;
        *) return 0 ;;
    esac

    echo "Restarting NUT data server to make sure it knows new configuration..."
    # Note: reload is a better way to go about this, so the
    # data service is not interrupted by re-initialization
    # of the daemon. But systemd/systemctl sometimes stalls...

    $TIMEOUT_CMD $TIMEOUT_ARGS /bin/systemctl reload-or-restart "nut-server" || \
    $TIMEOUT_CMD $TIMEOUT_ARGS /bin/systemctl restart "nut-server"
}

systemd_restart_drv() {
    # Do not restart/reload if not already running
    case "`/bin/systemctl is-active "nut-driver@$1"`" in
        active|unknown) ;;
        *) return 0 ;;
    esac

    echo "Restarting NUT driver instance '$1' to make sure it knows new configuration..."

    # Full restart, e.g. in case we changed the user= in configs
    $TIMEOUT_CMD $TIMEOUT_ARGS /bin/systemctl restart "nut-driver@$1"
}

upslist_normalizeFile_filter() {
    # See upslist_normalizeFile() detailed comments below; this routine
    # is a pipe worker to prepare the text into a simpler expected form.

    # Pick the lines which contain a bracket or assignment character,
    # or a single token (certain keywords come as just NUT "flags"),
    # trim leading and trailing whitespace, comment-only lines, and in
    # assignment lines trim the spaces around equality character and
    # quoting characters around assignment of values without whitespaces.
    # Any whitespace characters around a section name (single token that
    # starts the line and is enclosed in brackets) and a trailing comment
    # are dropped. Note that brackets with spaces inside, and brackets
    # that do not start the non-whitespace payload of the line, are not
    # sections.
    egrep -v '(^$|^#)' | \
    sed -e 's,^['"$TABCHAR"'\ ]*,,' \
        -e 's,^\#.*$,,' \
        -e 's,['"$TABCHAR"'\ ]*$,,' \
        -e 's,^\([^=\ '"$TABCHAR"']*\)['"$TABCHAR"'\ ]*=['"$TABCHAR"'\ ]*,\1=,g' \
        -e 's,=\"\([^\ '"$TABCHAR"']*\)\"$,=\1,' \
        -e 's,^\(\[[^]'"$TABCHAR"'\ ]*\]\)['"$TABCHAR"'\ ]*\(#.*\)*$,\1,' \
    | egrep -v '^$' \
    | egrep '([\[\=]|^[^ '"$TABCHAR"']*$|^[^ '"$TABCHAR"']*[ '"$TABCHAR"']*\#.*$)'
}

upslist_normalizeFile() {
    # Read the ups.conf file and find all defined sections (names of
    # configuration blocks for drivers that connect to a certain device
    # using specified protocol and media); normalize section contents
    # as detailed below, to simplify subsequent parsing and comparison.

    # File contents
    UPSCONF_DATA=""
    UPSCONF_DATA_SDP=""
    if [ -n "$UPSCONF" ] && [ -f "$UPSCONF" ] && [ -r "$UPSCONF" ]; then
        [ ! -s "$UPSCONF" ] \
        && echo "WARNING: The '$UPSCONF' file exists but is empty" >&2 \
        && return 0
        # Ok to continue - we may end up removing all instances
    else
        echo "FATAL: The '$UPSCONF' file does not exist or is not readable" >&2
        return 2
    fi

    # Store a normalized version of NUT configuration file contents.
    # Also use a SDP subset with just section, driver and port info
    # for faster parsing when determining driver-required media etc.
    UPSCONF_DATA="$(upslist_normalizeFile_filter < "$UPSCONF")" \
        && [ -n "$UPSCONF_DATA" ] \
        && UPSCONF_DATA_SDP="`egrep '^(\[.*\]|driver=|port=)' << EOF
$UPSCONF_DATA
EOF`" \
        ||  { echo "Error reading the '$UPSCONF' file or it does not declare any device configurations: nothing left after normalization" >&2
              UPSCONF_DATA=""
              UPSCONF_DATA_SDP=""
            }
}

upslist_normalizeFile_once() {
    # Wrapper that ensures that the parsing is only done once
    # (will re-parse if there were no devices listed on the
    # first time, though)
    [ -z "$UPSCONF_DATA" ] && [ -z "$UPSCONF_DATA_SDP" ] || return 0
    upslist_normalizeFile
}

upslist_readFile() {
    # Use the routine above (unconditionally) to get or update the
    # listing of device sections known at this moment.

    # List of devices from the config file
    UPSLIST_FILE=""
    if [ "$DO_NORMALIZE_ONCE" = yes ]; then
        upslist_normalizeFile_once || return    # Propagate errors upwards
    else
        upslist_normalizeFile || return    # Propagate errors upwards
    fi

    if [ -n "$UPSCONF_DATA" ] ; then
        # Note that section-name brackets should contain a single token
        UPSLIST_FILE="$(echo "$UPSCONF_DATA_SDP" | egrep '^\[[^'"$TABCHAR"'\ ]*\]$' | sed 's,^\[\(.*\)\]$,\1,' | sort -n)" \
            || UPSLIST_FILE=""
        if [ -z "$UPSLIST_FILE" ] ; then
            echo "Error reading the '$UPSCONF' file or it does not declare any device configurations: no section declarations in parsed normalized contents" >&2
        fi
    fi
    # Ok to continue with empty results - we may end up removing all instances
}

upslist_readFile_once() {
    # Wrapper that ensures that the parsing is only done once
    # (will re-parse if there were no devices listed on the
    # first time, though)
    [ -z "$UPSLIST_FILE" ] || return 0
    DO_NORMALIZE_ONCE=yes upslist_readFile
}

upslist_readSvcs() {
    UPSLIST_SVCS="`$hook_listInstances`" || UPSLIST_SVCS=""
    if [ -z "$UPSLIST_SVCS" ] && [ "$1" != "-" ] ; then
        EXPLAIN=""
        [ -z "$1" ] || EXPLAIN=" - $1"
        echo "Error reading the list of ${SERVICE_FRAMEWORK-} service instances for UPS drivers, or none are defined${EXPLAIN}" >&2
        # Ok to continue - we may end up defining new instances
    fi
}

upslist_debug() {
    for UPSF in "" $UPSLIST_FILE ; do
        upsconf_debug "$UPSF"
    done
}

upslist_addSvcs() {
    # Note: This routine registers service instances for device config sections
    # that are not wrapped currently. Support for redefined previously existing
    # sections - is attained by removing the old service instance elsewhere and
    # recreating it here, since any data could change including the dependency
    # list, etc.
    for UPSF in $UPSLIST_FILE ; do
        if ! common_isRegistered "$UPSF" ; then
            echo "Adding new ${SERVICE_FRAMEWORK} service instance for power device [${UPSF}]..." >&2
            $hook_registerInstance "$UPSF"
        fi
    done
}

upslist_delSvcs() {
    for UPSS in $UPSLIST_SVCS ; do
        if ! common_isFiled "$UPSS" ; then
            echo "Dropping old ${SERVICE_FRAMEWORK} service instance for power device [${UPSS}] which is no longer in config file..." >&2
            $hook_unregisterInstance "$UPSS"
        fi
    done
}

upslist_restartSvcs() {
    for UPSS in $UPSLIST_SVCS ; do
        if common_isFiled "$UPSS" ; then
            $hook_restart_drv "$UPSS"
        fi
    done
}

nut_driver_enumerator_main() {
    ################# MAIN PROGRAM by default

    # Note: do not use the read..._once() here, to ensure that the
    # looped daemon sees the whole picture, which can be new every time
    upslist_readFile || return $?
    #upslist_debug
    upslist_readSvcs "before manipulations"

    # Test if global config has changed since last run
    RESTART_ALL=no
    upssvcconf_checksum_unchanged "" || { echo "`date -u` : Detected changes in global section of '$UPSCONF', will restart all drivers"; RESTART_ALL=yes; }

    # Quickly exit if there's nothing to do; note the lists are pre-sorted
    # Otherwise a non-zero exit will be done below
    # Note: We implement testing in detail whether section definitions were
    # changed since last run, as a first step before checking that name
    # lists are still equivalent, because we need to always have the result
    # of the "has it changed?" check as a hit-list of something to remove,
    # while the check for no new device section definitions is just boolean.
    # We can only exit quickly if both there are no changed sections and no
    # new or removed sections since last run.
    NEW_CHECKSUM="`upslist_checksums_unchanged "$UPSLIST_FILE" "$UPSLIST_SVCS"`" \
    && [ -z "$NEW_CHECKSUM" ] \
    && upslist_equals "$UPSLIST_FILE" "$UPSLIST_SVCS" \
    && if [ -z "$DAEMON_SLEEP" -o "${VERBOSE_LOOP}" = yes ] ; then \
        echo "`date -u` : OK: No changes to reconcile between ${SERVICE_FRAMEWORK} service instances and device configurations in '$UPSCONF'" ; \
       fi \
    && [ "$RESTART_ALL" = no ] && return 0

    if [ -n "$NEW_CHECKSUM" ]; then
        for UPSS in $NEW_CHECKSUM ; do
            echo "Dropping old ${SERVICE_FRAMEWORK} service instance ${UPSS} whose section in config file has changed..." >&2
            $hook_unregisterInstance "$UPSS"
        done
        upslist_readSvcs "after updating for new config section checksums"
    fi

    if [ -n "$UPSLIST_SVCS" ]; then
        # Drop services that are not in config file (any more?)
        upslist_delSvcs

        if [ "$RESTART_ALL" = yes ] && [ "$AUTO_START" = yes ] ; then
            # Here restart only existing services; new ones will (try to)
            # start soon after creation and upsd is handled below
            upslist_restartSvcs
        fi
    fi

    if [ "$RESTART_ALL" = yes ] ; then
        # Save new checksum of global config
        $hook_setSavedMD5 "" "`upsconf_getSection_MD5 ""`"
    fi

    if [ -n "$UPSLIST_FILE" ]; then
        # Add services for sections that are in config file but not yet wrapped
        upslist_addSvcs
        $hook_refreshSupervizor
        upslist_readSvcs "after checking for new config sections to define service instances"
    fi

    upslist_readSvcs
    if [ -n "$UPSLIST_SVCS" ] ; then
        echo "=== The currently defined service instances are:"
        echo "$UPSLIST_SVCS"
    fi

    if [ -n "$UPSLIST_FILE" ] ; then
        echo "=== The currently defined configurations in '$UPSCONF' are:"
        echo "$UPSLIST_FILE"
    fi

    # We had some changes to the config file; upsd must be made aware
    if [ "$AUTO_START" = yes ] ; then
        $hook_restart_upsd
    fi

    # Return 42 if there was a change applied succesfully
    # (but e.g. some services should restart - upsd, maybe upsmon)
    UPSLIST_EQ_RES=0
    upslist_equals "$UPSLIST_FILE" "$UPSLIST_SVCS" || UPSLIST_EQ_RES=$?

    # File processing and service startups take a while;
    # make sure upsconf did not change while we worked...
    # NOTE: Check this at the last moment to minimize
    # the chance of still not noticing the change made
    # at just the wrong moment.
    UPSCONF_CHECKSUM_END="`calc_md5_file "$UPSCONF"`" || true
    if [ "$UPSCONF_CHECKSUM_END" != "$UPSCONF_CHECKSUM_START" ] ; then
        # NOTE: even if daemonized, the sleep between iterations
        # can be configured into an uncomfortably long lag, so
        # we should re-sync the system config in any case.
        echo "`date -u` : '$UPSCONF' changed while $0 $* was processing its older contents; re-running the script to pick up the late-coming changes"
        # Make sure the cycle does not repeat itself due to diffs
        # from an ages-old state of the file from when we started.
        UPSCONF_CHECKSUM_START="$UPSCONF_CHECKSUM_END"
        ( nut_driver_enumerator_main ) ; return $?
        # The "main" routine at the end of recursions will
        # do REPORT_RESTART_42 logic or the error exit-code
    fi

    if [ "$UPSLIST_EQ_RES" = 0 ] ; then
        echo "`date -u` : OK: No more changes to reconcile between ${SERVICE_FRAMEWORK} service instances and device configurations in '$UPSCONF'"
        [ "${REPORT_RESTART_42-}" = no ] && return 0 || return 42
    fi
    return 13
}

daemonize() (
    # Support (SIG)HUP == signal code 1 to quickly reconfigure,
    # e.g. to request it while the sleep is happening or while
    # "main" is processing an earlier change of the file.
    RECONFIGURE_ASAP=false
    trap 'RECONFIGURE_ASAP=true' 1

    # Note: this loop would die on errors with config file or
    # inability to ensure that it matches the list of services.
    # If caller did not `export REPORT_RESTART_42=no` then the
    # loop would exit with code 42, and probably trigger restart
    # of the service which wraps this daemon do topple others that
    # depend on it.
    # Note: do not quickly skip the "main" based on full-file
    # checksum refresh, to ensure that whatever is configured
    # gets applied (e.g. if user disabled some services or they
    # died, or some config was not applied due to coding error).
    while nut_driver_enumerator_main ; do
        if $RECONFIGURE_ASAP ; then
            echo "`date -u` : Trapped a SIGHUP during last run of nut_driver_enumerator_main, repeating reconfiguration quickly" >&2
        else
            sleep $DAEMON_SLEEP &
            trap "kill $! ; echo 'Sleep interrupted, processing configs now!'>&2" 1
            wait $!
        fi
        RECONFIGURE_ASAP=false
        trap 'RECONFIGURE_ASAP=true' 1
    done
    exit $?
)

# Save the checksum of ups.conf as early as possible,
# to test in the end that it is still the same file.
UPSCONF_CHECKSUM_START="`calc_md5_file "$UPSCONF"`" || true

# By default, update wrapping of devices into services
if [ $# = 0 ]; then
    nut_driver_enumerator_main ; exit $?
fi

if [ $# = 1 ] ; then
    [ -n "$DAEMON_SLEEP" ] || DAEMON_SLEEP=60
    # Note: Not all shells have 'case ... ;&' support
    case "$1" in
        --daemon=*) DAEMON_SLEEP="`echo "$1" | sed 's,^--daemon=,,'`" ;;
    esac
    case "$1" in
        --daemon|--daemon=*)
            daemonize &
            exit $?
            ;;
    esac
fi
unset DAEMON_SLEEP

usage() {
    cat << EOF
$0 (no args)
        Update wrapping of devices into services
$0 --daemon(=freq)
        Update wrapping of devices into services in an infinite loop
        Default freq is 60 sec
$0 --reconfigure
        Stop and un-register all service instances and recreate them
        (e.g. if new dependency template was defined in a new
        version of this script and/or NUT package)
$0 --get-service-framework
        Print the detected service
        management framework in this OS
$0 --list-devices
        Print list of devices in NUT config
$0 --list-services
        Print list of service instances which wrap registered
        NUT devices (full name of service unit)
$0 --list-instances
        Print list of service instances which wrap registered
        NUT devices (just instance suffix)
$0 --get-service-for-device DEV
        Print the full name of service unit which wraps a NUT
        device named "DEV"
$0 --get-device-for-service SVC
        Print the NUT device name for full or instance-suffix name of
        a service unit which wraps it
$0 --list-services-for-devices
        Print a TAB-separated list of service units and corresponding
        NUT device names which each such unit wraps
$0 --show-configs|--show-all-configs
        Show the complete normalized list of device configuration blocks
$0 --show-config DEV
$0 --show-device-config DEV
        Show configuration block of the specified NUT device
$0 --show-device-config-value DEV KEY [KEY...]
        Show single configuration key value of the specified NUT device
        For flags, shows the flag name if present in the section
        If several keys or flags are requested, their values are reported
        one per line in the same order (including empty lines for missing
        values); any missing value yields a non-zero exit code.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h|-help) usage; exit 0 ;;
        --get-service-framework) echo "${SERVICE_FRAMEWORK}" ; exit 0 ;;
        --reconfigure)
            upslist_readFile_once || exit $?
            upslist_readSvcs "before manipulations"

            if [ -n "$UPSLIST_SVCS" ]; then
                for UPSS in $UPSLIST_SVCS ; do
                    echo "Dropping old ${SERVICE_FRAMEWORK} service instance for power device [${UPSS}] to reconfigure the service unit..." >&2
                    $hook_unregisterInstance "$UPSS"
                done
                upslist_readSvcs "after dropping"
            fi

            if [ -n "$UPSLIST_FILE" ]; then
                upslist_addSvcs
                upslist_readSvcs "after checking for new config sections to define service instances"
            fi

            # Save new checksum of global config
            $hook_setSavedMD5 "" "`upsconf_getSection_MD5 ""`"

            # Service units were manipulated, including saving of checksums;
            # refresh the service management daemon if needed
            $hook_refreshSupervizor

            if [ -n "$UPSLIST_SVCS" ] ; then
                echo "=== The currently defined service instances are:"
                echo "$UPSLIST_SVCS"
            fi

            if [ -n "$UPSLIST_FILE" ] ; then
                echo "=== The currently defined configurations in '$UPSCONF' are:"
                echo "$UPSLIST_FILE"
            fi

            # We had some changes to the config file; upsd must be made aware
            if [ "$AUTO_START" = yes ] ; then
                $hook_restart_upsd
            fi

            # Return 42 if there was a change applied succesfully
            # (but e.g. some services should restart - upsd, maybe upsmon)
            UPSLIST_EQ_RES=0
            upslist_equals "$UPSLIST_FILE" "$UPSLIST_SVCS" || UPSLIST_EQ_RES=$?

            # File processing and service startups take a while;
            # make sure upsconf did not change while we worked...
            # NOTE: Check this at the last moment to minimize
            # the chance of still not noticing the change made
            # at just the wrong moment.
            UPSCONF_CHECKSUM_END="`calc_md5_file "$UPSCONF"`" || true
            if [ "$UPSCONF_CHECKSUM_END" != "$UPSCONF_CHECKSUM_START" ] ; then
                echo "`date -u` : '$UPSCONF' changed while $0 $* was processing its older contents; re-running the script to pick up the late-coming changes"
                $0 ; exit $?
                # The "main" routine will do REPORT_RESTART_42 logic too
            fi

            if [ "$UPSLIST_EQ_RES" = 0 ] ; then
                echo "`date -u` : OK: No more changes to reconcile between ${SERVICE_FRAMEWORK} service instances and device configurations in '$UPSCONF'"
                [ "${REPORT_RESTART_42-}" = no ] && exit 0 || exit 42
            fi

            exit 13
            ;;
        --list-devices)
            upslist_readFile_once && \
            if [ -n "$UPSLIST_FILE" ] ; then
                echo "=== The currently defined configurations in '$UPSCONF' are:" >&2
                echo "$UPSLIST_FILE"
                exit 0
            fi
            echo "No devices detected in '$UPSCONF'" >&2
            exit 1
            ;;
        --list-services)
            UPSLIST_SVCS_RAW="`$hook_listInstances_raw`" && \
            if [ -n "$UPSLIST_SVCS_RAW" ] ; then
                echo "=== The currently defined service units are:" >&2
                echo "$UPSLIST_SVCS_RAW"
                exit 0
            fi
            echo "No service units detected" >&2
            exit 1
            ;;
        --list-instances)
            upslist_readSvcs "by user request" && \
            if [ -n "$UPSLIST_SVCS" ] ; then
                echo "=== The currently defined service instances are:" >&2
                echo "$UPSLIST_SVCS"
                exit 0
            fi
            echo "No service instances detected" >&2
            exit 1
            ;;
        --get-service-for-device) [ -z "$2" ] && echo "Device name argument required" >&2 && exit 1
            DEV="$2"
            upslist_readSvcs "by user request" && [ -n "$UPSLIST_SVCS" ] \
                || { echo "No service instances detected" >&2 ; exit 1; }
            UPSLIST_SVCS_RAW="`$hook_listInstances_raw`" && [ -n "$UPSLIST_SVCS_RAW" ] \
                || { echo "No service units detected" >&2 ; exit 1; }
            vINST="`$hook_validInstanceName "$DEV"`"
            vUNITD="`$hook_validFullUnitName "$DEV"`"
            vUNITI="`$hook_validFullUnitName "$vINST"`"
            # First pass over simple verbatim names
            for INST in $UPSLIST_SVCS ; do
                if [ "$INST" = "$DEV" ] ; then
                    for UNIT in $UPSLIST_SVCS_RAW ; do
                        if [ "$UNIT" = "$vUNITD" ] ; then
                            echo "$UNIT"
                            exit 0
                        fi
                    done
                fi
            done
            for INST in $UPSLIST_SVCS ; do
                if [ "$INST" = "$vINST" ] ; then
                    for UNIT in $UPSLIST_SVCS_RAW ; do
                        if [ "$UNIT" = "$vUNITI" ] ; then
                            echo "$UNIT"
                            exit 0
                        fi
                    done
                fi
            done
            echo "No service instances detected that match device '$2'" >&2
            exit 1
            ;;
        --get-device-for-service) [ -z "$2" ] && echo "Service (instance) name argument required" >&2 && exit 1
            # Instance name can be a hash or "native" NUT section name
            SVC="`$hook_validInstanceSuffixName "$2"`"
            case "$SVC" in
                MD5_*) ;; # fall through to the bulk of code
                *)  upslist_readFile_once || exit $?
                    echo "$UPSLIST_FILE" | egrep "^$SVC\$"
                    exit $?
                    ;;
            esac
            FINAL_RES=0
            OUT="`"$0" --list-services-for-devices`" && [ -n "$OUT" ] || FINAL_RES=$?
            if [ "$FINAL_RES" = 0 ]; then
                echo "$OUT" | grep "$SVC" | ( \
                    while read _SVC _DEV ; do
                        _SVC="`$hook_validInstanceSuffixName "${_SVC}"`" || exit
                        [ "${_SVC}" = "${SVC}" ] && echo "$_DEV" && exit 0
                    done ; exit 1 ) && exit 0
            fi
            echo "No service instance '$2' was detected that matches a NUT device" >&2
            exit 1
            ;;
        --list-services-for-devices)
            FINAL_RES=0
            upslist_readFile_once && [ -n "$UPSLIST_FILE" ] \
                || { echo "No devices detected in '$UPSCONF'" >&2 ; exit 1 ; }
            upslist_readSvcs "by user request" && [ -n "$UPSLIST_SVCS" ] \
                || { echo "No service instances detected" >&2 ; exit 1; }
            UPSLIST_SVCS_RAW="`$hook_listInstances_raw`" && [ -n "$UPSLIST_SVCS_RAW" ] \
                || { echo "No service units detected" >&2 ; exit 1; }
            for DEV in $UPSLIST_FILE ; do
                vINST="`$hook_validInstanceName "$DEV"`"
                vUNITD="`$hook_validFullUnitName "$DEV"`"
                vUNITI="`$hook_validFullUnitName "$vINST"`"
                # First pass over simple verbatim names
                for INST in $UPSLIST_SVCS ; do
                    if [ "$INST" = "$DEV" ] ; then
                        for UNIT in $UPSLIST_SVCS_RAW ; do
                            if [ "$UNIT" = "$vUNITD" ] ; then
                                printf '%s\t%s\n' "$UNIT" "$DEV"
                                continue 3
                            fi
                        done
                    fi
                done
                for INST in $UPSLIST_SVCS ; do
                    if [ "$INST" = "$vINST" ] ; then
                        for UNIT in $UPSLIST_SVCS_RAW ; do
                            if [ "$UNIT" = "$vUNITI" ] ; then
                                printf '%s\t%s\n' "$UNIT" "$DEV"
                                continue 3
                            fi
                        done
                    fi
                done
                echo "WARNING: no service instances detected that match device '$DEV'" >&2
                FINAL_RES=1
            done
            exit $FINAL_RES
            ;;
        --show-configs|--show-device-configs|--show-all-configs|--show-all-device-configs)
            RES=0
            upslist_readFile_once || RES=$?
            [ "$RES" != 0 ] && { echo "ERROR: upslist_readFile_once () failed with code $RES" >&2; exit $RES; }
            [ -n "$UPSLIST_FILE" ] \
                || { echo "WARNING: No devices detected in '$UPSCONF'" >&2 ; RES=1 ; }
            echo "$UPSCONF_DATA"
            exit $RES
            ;;
        --show-config|--show-device-config)
            [ -z "$2" ] && echo "WARNING: Device name argument empty, will show global config" >&2
            DEV="$2"
            upsconf_getSection "$DEV"
            exit $?
            ;;
        --show-config-value|--show-device-config-value)
            [ -z "$3" ] && echo "At least one configuration key name argument is required" >&2 && exit 1
            [ -z "$2" ] && echo "WARNING: Device name argument empty, will show global config" >&2
            DEV="$2"
            shift 2
            upsconf_getValue "$DEV" "$@"
            exit $?
            ;;
        upsconf_debug) # Not public, not in usage()
            [ -z "$2" ] && echo "Device name argument required" >&2 && exit 1
            upsconf_debug "$2"
            exit $?
            ;;
        upslist_debug) # Not public, not in usage()
            upslist_readFile_once || exit
            upslist_debug
            exit $?
            ;;
        *) echo "Unrecognized argument: $1" >&2 ; exit 1 ;;
    esac
    shift
done
