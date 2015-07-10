#!/bin/sh

MY_VERSION="0.20-BETA"
# ----------------------------------------------------------------------------------------------------------------------
# Arno's Push-Snapshot Script using ENCFS + RSYNC + SSH
# Last update: July 10, 2015
# (C) Copyright 2014-2015 by Arno van Amersfoort
# Homepage              : http://rocky.eld.leidenuniv.nl/
# Email                 : a r n o v a AT r o c k y DOT e l d DOT l e i d e n u n i v DOT n l
#                         (note: you must remove all spaces and substitute the @ and the . at the proper locations!)
# ----------------------------------------------------------------------------------------------------------------------
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 2 as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
# ---------------------------------------------------------------------------------------------------------------------- 

DEFAULT_CONF_FILE="/etc/psnapshot-enc.conf"

EOL='
'
TAB=$(printf "\t")


# Functions:
############

mount_remote_sshfs()
{
  mkdir -p "$SSHFS_MOUNT_PATH"

  sshfs "${USER_AND_SERVER}:${TARGET_PATH}" "$SSHFS_MOUNT_PATH" -o Cipher="arcfour"
  return $?
}


umount_remote_sshfs()
{
  fusermount -u "$SSHFS_MOUNT_PATH"
  return $?
}


mount_remote_encfs()
{
  if mount_remote_sshfs; then
    mkdir -p "$ENCFS_MOUNT_PATH"
    if ENCFS6_CONFIG="$ENCFS_CONF_FILE" encfs --extpass="echo "$ENCFS_PASSWORD"" --standard "$SSHFS_MOUNT_PATH" "$ENCFS_MOUNT_PATH"; then
      return 0
    fi
  fi

  return 1
}


umount_remote_encfs()
{
  fusermount -u "$ENCFS_MOUNT_PATH"
  umount_remote_sshfs;
}


mount_rev_encfs()
{
  mkdir -p "$ENCFS_MOUNT_PATH"

  if ENCFS6_CONFIG="$ENCFS_CONF_FILE" encfs --reverse --extpass="echo "$ENCFS_PASSWORD"" --standard "$1" "$ENCFS_MOUNT_PATH"; then
    return 0
  fi

  return 1
}


umount_encfs()
{
  fusermount -u "$ENCFS_MOUNT_PATH"
}


encode_path()
{
  if [ "$ENCFS_ENABLE" != "0" ]; then
    ENCFS6_CONFIG="$ENCFS_CONF_FILE" encfsctl encode --extpass="echo "$ENCFS_PASSWORD"" -- "$1" "$2"
  else
    echo "$1"
  fi
}


decode_path()
{
  if [ "$ENCFS_ENABLE" != "0" ]; then
    ENCFS6_CONFIG="$ENCFS_CONF_FILE" encfsctl decode --extpass="echo "$ENCFS_PASSWORD"" -- "$1" "$2"
  else
    echo "$1"
  fi
}


rsync_parse()
{
  # NOTE: This is currently really slow due to encfsctl decode performing really bad
  IFS=$EOL
  while read LINE; do
    case "$LINE" in
      "send: "*)              echo "send: $(decode_path "$1" $(echo "$LINE" |cut -f1 -d' ' --complement))"
                              ;;
      "del.: "*)              echo "del.: $(decode_path "$1" $(echo "$LINE" |cut -f1 -d' ' --complement))"
                              ;;
      "created directory "*)  echo "created directory: $(decode_path "$1" $(echo "$LINE" |cut -f1 -d' ' --complement))"
                              ;;
      *)                      echo "$LINE"
                              ;;
    esac
  done
}


check_command()
{
  local path IFS

  IFS=' '
  for cmd in $*; do
    if [ -n "$(which "$cmd" 2>/dev/null)" ]; then
      return 0
    fi
  done

  return 1
}


# Check whether a binary is available and if not, generate an error and stop program execution
check_command_error()
{
  local IFS=' '

  if ! check_command "$@"; then
    printf "\033[40m\033[1;31mERROR  : Command(s) \"$(echo "$@" |tr ' ' '|')\" is/are not available!\033[0m\n" >&2
    printf "\033[40m\033[1;31m         Please investigate. Quitting...\033[0m\n" >&2
    echo ""
    exit 2
  fi
}


backup()
{
  while true; do
    CUR_DATE=`date "+%Y-%m-%d"`

    IFS=' '
    for ITEM in $BACKUP_DIRS; do
      # Determine folder name to use on target
      if echo "$ITEM" |grep -q ':'; then
        SUB_DIR="$(echo "$ITEM" |cut -f2 -d':')"
        SOURCE_DIR="$(echo "$ITEM" |cut -f1 -d':')"
      else
        SUB_DIR="$(echo "$ITEM" |tr / _)"
        SOURCE_DIR="$ITEM"
      fi

      # Reverse encode local path
      if [ "$ENCFS_ENABLE" != "0" ]; then
        umount_encfs 2>/dev/null # First unmount

        if ! mount_rev_encfs "$SOURCE_DIR"; then
          echo "ERROR: ENCFS mount failed. Aborting backup for $SOURCE_DIR!" >&2
          continue;
        fi
      fi

      umount_remote_sshfs 2>/dev/null # First unmount
      if ! mount_remote_sshfs; then
        echo "ERROR: SSHFS mount failed. Aborting backup for $SOURCE_DIR!" >&2
        continue;
      fi

      # Create remote directory 
      ENCODED_SUB_PATH="$(encode_path "$SOURCE_DIR" "$SUB_DIR")"
      if ! mkdir -p -- "$SSHFS_MOUNT_PATH/$ENCODED_SUB_PATH"; then
        echo "ERROR: Unable to create remote target directory \"${SSHFS_MOUNT_PATH}/${ENCODED_SUB_PATH}\". Aborting backup for $SOURCE_DIR!" >&2
        continue;
      fi

      # First check whether there are any changes
      echo "* Checking for changes in $SOURCE_DIR..."

      # Look for already existing snapshot directories
      FOUND_SYNC=0
      FOUND_CURRENT=0
      LAST_SNAPSHOT_ENC=""

      # TODO: Instead of using stat, check the actual folder-name (just remove the xargs stat?)
      IFS=$EOL
      for ITEM in `find "$SSHFS_MOUNT_PATH/$ENCODED_SUB_PATH/" -maxdepth 1 -mindepth 1 -type d -print0 |xargs -r0 stat -c "%Y${TAB}%n" |sort -r |head -n3`; do
        NAME="$(basename "$(echo "$ITEM" |cut -f2)")"
        DECODED_NAME="$(decode_path "$SOURCE_DIR" "$NAME")"

        case $DECODED_NAME in
          .sync              ) FOUND_SYNC=1
                               echo "* .sync folder found"
                               ;;
          snapshot_$CUR_DATE ) FOUND_CURRENT=1
                               echo "* $DECODED_NAME (current date) folder found"
                               ;;
          snapshot_*         ) if [ -z "$LAST_SNAPSHOT_ENC" ]; then
                                 LAST_SNAPSHOT_ENC="$NAME" # Use last snapshot as base
                                 echo "* $DECODED_NAME (previous date) folder found"
                               fi
                               ;;
        esac
      done

      # Construct rsync line depending on the info we just retrieved
      RSYNC_LINE="-rtlx --safe-links  --fuzzy --delete --delete-after --delete-excluded --log-format='%o: %n%L' -e 'ssh -q -c arcfour'"

      if [ -n "$BW_LIMIT" ]; then
        RSYNC_LINE="$RSYNC_LINE --bwlimit=$BW_LIMIT"
      fi

      if [ -n "$EXCLUDE_DIRS" ]; then
        IFS=' '
        for EXDIR in $EXCLUDE_DIRS; do
          RSYNC_LINE="$RSYNC_LINE --exclude $(encode_path "$SOURCE_DIR" "$EXDIR")/"
        done
      fi

      if [ -n "$LAST_SNAPSHOT_ENC" ]; then
        RSYNC_LINE="$RSYNC_LINE --link-dest=../$LAST_SNAPSHOT_ENC"
      fi

      if [ "$ENCFS_ENABLE" != "0" ]; then
        RSYNC_LINE="$RSYNC_LINE "$ENCFS_MOUNT_PATH/""
      else
        RSYNC_LINE="$RSYNC_LINE "$SOURCE_DIR/""
      fi

      if [ $FOUND_CURRENT -eq 1 ]; then
        SNAPSHOT_DIR="snapshot_${CUR_DATE}"
      else
        SNAPSHOT_DIR=".sync"
      fi
      RSYNC_LINE="$RSYNC_LINE -- "${USER_AND_SERVER}:\"${TARGET_PATH}/$(encode_path "$SOURCE_DIR" "$SUB_DIR/$SNAPSHOT_DIR")/\"""

      if [ -n "$EXCLUDE_DIRS" ]; then
        echo "* Excluding folders: $EXCLUDE_DIRS"
      fi
#        echo "-> $RSYNC_LINE"

      # Need to unset IFS for commandline parse to work properly
      unset IFS
      # NOTE: Ignore root (eg. permission) changes with ' ./$'
      # NOTE: We use rsync + ssh directly (without sshfs) as this is much faster
      # TODO: Can we optimise this by aborting on the first change?:
      change_count="$(eval rsync -i --dry-run $RSYNC_LINE |grep -v ' ./$' |wc -l)"

      if [ $change_count -gt 0 ]; then
        echo "* $change_count changes detected -> syncing remote..."

        RSYNC_LINE="-v --log-file="$LOG_FILE" $RSYNC_LINE"

        if [ "$VERBOSE" = "1" ]; then
          RSYNC_LINE="--progress $RSYNC_LINE"
        fi

        if [ $DRY_RUN -eq 1 ]; then
          RSYNC_LINE="--dry-run $RSYNC_LINE"
        fi

        echo "-> rsync $RSYNC_LINE"

        if [ $DECODE -eq 0 ]; then
          eval rsync $RSYNC_LINE 2>&1
          retval=$?
        else
          eval rsync $RSYNC_LINE 2>&1 |rsync_parse "$SOURCE_DIR"
          retval=$?
        fi

        if [ $retval -eq 0 ]; then

          # Update timestamp on base folder:
          if [ $FOUND_CURRENT -ne 1 ]; then
            # Rename .sync to current date-snapshot
            echo "* Renaming \"${SSHFS_MOUNT_PATH}/${SUB_DIR}/.sync\" to \"${SSHFS_MOUNT_PATH}/${SUB_DIR}/snapshot_${CUR_DATE}\""
            if [ $DRY_RUN -eq 0 ]; then
              mv -- "$SSHFS_MOUNT_PATH/$(encode_path "$SOURCE_DIR" "$SUB_DIR/.sync")" "$SSHFS_MOUNT_PATH/$(encode_path "$SOURCE_DIR" "$SUB_DIR/snapshot_$CUR_DATE")"
            fi
          fi

          echo "* Setting permissions 750 for \"$SSHFS_MOUNT_PATH/$SUB_DIR/snapshot_${CUR_DATE}\""
          if [ $DRY_RUN -eq 0 ]; then
            chmod 750 -- "$SSHFS_MOUNT_PATH/$(encode_path "$SOURCE_DIR" "$SUB_DIR/snapshot_${CUR_DATE}")"
            touch -- "$SSHFS_MOUNT_PATH/$(encode_path "$SOURCE_DIR" "$SUB_DIR/snapshot_${CUR_DATE}")"
          fi
        else
          echo "ERROR: rsync failed" >&2
          # TODO: Log to root
          #. Showing log file:" >&2
          #grep -v -e 'building file list' -e 'files to consider' "$LOG_FILE"
        fi
      else
        echo "* No changes detected..."
      fi

      if [ "$ENCFS_ENABLE" != "0" ]; then
        umount_encfs;
      fi

      umount_remote_sshfs;
    done

    if [ $BACKGROUND -eq 0 -a $FOREGROUND -eq 0 ]; then
      # We're done
      break;
    fi

    # Sleep till the next sync
    echo "* Sleeping $(($SLEEP_TIME / 60)) minutes..."
    sleep $SLEEP_TIME
  done
}


show_help()
{
  echo "Usage: psnapshot-enc.sh [options]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "--help|-h                   - Print this help" >&2
  echo "--init|-i                   - Init encfs (for the first time)" >&2
  echo "--test|--dry-run            - Only show what would be performed (test run)" >&2
  echo "--background                - Background daemon mode" >&2
  echo "--foreground                - Foreground daemon mode" >&2
  echo "--mount                     - Mount remote sshfs/encfs filesystem" >&2
  echo "--umount                    - Umount remote sshfs/encfs filesystem" >&2
  echo "--conf|-c={config_file}     - Specify alternate configuration file" >&2
  echo ""
}


sanity_check()
{
  IFS=' '
  for ITEM in $BACKUP_DIRS; do
    # Determine folder name to use on target
    if echo "$ITEM" |grep -q ':'; then
      SOURCE_DIR="$(echo "$ITEM" |cut -f1 -d':')"
    else
      SOURCE_DIR="$ITEM"
    fi

    if [ ! -e "$SOURCE_DIR" ]; then
      echo "ERROR: Source directory $SOURCE_DIR does NOT exist!" >&2
      echo ""
      exit 1
    fi
  done

  if [ -z "$USER_AND_SERVER" ]; then
    echo "ERROR: Missing USER_AND_SERVER setting. Check $CONF_FILE" >&2
    echo ""
    exit 1
  fi

  if [ -z "$LOG_FILE" ]; then
    echo "ERROR: Missing LOG_FILE setting. Check $CONF_FILE" >&2
    echo ""
    exit 1
  fi

  if [ "$ENCFS_ENABLE" != "0" ]; then
    if [ -z "$ENCFS_CONF_FILE" ]; then
      echo "ERROR: Missing ENCFS_CONF_FILE setting. Check $CONF_FILE" >&2
      echo ""
      exit 1
    fi

    if [ -z "$ENCFS_PASSWORD" ]; then
      echo "ERROR: Missing ENCFS_PASSWORD setting. Check $CONF_FILE" >&2
      echo ""
      exit 1
    fi

    if [ $INIT -eq 0 -a ! -e "$ENCFS_CONF_FILE" ]; then
      echo "ERROR: Missing ENCFS_CONF_FILE($ENCFS_CONF_FILE) not found. You need to run with --init first!" >&2
      echo ""
      exit 1
    fi

    check_command_error encfs
    check_command_error encfsctl
  fi

  check_command_error fusermount
  check_command_error sshfs
  check_command_error rsync
  check_command_error basename
  check_command_error date
}


process_commandline()
{
  # Set environment variables to default
  DRY_RUN=0
  INIT=0
  MOUNT=0
  UMOUNT=0
  BACKGROUND=0
  FOREGROUND=0
  DECODE=0
  CONF_FILE=""

  # Check arguments
  unset IFS
  for arg in $*; do
    ARGNAME=`echo "$arg" |cut -d= -f1`
    ARGVAL=`echo "$arg" |cut -d= -f2 -s`

    case "$ARGNAME" in
              --conf|-c) CONF_FILE="$ARGVAL";;
       --dry-run|--test) DRY_RUN=1;;
                --mount) MOUNT=1;;
        --background|-b) BACKGROUND=1;;
           --foreground) FOREGROUND=1;;
               --decode) DECODE=1;;
               --umount) UMOUNT=1;;
              --init|-i) INIT=1;;
              --help|-h) show_help;
                         exit 0
                         ;;
                     -*) echo "ERROR: Bad argument \"$arg\"" >&2
                         show_help;
                         exit 1;
                         ;;
                      *) if [ -z "$CONF_FILE" ]; then
                           CONF_FILE="$arg"
                         else
                           echo "ERROR: Bad command syntax with argument \"$arg\"" >&2
                           show_help;
                           exit 1;
                         fi
                         ;;
    esac
  done

  if [ -z "$CONF_FILE" ]; then
    CONF_FILE="$DEFAULT_CONF_FILE"
  fi

  if [ -z "$ENCFS_CONF_FILE" ]; then
    ENCFS_CONF_FILE="$HOME/.encfs6.xml"
  fi

  if [ -z "$SLEEP_TIME" ]; then
    SLEEP_TIME=900
  fi

  if [ -z "$ENCFS_MOUNT_PATH" ]; then
    ENCFS_MOUNT_PATH="/mnt/encfs"
  fi

  if [ -z "$SSHFS_MOUNT_PATH" ]; then
    SSHFS_MOUNT_PATH="/mnt/sshfs"
  fi
}


# Mainline:
###########
echo "psnapshot-enc v$MY_VERSION - (C) Copyright 2014-2015 by Arno van Amersfoort"
echo ""

process_commandline $*;

if [ -z "$CONF_FILE" -o ! -e "$CONF_FILE" ]; then
  echo "ERROR: Missing config file ($CONF_FILE)!" >&2
  echo ""
  exit 1
fi

# Source config file
. "$CONF_FILE"

sanity_check;

if [ $INIT -eq 1 ]; then
  umount_encfs 2>/dev/null

  echo "* Using ENCFS6 config file: $ENCFS_CONF_FILE"
  if mount_rev_encfs; then
    echo "* Done. Don't forget to backup your config file ($ENCFS_CONF_FILE)!"
    echo ""
    echo "You should now probably generate + setup SSH keys (if not done already)"
  else
    echo "ERROR: Init failed. Please investigate!" >&2
  fi

  echo ""
  umount_encfs;
elif [ $MOUNT -eq 1 ]; then
  echo "* Mounting remote SSHFS/ENCFS filesystem \"${USER_AND_SERVER}:${TARGET_PATH}\" on \"$ENCFS_MOUNT_PATH\" (via \"$SSHFS_MOUNT_PATH\")"

  umount_remote_encfs 2>/dev/null
  if mount_remote_encfs; then
    echo "* Done"
    echo ""
  else
    echo "ERROR: Mount failed. Please investigate!" >&2
  fi
elif [ $UMOUNT -eq 1 ]; then
  umount_remote_encfs;
  echo "* SSHFS/ENCFS filesystems unmounted"
  echo ""
else
  if [ -z "$TARGET_PATH" ]; then
    echo "ERROR: Missing TARGET_PATH setting. Check $CONF_FILE" >&2
    echo ""
    exit 1
  fi

  if [ -z "$BACKUP_DIRS" ]; then
    echo "ERROR: Missing BACKUP_DIRS setting. Check $CONF_FILE" >&2
    echo ""
    exit 1
  fi

  if [ $BACKGROUND -eq 1 ]; then
    backup &
  else
    backup
  fi
fi

# TODO: Parse log file and/or show changes with decoded names
# TODO: Cleanup old backups
# CTRL-C handler?

# TODO: move target directory creation to --init ?
# FIXME: detect empty mount point / wrong key
# TODO: On init detect non-empty remote folder
# TODO: ls remote after init?

# TODO: Locking
# TODO: Error mailing
