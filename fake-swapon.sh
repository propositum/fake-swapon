#!/bin/bash
#
# STEmacsModelines:
# -*- Shell-Unix-Generic -*-
#
# Create and enable a swap file on Linux.
#

# Copyright (c) 2014 Mark Eissler, mark@mixtur.com

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# @TODO Implement options to free swap.
#
# NOTE: To remove loop device based swap you need to do the following:
#
# >swapoff /dev/loop0
# >losetup -d /dev/loop0
#
# If you don't delete the loop device, the kernel will at some point remap the
# vm back into the table.
#

PATH=/usr/local/bin

PATH_BNAME="/usr/bin/basename"
PATHgetOPT="/usr/bin/getopt"
PATH_CAT="/usr/bin/cat"
PATH_DD="/usr/bin/dd"
PATH_LS="/bin/ls"
PATH_CHMOD="/usr/bin/chmod"
PATH_MKDIR="/usr/bin/mkdir"
PATH_STAT="/usr/bin/stat"
PATH_SED="/usr/bin/sed"
PATH_TR="/usr/bin/tr"
PATH_UNAME="/usr/bin/uname"
PATH_EXPR="/usr/bin/expr"

PATH_MKSWAP="/usr/sbin/mkswap"
PATH_SWAPON="/usr/sbin/swapon"

# Loop device support (required for CoreOS)
#
PATH_LOSETUP="/usr/sbin/losetup"

# Swap directory
#
PATH_SWAPDIR="/root/swap"


###### NO SERVICABLE PARTS BELOW ######
VERSION=2.0.0
PROGNAME=$(${PATH_BNAME} $0)

# reset internal vars (do not touch these here)
DEBUG=0
FORCEEXEC=0
ADDSWAP=0
LISTSWAP=0
REMOVESWAP=0
SWAPSIZE=-1

# defaults
DEF_SWAPSIZE=1024

#
# FUNCTIONS
#

# if basename is not installed
#
basename() {
  if [ -z "${1}" ]; then
    echo ""; return 1
  fi

  # resp=$(echo "${1}" | sed -E "s:^(.*/)*(.*)$:\2:;s:^(.*)(\..*)$:\1:")
  resp=$(echo "${1}" | sed -E "s:^([\/]?.*\/)*(.*)\..*$:\2:")
  rslt=$?
  if [[ -n "${resp}" ]] && [[ ${rslt} -eq 0 ]]; then
    echo ${resp}; return 0
  else
    echo ""; return 1
  fi
}

function usage {
  if [ ${GETOPT_OLD} -eq 1 ]; then
    usage_old
  else
    usage_new
  fi
}

function usage_new {
${PATH_CAT} << EOF
usage: ${PROGNAME} [options]

Add system virtual memory ("swap"). On file systems that don\'t support swap,
the loop device will be used to create "fake" swap. The "add" and "remove"
options refer only to swap managed by fake-swap.

OPTIONS:
   -a, --add-swap               Add swap to system virtual memory pool
   -i, --swap-id                Swap id (as returned by "fake-swap --list-swap")
   -l, --list-swap              List swap managed by fake-swap
   -r, --remove-swap            Remove swap managed by fake-swap from vm pool
   -s, --swap-size              Size of swap to add (use with --add-swap)
   -d, --debug                  Turn debugging on (increases verbosity)
   -f, --force                  Execute without user prompt
   -h, --help                   Show this message
   -v, --version                Output version of this script

EOF
}

# support for old getopt (non-enhanced, only supports short param names)
#
function usage_old {
cat << EOF
usage: ${PROGNAME} [options] targetName

Add system virtual memory ("swap"). On file systems that don\'t support swap,
the loop device will be used to create "fake" swap. The "add" and "remove"
options refer only to swap managed by fake-swap.

OPTIONS:
   -a                           Add swap to system virtual memory pool
   -i                           Swap id (as returned by "fake-swap -l")
   -l                           List swap managed by fake-swap
   -r                           Remove swap managed by fake-swap from vm pool
   -s                           Size of swap to add (use with -a)
   -d                           Turn debugging on (increases verbosity)
   -f                           Execute without user prompt
   -h                           Show this message
   -v                           Output version of this script

EOF
}

function promptHelp {
${PATH_CAT} << EOF
For help, run "${PROGNAME}" with the -h flag or without any options.

EOF
}

function version {
  echo ${PROGNAME} ${VERSION};
}

# promptConfirm()
#
# Confirm a user action. Input case insensitive.
#
# Returns "yes" or "no" (default).
#
function promptConfirm() {
  read -p "$1 ([y]es or [N]o): "
  case $(echo $REPLY | ${PATH_TR} '[A-Z]' '[a-z]') in
    y|yes) echo "yes" ;;
    *)     echo "no" ;;
  esac
}

# check if swap is enabled
#

# checkSwap()
#
# Get configured swap size and reporting units. The referenced swapconfig array
#   will be updated.
#
# @param { arrayref } [optional] Reference to an existing swapconfig array
#
checkSwap() {
  local __swapconfig="gSwapConfig"
  if [ -n "${1}" ]; then
    __swapconfig=${1}
  fi
  declare -g -A "$__swapconfig"

  local swaparray
  local resp rslt

  # init array
  eval "$__swapconfig[SRECCNT]=1"
  eval "$__swapconfig[SRECSIZ]=2"
  eval "$__swapconfig[SRECOFF]=3"
  eval "$__swapconfig[SIZE]=0"
  eval "$__swapconfig[UNIT]=M"

  resp=$(${PATH_CAT} /proc/meminfo | ${PATH_SED} -En "s/^SwapTotal:[\ ]*([0-9]*)[\ ]*([a-zA-Z]{2,2})/\1@\2/p" )
  rslt=$?
  if [ ${rslt} -ne 0 ]; then
    return 1
  fi
  swaparray=(${resp//@/ })
  if [[ ${#swaparray[@]} -eq 2 ]] && [[ ${swaparray[0]} -gt 0 ]]; then
    eval "$__swapconfig[SIZE]=${swaparray[0]}"
    eval "$__swapconfig[UNIT]=${swaparray[1]}"
    return 0
  fi
}

# getSwapList()
#
# Get a list of our managed swap. The referenced swaplist array will be updated.
#
# @param { arrayref } [optional] Reference to an existing swaplist array
#
getSwapList() {
  local __swaplist="gSwapList"
  if [ -n "${1}" ]; then
    __swaplist=${1}
  fi
  declare -g -A "$__swaplist"

  local swapfile
  local lpdevice sizelimit offset autoclear roflag backfile
  local swdevice type size used prio
  local count=0
  local lcount scount
  local resp rslt
  local styparray
  local __wdev

  # init array
  eval "$__swaplist[SRECCNT]=${count}"
  eval "$__swaplist[SRECSIZ]=7"
  eval "$__swaplist[SRECOFF]=3"

  # suppress empty swapdir listing errors, check to see iif we have any swap at
  # all; if not, just bail out now!
  resp=$({ ${PATH_LS} -d1 ${PATH_SWAPDIR}/*; } 2>&1)
  rslt=$?
  if [[ rslt -ne 0 ]]; then
    if [ "${DEBUG}" -ne 0 ]; then
      echo "DEBUG:  swapdir: ERROR, is it empty?"
    fi
    return 1
  fi

  # get swap device and file information
  while IFS=" " read -r swapfile; do
    resp=$(echo ${swapfile} | ${PATH_SED} -Ee "/(lp.swap|wd.swap)/!d" -e "s:^/root/swap[/]?/(wd.swap|lp.swap).(.*)$:\2@\1:")
    if [ "${DEBUG}" -ne 0 ]; then
      echo "DEBUG: swapfile: $swapfile"
      echo "DEBUG: id found: $resp"
    fi
    rslt=$?
    if [[ -n "${resp}" ]] && [[ ${rslt} -eq 0 ]]; then

      # split SWID and STYP into an array, fix STYPE
      styparray=(${resp//@/ })
      if [[ ${#styparray[@]} -eq 2 ]] && [[ ! -z ${styparray[0]} ]] && [[ ! -z ${styparray[1]} ]]; then
        if [[ "${styparray[1]}" = "lp.swap" ]]; then
          styparray[1]="loop"
        elif [[ "${styparray[1]}" = "wd.swap" ]]; then
          styparray[1]="fsys"
        fi
      else
        styparray[0]="unk"
        styparray[1]="unk"
      fi

      if [ "${DEBUG}" -ne 0 ]; then
        echo "DEBUG: swaptype: ${styparray[1]}"
        echo "DEBUG:     swid: ${styparray[0]}"
      fi

      (( count++ ))
      (( _idx=count-1 ))

      # SRECCNT: number of swap records
      # SRECSIZ: number of fields in each swap record
      # SRECOFF: offset from header records
      eval "$__swaplist[SRECCNT]=${count}"
      eval "$__swaplist[${_idx},SWID]=${styparray[0]}"
      eval "$__swaplist[${_idx},STYP]=${styparray[1]}"
      eval "$__swaplist[${_idx},FILE]=${swapfile}"

      # retrieve loop device information
      if [[ "${styparray[1]}" = "loop" ]]; then
        lcount=0
        while IFS=" " read -r lpdevice sizelimit offset autoclear roflag backfile; do
          if [[ $(( lcount++ )) -lt 1 ]]; then
            continue
          fi
          if [[ "${swapfile}" = "${backfile}" ]]; then
            eval "$__swaplist[${_idx},WDEV]=${lpdevice}"
          fi
          (( lcount++ ))
        done <<< "$(${PATH_LOSETUP} --list)"
      else
        eval "$__swaplist[${_idx},WDEV]=${swapfile}"
      fi

      # get swap size information
      scount=0
      while IFS=" " read -r swdevice type size used prio; do
        if [[ $(( scount++ )) -lt 1 ]]; then
          continue
        fi

        # need to translate wdev value for local use, on loop devices, the
        # swdevice will point to /dev/loopX; on fsys devices, the swdevice
        # will point to the backing file.
        __wdev="\${${__swaplist}[${_idx},WDEV]}"
        __wdev=$(eval "${PATH_EXPR} ${__wdev}")

        if [[ "${__wdev}" = "${swdevice}" ]]; then
          eval "$__swaplist[${_idx},SIZE]=${size}"
          eval "$__swaplist[${_idx},USED]=${used}"
          eval "$__swaplist[${_idx},TYPE]=${type}"
        fi
        (( scount++ ))
      done <<< "$(${PATH_SWAPON} --show)"
    fi
  done <<< "$(${PATH_LS} -d1 ${PATH_SWAPDIR}/*)"
}

# getUniqStr()
#
# Get a random string.
#
# @param { int } Length of string to generate.
#
# @return { string } Generated string.
#
getUniqStr() {
  local uniqstr
  local length=5

  if [ -n "${1}" ]; then
    length=${1}
  fi

  dict="abcdefghijkmnopqrstuvxyz123456789"

  for i in $(eval echo {0..$length}); do
    rand=$(( $RANDOM%${#dict} ))
    uniqstr="${uniqstr}${dict:$rand:1}"
  done

  echo $uniqstr
}

# getUniqSWID()
#
# Get a unique swap id string. This is a recursive function.
#
# @param { arrayref } [optional] Reference to an existing swaplist array
# @param { string } [optional] Swapid to check and regenerate if not unique
#
# @return { string } Generated string.
#
getUniqSWID() {
  local __swaplist="gSwapList"
  if [ -n "${1}" ]; then
    __swaplist=${1}
  fi
  declare -g -A "$__swaplist"

  local checkswid=${2}
  local collision=1
  local __sreccnt
  local __swid

  if [ ${#__swaplist} -eq 0 ]; then
    getSwapList $__swaplist
  fi

  if [ -z "${checkswid}" ]; then
    checkswid=$(getUniqStr 5)
  fi

  __sreccnt="\${${__swaplist}[SRECCNT]}"
  __sreccnt=$(eval "${PATH_EXPR} ${__sreccnt}")

  while [[ $collision -eq 1 ]]; do
    for((i=0; i<${__sreccnt}; i++)); do

      __swid="\${${__swaplist}[$i,SWID]}"
      __swid=$(eval "${PATH_EXPR} ${__swid}")

      if [[ "${__swid}" = "${checkswid}" ]]; then
        checkswid=$(getUniqSWID $__swaplist $checkswid)
      fi
    done
    collision=0
  done

  echo $checkswid
}

# addswap()
#
# Add swap to the system.
#
# @param { int } [ optional ] Size of swap file in megabytes (-1 for default)
# @param { arrayref } [optional] Reference to an existing swapconfig array
# @param { arrayref } [optional] Reference to an existing swaplist array
#
addswap() {
  # swapsize vars
  local __swapsize=${DEF_SWAPSIZE}
  if [ -n "${1}"] && [ ${1} -gt ${__swapsize} ]; then
    __swapsize=${1}
  fi

  # swapconfig vars
  local __swapconfig="gSwapConfig"
  if [ -n "${1}" ]; then
    __swapconfig=${2}
  fi
  declare -g -A "$__swapconfig"

  local __swapconfig_reccnt
  local __swapconfig_size
  local __swapconfig_unit

  # swaplist vars
  local __swaplist="gSwapList"
  if [ -n "${3}" ]; then
    __swaplist=$3}
  fi
  declare -g -A "$__swaplist"

  local __sreccnt

  # other local vars...
  local swapid_new

  # let's go!
  #
  checkSwap $__swapconfig
  if [ $? -ne 0 ]; then
    echo "ABORTING. Unable to determine swap status."
    echo
    exit 1
  fi

  # translate to local vars
  __swapconfig_reccnt="\${${__swapconfig}[SRECCNT]}"
  __swapconfig_reccnt=$(eval "${PATH_EXPR} ${__swapconfig_reccnt}")

  __swapconfig_size="\${${__swapconfig}[SIZE]}"
  __swapconfig_size=$(eval "${PATH_EXPR} ${__swapconfig_size}")

  __swapconfig_unit="\${${__swapconfig}[UNIT]}"
  __swapconfig_unit=$(eval "${PATH_EXPR} ${__swapconfig_unit}")

  if [[ ${__swapconfig_reccnt} -eq 1 ]] && [[ ${__swapconfig_size} -gt 0 ]]; then
    echo "Swap has already been enabled. Detected: ${__swapconfig_size} ${__swapconfig_unit}"
    if [[ "${FORCEEXEC}" -eq 0 ]]; then
      # prompt user for confirmation
      if [[ "no" == $(promptConfirm "Add additional swap?") ]]
      then
        echo "ABORTING. Nothing to do."
        exit 0
      fi
    fi
  fi

  # make the swap directory
  resp=$({ ${PATH_MKDIR} -p "${PATH_SWAPDIR}"; } 2>&1)
  rslt=$?
  if [ $? -ne 0 ]; then
    echo "ABORTING. Unable to create swap directory."
    echo
    exit 1
  else
    resp=$({ ${PATH_CHMOD} 0700 "${PATH_SWAPDIR}"; } 2>&1)
    rslt=$?
    if [ $? -ne 0 ]; then
      echo "ABORTING. Unable to adjust permissions on swap directory."
      echo
      exit
    fi
  fi

  # avoid collisions in name space, grab list of existing swap
  getSwapList $__swaplist

  # translate to local vars
  __sreccnt="\${${__swaplist}[SRECCNT]}"
  __sreccnt=$(eval "${PATH_EXPR} ${__sreccnt}")

  if [ "${DEBUG}" -ne 0 ]; then
    echo "DEBUG:  sreccnt: ${__sreccnt}"
  fi
  swapid_new=$(getUniqSWID $__swaplist)
  if [ "${DEBUG}" -ne 0 ]; then
    echo "DEBUG: swapid_n: ${swapid_new}"
  fi

  if [[ "${osconfig[NAME]}" =~ "CoreOS" ]]; then
    echo
    echo "Creating swap using the loop device method..."
    swapfile="${PATH_SWAPDIR}/lp.swap.${swapid_new}"
    swapdev=$(${PATH_LOSETUP} -f)
    # check if a swapfile already exists, if not, create it
    resp=$(${PATH_STAT} ${swapfile} &> /dev/null)
    rslt=$?
    if [[ ${rslt} -ne 0 ]]; then
      echo "No swapfile detected. Creating it..."
      ${PATH_DD} if=/dev/zero of=${swapfile} bs=1M count=${__swapsize}
      if [ $? -ne 0 ]; then
        echo "ABORTING. Couldn't create swap file: ${swapfile}"
        echo
        exit 1
      fi
      # fix permissions
      ${PATH_CHMOD} 0600 ${swapfile}
      echo "Swap file created at ${swapfile}"
    else
      echo "Found a swap file at ${swapfile}"
    fi
    echo "Connecting swap to loop device."
    ${PATH_LOSETUP} ${swapdev} ${swapfile}
    echo "Formatting swap file."
    ${PATH_MKSWAP} ${swapdev} &> /dev/null
    echo "Enabling swap."
    ${PATH_SWAPON} ${swapdev}
  elif [[ "${osconfig[NAME]}" =~ "CentOS" ]]; then
    echo
    echo "Creating swap using the file system method..."
    swapfile="${PATH_SWAPDIR}/wd.swap.${swapid_new}"
    swapdev=${swapfile}
    # check if a swapfile already exists, if not, create it
    resp=$(${PATH_STAT} ${swapfile} &> /dev/null)
    rslt=$?
    if [[ ${rslt} -ne 0 ]]; then
      echo "No swapfile detected. Creating it..."
      ${PATH_DD} if=/dev/zero of=${swapfile} bs=1M count=${__swapsize}
      if [ $? -ne 0 ]; then
        echo "ABORTING. Couldn't create swap file: ${swapfile}"
        echo
        exit 1
      fi
      # fix permissions
      ${PATH_CHMOD} 0600 ${swapfile}
      echo "Swap file created at ${swapfile}"
    else
      echo "Found a swap file at ${swapfile}"
    fi
    echo "Formatting swap file."
    ${PATH_MKSWAP} ${swapdev} &> /dev/null
    echo "Enabling swap."
    ${PATH_SWAPON} ${swapdev}
  else
    echo "ABORTING. Swap creation strategy not implemented for this OS."
    echo
    exit 1
  fi

  echo
  echo "REMEMBER 1: You will need to manually delete the swap file when done: ${swapfile}"
  echo "REMEMBER 2: You will need to re-run this script between reboots/shutdowns."
  echo

  # check if our work was a success
  checkSwap $__swapconfig
  if [ $? -ne 0 ]; then
    echo "ABORTING. Unable to determine swap status."
    echo
    exit 1
  fi

  # translate to local vars
  __swapconfig_reccnt="\${${__swapconfig}[SRECCNT]}"
  __swapconfig_reccnt=$(eval "${PATH_EXPR} ${__swapconfig_reccnt}")

  __swapconfig_size="\${${__swapconfig}[SIZE]}"
  __swapconfig_size=$(eval "${PATH_EXPR} ${__swapconfig_size}")

  __swapconfig_unit="\${${__swapconfig}[UNIT]}"
  __swapconfig_unit=$(eval "${PATH_EXPR} ${__swapconfig_unit}")

  if [[ ${__swapconfig_reccnt} -eq 1 ]] && [[ ${__swapconfig_size} -gt 0 ]]; then
    echo "Swap has been enabled. Detected: ${__swapconfig_size} ${__swapconfig_unit}"
    echo
    exit 0
  fi
}

# list swap
#
listswap() {
  swaplist="swaplist"
  getSwapList $swaplist

  printf "Swap Id     Type                  Size    Used\n"

  for((i=0; i<${swaplist[SRECCNT]}; i++)); do
    swaptype="${swaplist[$i,TYPE]}"
    if [[ "${swaplist[$i,STYP]}" = "loop" ]]; then
      swaptype="${swaptype} (loop)"
    fi
    printf "%-10s  %-20s  %-6s  %-6s\n" "${swaplist[$i,SWID]}" "${swaptype}" "${swaplist[$i,SIZE]}" "${swaplist[$i,USED]}"
  done
  echo
}

# removeswap()
#
# Remove swap from the system.
#
# @param { arrayref } [optional] Reference to an existing swapconfig array
# @param { arrayref } [optional] Reference to an existing swaplist array
#
removeswap() {
  echo "$FUNCNAME: not impl"
}

# parse a config file with KEY=VAL definitions, return array in variable
# supplied by caller.
#
readconfig() {
  local array="$1"
  local key val
  local IFS='='
  declare -g -A "$array"
  while read reply; do
    # assume comments may not be indented
    [[ $reply == [^#]*[^$IFS]${IFS}[^$IFS]* ]] && {
      read key val <<< "$reply"
      [[ -n $key ]] || continue
      eval "$array[$key]=${val}"
    }
  done
}

# parse cli parameters
#
# Our options:
#   --add-swap, a
#   --swap-id, i
#   --list-swap, l
#   --remove-swap, r
#   --swap-size, s
#   --debug, d
#   --force, f
#   --help, h
#   --version, v
#
params=""
${PATHgetOPT} -T > /dev/null
if [ $? -eq 4 ]; then
  # GNU enhanced getopt is available
  PROGNAME=$(${PATH_BNAME} $0)
  params="$(${PATHgetOPT} --name "$PROGNAME" --long add-swap,swap-id:,list-swap,remove-swap,swap-size:,force,help,version,debug --options ai:lrs:fhvd -- "$@")"
else
  # Original getopt is available
  GETOPT_OLD=1
  PROGNAME=$(${PATH_BNAME} $0)
  params="$(${PATHgetOPT} ai:lrs:fhvd "$@")"
fi

# check for invalid params passed; bail out if error is set.
if [ $? -ne 0 ]
then
  usage; exit 1;
fi

eval set -- "$params"
unset params

while [ $# -gt 0 ]; do
  case "$1" in
    -a | --add-swap)        cli_ADDSWAP=1; ADDSWAP=${cli_ADDSWAP};;
    -i | --swap-id)         cli_SWAPID="$2"; shift;;
    -l | --list-swap)       cli_LISTSWAP=1; LISTSWAP=${cli_LISTSWAP};;
    -r | --remove-swap)     cli_REMOVESWAP=1; REMOVESWAP=${cli_REMOVESWAP};;
    -s | --swap-size)       cli_SWAPSIZE="$2"; shift;;
    -d | --debug)           cli_DEBUG=1; DEBUG=${cli_DEBUG};;
    -f | --force)           cli_FORCEEXEC=1;;
    -v | --version)         version; exit;;
    -h | --help)            usage; exit;;
    --)                     shift; break;;
  esac
  shift
done


# Root user!!
#
if [[ $EUID -ne 0 ]]; then
  echo "Superuser (root) privileges required." 1>&2
  echo
  exit 100
fi

# Rangle our vars
#
if [ -n "${cli_FORCEEXEC}" ]; then
  FORCEEXEC=${cli_FORCEEXEC};
fi

if [ -n "${cli_SWAPSIZE}" ]; then
  if [[ ${cli_SWAPSIZE} =~ ^-?[0-9]+$ ]]; then
    SWAPSIZE=${cli_SWAPSIZE}
    if [ "${DEBUG}" -ne 0 ]; then
      echo "DEBUG: swapsize: ${SWAPSIZE}"
    fi
    if [[ ${SWAPSIZE} -lt 1024 ]]; then
      echo
      echo "WARNING: Minimum swap size is 1024. Specified swap size ignored."
      echo
    fi
  else
    echo
    echo "ABORTING. Invalid swap size specified: \"${cli_SWAPSIZE}\""
    echo
    usage
    exit 1
  fi
fi

echo "Analyzing system for fake-swap status..."

runos=""

unamestr=$(${PATH_UNAME})
case "${unamestr}" in
"Linux" )
  runos='linux'
  ;;
"FreeBSD" )
  runos='freebsd'
  ;;
"Darwin" )
  runos='osx'
  ;;
"SunOS" )
  runos='solaris'
  ;;
* )
  runos=${platform}
  ;;
esac

if [ "${runos}" != 'linux' ]; then
  echo "ABORTING. Target OS doesn't appear to be Linux."
  echo
  exit 1
fi

# we are on linux, so which distro?
if [ ! -e /etc/os-release ]; then
  echo "ABORTING. Unable to determine Linux variant."
  echo
  exit 1
fi
readconfig osconfig < "/etc/os-release"
if [[ "${osconfig[NAME]}" = "" ]] || [[ "${osconfig[VERSION]}" = "" ]]; then
  echo "ABORTING. Unable to determine Linux variant."
  echo "The /etc/os-release file may be incomplete."
  echo
  exit 1
fi

echo "Detected Linux variant: ${osconfig[NAME]} [${osconfig[VERSION]}]"

#
# Add swap
#

if [[ ${ADDSWAP} -ne 0 ]] && [[ ${SWAPSIZE} -gt 0 ]]; then
  #
  # -Additional (-a with -s option)
  #
  addswap ${SWAPSIZE}

  exit 0
else if [[ ${ADDSWAP} -ne 0 ]]; then
  #
  # -Default
  #
  addswap

  exit 0
fi

#
# Remove swap
#

# -All swap
if [[ ${REMOVESWAP} -ne 0 ]]; then
  removeswap

  exit 0
fi

# -Specific swap (-r with -i option)

#
# List swap
#
if [[ ${LISTSWAP} -ne 0 ]]; then
  listswap

  exit 0
fi
