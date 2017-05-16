#!/bin/sh

MY_VERSION="0.30-BETA4"
# ----------------------------------------------------------------------------------------------------------------------
# Arno's Push-Snapshot Script using ENCFS + RSYNC + SSH
# Last update: May 16, 2017
# (C) Copyright 2014-2017 by Arno van Amersfoort
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

EOL='
'
TAB=$(printf "\t")

# Functions:
############

mount_remote_sshfs()
{
  mkdir -p "$SSHFS_MOUNT_PATH"

  if [ $(id -u) -eq 0 ]; then
    sshfs "${USER_AND_SERVER}:${TARGET_PATH}/$1" "$SSHFS_MOUNT_PATH" -o Cipher="$SSH_CIPHER" -o nonempty
  else
    sshfs "${USER_AND_SERVER}:${TARGET_PATH}/$1" "$SSHFS_MOUNT_PATH" -o Cipher="$SSH_CIPHER",uid="$(id -u)",gid="$(id -g)" -o nonempty
  fi
  return $?
}


umount_remote_sshfs()
{
  fusermount -u "$SSHFS_MOUNT_PATH"
  return $?
}


mount_remote_encfs()
{
  if mount_remote_sshfs "$1"; then
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


encode_item()
{
  local result

  if [ "$ENCFS_ENABLE" != "0" -a -n "$2" ]; then
    result=`ENCFS6_CONFIG="$ENCFS_CONF_FILE" encfsctl encode --extpass="echo "$ENCFS_PASSWORD"" -- "$1" "$2"`
    if [ -n "$result" ]; then
      echo "$result"
      return
    fi
  fi

  echo "$2"
}


decode_item()
{
  local result

  if [ "$ENCFS_ENABLE" != "0" -a -n "$2" ]; then
    result=`ENCFS6_CONFIG="$ENCFS_CONF_FILE" encfsctl decode --extpass="echo "$ENCFS_PASSWORD"" -- "$1" "$2"`
    if [ -n "$result" ]; then
      echo "$result"
      return
    fi
  fi

  echo "$2"
}


rsync_decode_path()
{
  local SUB_DIR
  local FIRST=1
  local RSYNC_PATH="$(echo "$2" |sed -e 's!^\"!!' -e 's!\"$!!')"

  # Split full path (/ separator)
  IFS='/'
  for SUB_DIR in $RSYNC_PATH; do
    if [ $FIRST -eq 0 ] || echo "$RSYNC_PATH" |grep -q '^/'; then
      printf "/"
    fi
    printf "$(decode_item "$1" "$SUB_DIR")"
    FIRST=0
  done

  if echo "$RSYNC_PATH" |grep -q '/$'; then
    echo "/"
  fi
}


rsync_parse()
{
  # NOTE: This is currently really slow due to encfsctl decode performing really bad
  IFS=$EOL
  while read LINE; do
    case "$LINE" in
                          "send: "*) echo "send: $(decode_item "$1" $(echo "$LINE" |cut -f1 -d' ' --complement))"
                                     ;;
                          "del.: "*) echo "del.: $(decode_item "$1" $(echo "$LINE" |cut -f1 -d' ' --complement))"
                                     ;;
      "skipping non-regular file "*) echo "skipping non-regular file $(rsync_decode_path "$1" $(echo "$LINE" |cut -f1,2,3 -d' ' --complement))"
                                     ;;
              "created directory "*) echo "created directory: $(decode_item "$1" $(echo "$LINE" |cut -f1,2 -d' ' --complement))"
                                     ;;
                                  *) echo "$LINE"
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
  local RET=0

  CUR_DATE=`date "+%Y-%m-%d"`

  IFS=' '
  for ITEM in $BACKUP_DIRS; do
    # Determine folder name to use on target
    if echo "$ITEM" |grep -q ':'; then
      SUB_DIR="$(echo "$ITEM" |cut -f2 -d':')"
      SOURCE_DIR="$(echo "$ITEM" |cut -f1 -d':')"
    else
      # No sub dir specified, use basename
#      SUB_DIR="$(echo "$ITEM" |tr / _)"
      SUB_DIR="$(basename "$ITEM")"
      SOURCE_DIR="$ITEM"
    fi

    DATE=`LC_ALL=C date +'%b %d %H:%M:%S'`
    echo "* $DATE - Inspecting $SOURCE_DIR" |tee -a "$LOG_FILE"

    # Reverse encode local path
    if [ "$ENCFS_ENABLE" != "0" ]; then
      umount_encfs 2>/dev/null # First unmount

      if ! mount_rev_encfs "$SOURCE_DIR"; then
        echo "ERROR: ENCFS mount of \"$SOURCE_DIR\" on \"$ENCFS_MOUNT_PATH\" failed. Aborting backup for $SOURCE_DIR!" >&2
        echo "ERROR: ENCFS mount of \"$SOURCE_DIR\" on \"$ENCFS_MOUNT_PATH\" failed. Aborting backup for $SOURCE_DIR!" |tee -a "$LOG_FILE"
        RET=1
        continue;
      fi
    fi

    umount_remote_sshfs 2>/dev/null # First unmount
    if ! mount_remote_sshfs "$SUB_DIR"; then
      echo "ERROR: SSHFS mount of \"${USER_AND_SERVER}:${TARGET_PATH}/$SUB_DIR\" on \"$SSHFS_MOUNT_PATH\" failed. Aborting backup for $SOURCE_DIR!" >&2
      echo "ERROR: SSHFS mount of \"${USER_AND_SERVER}:${TARGET_PATH}/$SUB_DIR\" on \"$SSHFS_MOUNT_PATH\" failed. Aborting backup for $SOURCE_DIR!" |tee -a "$LOG_FILE"
      RET=1
      continue;
    fi

    # Look for already existing snapshot directories
    FOUND_SYNC=0
    FOUND_CURRENT=0
    LAST_SNAPSHOT_ENC=""

    # First get a list of all the snapshot folders
    DIR_LIST=""
    IFS=$EOL
    for ITEM in `find "$SSHFS_MOUNT_PATH/" -maxdepth 1 -mindepth 1 -type d`; do
      NAME="$(basename "$ITEM")"
      DECODED_NAME="$(decode_item "$SOURCE_DIR" "$NAME")"
      DIR_LIST="$DECODED_NAME $NAME\n$DIR_LIST"
    done

    IFS=$EOL
    for ITEM in `echo "$DIR_LIST" |sort -r |head -n3`; do
      DECODED_NAME="$(echo "$ITEM" |cut -d' ' -f1)"
      ENCODED_NAME="$(echo "$ITEM" |cut -d' ' -f2)"

      case $DECODED_NAME in
        .sync                ) FOUND_SYNC=1
                               echo "* .sync ($ENCODED_NAME) folder found" |tee -a "$LOG_FILE"
                               ;;
        snapshot_${CUR_DATE} ) FOUND_CURRENT=1
                               echo "* $DECODED_NAME ($ENCODED_NAME) current date folder found" |tee -a "$LOG_FILE"
                               ;;
        snapshot_*           ) if [ -z "$LAST_SNAPSHOT_ENC" ]; then
                                 LAST_SNAPSHOT_ENC="$ENCODED_NAME" # Use last snapshot as base
                                 echo "* $DECODED_NAME ($ENCODED_NAME) previous date folder found" |tee -a "$LOG_FILE"
                               fi
                               ;;
      esac
    done

    # Construct rsync line depending on the info we just retrieved
    # NOTE: We use rsync over ssh directly (without sshfs) as this is much faster
    RSYNC_LINE="-rtlx --safe-links --fuzzy --delete --delete-after --delete-excluded --log-format='%o: %n%L' -e 'ssh -q -c $SSH_CIPHER'"

    LIMIT=0
    if [ -n "$LIMIT_KB" ]; then
      if [ -n "$LIMIT_HOUR_START" -a -n "$LIMIT_HOUR_END" ]; then
        CHOUR=`date +'%H'`
        if [ $LIMIT_HOUR_START -le $LIMIT_HOUR_END ]; then
          if [ $CHOUR -ge $LIMIT_HOUR_START -a $CHOUR -le $LIMIT_HOUR_END ]; then
            LIMIT=1
          fi
        else
          # Handle wrapping
          if [ $CHOUR -ge $LIMIT_HOUR_START -o $CHOUR -le $LIMIT_HOUR_END ]; then
            LIMIT=1
          fi
        fi
      else
        LIMIT=1
      fi
    fi

    if [ $LIMIT -eq 1 ]; then
      RSYNC_LINE="$RSYNC_LINE --bwlimit=$LIMIT_KB"
    fi

    if [ -n "$EXCLUDE" ]; then
      IFS=' '
      for EX in $EXCLUDE; do
        RSYNC_LINE="$RSYNC_LINE --exclude \"$(encode_item "$SOURCE_DIR" "$EX")\""
      done
    fi

    if [ -n "$LAST_SNAPSHOT_ENC" ]; then
      RSYNC_LINE="$RSYNC_LINE --link-dest=\"../$LAST_SNAPSHOT_ENC\""
    fi

    if [ "$ENCFS_ENABLE" != "0" ]; then
      RSYNC_LINE="$RSYNC_LINE $ENCFS_MOUNT_PATH/"
    else
      RSYNC_LINE="$RSYNC_LINE $SOURCE_DIR/"
    fi

    if [ $FOUND_CURRENT -eq 1 ]; then
      SNAPSHOT_DIR="snapshot_${CUR_DATE}"
    else
      SNAPSHOT_DIR=".sync"
    fi
    RSYNC_LINE="$RSYNC_LINE -- "${USER_AND_SERVER}:\"${TARGET_PATH}/$SUB_DIR/$(encode_item "$SOURCE_DIR" "$SNAPSHOT_DIR")/\"""

    if [ -n "$EXCLUDE" ]; then
      echo "* Exclude(s): $EXCLUDE" |tee -a "$LOG_FILE"
    fi
#        echo "-> $RSYNC_LINE"

    echo "* Looking for changes..." |tee -a "$LOG_FILE"

    if [ $VERBOSE -eq 1 ]; then
      echo "-> rsync -i --dry-run $RSYNC_LINE" |tee -a "$LOG_FILE"
    fi

    # Need to unset IFS for commandline parse to work properly
    unset IFS
    result="$(eval rsync -i --dry-run $RSYNC_LINE)"
    retval=$?

    # NOTE: Ignore root (eg. permission) changes with ' ./$' and non-regular files
    change_count="$(echo "$result" |grep -v -e ' ./$' -e '^skipping non-regular file' |wc -l)"

    if [ $retval -ne 0 ]; then
      echo "ERROR: rsync failed ($retval)" >&2
      echo "ERROR: rsync failed ($retval)" |tee -a "$LOG_FILE"
      RET=1
    elif [ $change_count -gt 0 ]; then
      echo "* $change_count change(s) detected -> syncing to remote..." |tee -a "$LOG_FILE"

      RSYNC_LINE="-v --log-file="$LOG_FILE" $RSYNC_LINE"

      if [ $VERBOSE -eq 1 ]; then
        RSYNC_LINE="--progress $RSYNC_LINE"
      fi

      if [ $DRY_RUN -eq 1 ]; then
        RSYNC_LINE="--dry-run $RSYNC_LINE"
      fi

      if [ $VERBOSE -eq 1 ]; then
        echo "-> rsync $RSYNC_LINE" |tee -a "$LOG_FILE"
      fi

      if [ $DECODE -eq 0 ]; then
        eval rsync $RSYNC_LINE 2>&1
        retval=$?
      else
        eval rsync $RSYNC_LINE 2>&1 |rsync_parse "$SOURCE_DIR"
        retval=$?
      fi

      echo ""

      if [ $retval -eq 0 ]; then
        if [ $NO_ROTATE -eq 0 ]; then
          if [ $FOUND_CURRENT -ne 1 ]; then
            # Rename .sync to current date-snapshot
            echo "* Renaming \"${SUB_DIR}/.sync\" to \"${SUB_DIR}/snapshot_${CUR_DATE}\"" |tee -a "$LOG_FILE"
            if [ $DRY_RUN -eq 0 ]; then
              mv -- "$SSHFS_MOUNT_PATH/$(encode_item "$SOURCE_DIR" ".sync")" "$SSHFS_MOUNT_PATH/$(encode_item "$SOURCE_DIR" "snapshot_${CUR_DATE}")"
            fi
          fi

          echo "* Setting permissions 750 for \"$SUB_DIR/snapshot_${CUR_DATE}\"" |tee -a "$LOG_FILE"
          if [ $DRY_RUN -eq 0 ]; then
            chmod 750 -- "$SSHFS_MOUNT_PATH/$(encode_item "$SOURCE_DIR" "snapshot_${CUR_DATE}")"

            # Update timestamp on base folder:
            touch -- "$SSHFS_MOUNT_PATH/$(encode_item "$SOURCE_DIR" "snapshot_${CUR_DATE}")"
          fi
        else
          echo "* Setting permissions 750 for \"$SUB_DIR/.sync\"" |tee -a "$LOG_FILE"
          if [ $DRY_RUN -eq 0 ]; then
            chmod 750 -- "$SSHFS_MOUNT_PATH/$(encode_item "$SOURCE_DIR" ".sync")"

            # Update timestamp on base folder:
            touch -- "$SSHFS_MOUNT_PATH/$(encode_item "$SOURCE_DIR" ".sync")"
          fi
        fi
      else
        echo "ERROR: rsync failed" >&2
        echo "ERROR: rsync failed" |tee -a "$LOG_FILE"
        RET=1
        # TODO: Log to root
        #. Showing log file:" >&2
        #grep -v -e 'building file list' -e 'files to consider' "$LOG_FILE"
      fi
    else
      echo "* No changes detected..." |tee -a "$LOG_FILE"
    fi

    if [ "$ENCFS_ENABLE" != "0" ]; then
      umount_encfs;
    fi

    umount_remote_sshfs;

    DATE=`LC_ALL=C date +'%b %d %H:%M:%S'`
    echo "* $DATE - Finished sync of $SOURCE_DIR" |tee -a "$LOG_FILE"
    echo "" |tee -a "$LOG_FILE"
  done

  return $RET
}


remote_init()
{
  local RET=0

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

  IFS=' '
  for ITEM in $BACKUP_DIRS; do
    # Determine folder name to use on target
    if echo "$ITEM" |grep -q ':'; then
      SUB_DIR="$(echo "$ITEM" |cut -f2 -d':')"
      SOURCE_DIR="$(echo "$ITEM" |cut -f1 -d':')"
    else
      # No sub dir specified, use basename
#      SUB_DIR="$(echo "$ITEM" |tr / _)"
      SUB_DIR="$(basename "$ITEM")"
      SOURCE_DIR="$ITEM"
    fi

    umount_remote_sshfs 2>/dev/null # First unmount
    if ! mount_remote_sshfs; then
      echo "ERROR: SSHFS mount of \"${USER_AND_SERVER}:${TARGET_PATH}\" on \"$SSHFS_MOUNT_PATH\" failed!" >&2
      RET=1
      continue;
    fi

    # Create remote directory 
    if [ -d "$SSHFS_MOUNT_PATH/$SUB_DIR" ]; then
      echo "WARNING: Remote directory \"(${SSHFS_MOUNT_PATH}/)$SUB_DIR\" already exists!" >&2
    elif ! mkdir -p -- "$SSHFS_MOUNT_PATH/$SUB_DIR"; then
      echo "ERROR: Unable to create remote target directory \"(${SSHFS_MOUNT_PATH}/)$SUB_DIR}\"!" >&2
      RET=1
      continue;
    fi

    umount_remote_sshfs
  done

  return RET
}


backup_bg_process()
{
  while true; do
    result="$(backup 2>&1)"
    retval=$?

    if [ $retval -ne 0 ] || echo "$result" |grep -q -i -e error -e warning -e fail ]; then
      printf "Subject: psnapshot FAILURE\n$result\n" |sendmail "$MAIL_TO"
    fi

    # Sleep till the next sync
    echo "* Sleeping $(($SLEEP_TIME / 60)) minutes..."
    sleep $SLEEP_TIME
  done
}


view_log_file()
{
  local LOG_FILE="$1"
  local SOURCE_DIR

  echo "Viewing log file \"$LOG_FILE\":"

  if [ ! -f "$LOG_FILE" ]; then
    echo "ERROR: Log file \"$LOG_FILE\" not found!"
    exit 1
  fi

  IFS=$EOL
  while read LINE; do
    # Detect rsync log line:
    if echo "$LINE" |grep -E -q '\[[0-9]+\]'; then
      LINE_STRIPPED="$(echo "$LINE" |cut -d' ' -f1,2,3 --complement)"

      # Now the first item is the rsync code
      ITEM_CHANGE_CHECK="$(echo "$LINE_STRIPPED" |cut -d' ' -f1)"

      # Simple check to determine whether this is an itemized list of changes
      if [ -n "$SOURCE_DIR" ] && echo "$ITEM_CHANGE_CHECK" |grep -E -q '^[c<\.][fdL][\.\+\?cst]+'; then
        printf "$(echo "$LINE" |cut -d' ' -f1,2,3,4) "
        echo "$(rsync_decode_path "$SOURCE_DIR" $(echo "$LINE_STRIPPED" |cut -d' ' -f1 --complement))"
      else
        # Just print the line
        echo "$LINE"
      fi
    else
      # Get SOURCE_DIR from log
      if echo "$LINE" |grep -E -q '^\* .* Inspecting '; then
        SOURCE_DIR="$(echo "$LINE" |sed -e 's!^\*.*Inspecting !!' -e 's!\.*$!!')"
      fi

      echo "$LINE"
    fi
  done < "$LOG_FILE"
}


# Read password from stdin but disable echo of it
read_stdin_password()
{
  local PASSWORD

  # Disable echo.
  stty -echo

  # Set up trap to ensure echo is enabled before exiting if the script
  # is terminated while echo is disabled.
  trap 'stty echo' EXIT

  # Read secret.
  read PASSWORD

  # Enable echo.
  stty echo
  trap - EXIT

  # Print a newline because the newline entered by the user after
  # entering the passcode is not echoed. This ensures that the
  # next line of output begins at a new line.
  echo "$PASSWORD"
}


show_help()
{
  echo "Usage: psnapshot-enc.sh [options]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "--help|-h                   - Print this help" >&2
  echo "--init|-i                   - Init encfs (for the first time)" >&2
  echo "--test|--dry-run            - Only show what would be performed (test run)" >&2
  echo "--norotate                  - Don't rotate .sync to current date folder when done" >&2
  echo "--decode                    - Decode encoded filesnames for display (slower!)" >&2
  echo "--verbose                   - Be verbose with displaying info" >&2
  echo "--background                - Background daemon mode" >&2
  echo "--foreground                - Foreground daemon mode" >&2
  echo "--mount={remote_dir}        - Mount remote sshfs/encfs filesystem" >&2
  echo "--umount                    - Umount remote sshfs/encfs filesystem" >&2
  echo "--logview={log_file}        - View (decoded) log file" >&2
  echo "--conf|-c={config_file}     - Specify alternate configuration file (default=~/.psnapshot.conf)" >&2
  echo "--cipher={cipher}           - Specify SSH cipher (default=arcfour)" >&2
  echo ""
}


sanity_check()
{
  if [ "$MOUNT" = "0" -a "$UMOUNT" = "0" ]; then
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
  fi

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
  MOUNT=""
  UMOUNT=0
  BACKGROUND=0
  FOREGROUND=0
  DECODE=0
  VERBOSE=0
  NO_ROTATE=0
  LOG_VIEW=""
  CONF_FILE=""

  # Check arguments
  while [ -n "$1" ]; do
    ARG="$1"
    ARGNAME=`echo "$ARG" |cut -d= -f1`
    ARGVAL=`echo "$ARG" |cut -d= -f2 -s`

    case "$ARGNAME" in
              --conf|-c) if [ -z "$ARGVAL" ]; then
                           echo "ERROR: Bad command syntax with argument \"$ARG\"" >&2
                           show_help
                           exit 1
                         else
                           CONF_FILE="$ARGVAL"
                         fi
                         ;;
               --cipher) if [ -z "$ARGVAL" ]; then
                           echo "ERROR: Bad command syntax with argument \"$ARG\"" >&2
                           show_help
                           exit 1
                         else
                           SSH_CIPHER="$ARGVAL"
                         fi
                         ;;
              --logview) if [ -z "$ARGVAL" ]; then
                           echo "ERROR: Bad command syntax with argument \"$ARG\"" >&2
                           show_help
                           exit 1
                         else
                           LOG_VIEW="$ARGVAL"
                         fi
                         ;;
       --dry-run|--test) DRY_RUN=1;;
                --mount) MOUNT="$ARGVAL";;
        --background|-b) BACKGROUND=1;;
           --foreground) FOREGROUND=1;;
               --decode) DECODE=1;;
             --norotate) NO_ROTATE=1;;
              --verbose) VERBOSE=1;;
               --umount) UMOUNT=1;;
              --init|-i) INIT=1;;
              --help|-h) show_help;
                         exit 0
                         ;;
                     --) shift
                         # Check for remaining arguments
                         if [ -n "$*" ]; then
                           if [ -z "$CONF_FILE" ]; then
                             CONF_FILE="$*"
                           else
                             echo "ERROR: Bad command syntax with argument \"$*\"" >&2
                             show_help
                             exit 1
                           fi
                         fi
                         break # We're done
                         ;;
                     -*) echo "ERROR: Bad argument \"$ARG\"" >&2
                         show_help
                         exit 1
                         ;;
                      *) if [ -z "$CONF_FILE" ]; then
                           CONF_FILE="$ARG"
                         else
                           echo "ERROR: Bad command syntax with argument \"$ARG\"" >&2
                           show_help
                           exit 1
                         fi
                         ;;
    esac

    shift # Next argument
  done

  if [ -z "$CONF_FILE" ]; then
    CONF_FILE="$HOME/.psnapshot-enc.conf"
  fi

  if [ -z "$SSH_CIPHER" ]; then
    SSH_CIPHER="arcfour"
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
echo "psnapshot-enc v$MY_VERSION - (C) Copyright 2014-2017 by Arno van Amersfoort"
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

if [ -z "$ENCFS_PASSWORD" -a "$UMOUNT" = "0" ]; then
  printf "* No password in config file. Enter ENCFS password: "

  ENCFS_PASSWORD="$(read_stdin_password)"

  echo ""
fi

if [ -z "$MAIL_TO" ]; then
  MAIL_TO="root"
fi

if [ -n "$LOG_VIEW" ]; then
  view_log_file "$LOG_VIEW"
elif [ $INIT -eq 1 ]; then
  remote_init
elif [ -n "$MOUNT" ]; then
  echo "* Mounting remote SSHFS/ENCFS filesystem \"${USER_AND_SERVER}:${TARGET_PATH}\" on \"$ENCFS_MOUNT_PATH/$MOUNT\" (via \"$SSHFS_MOUNT_PATH/$MOUNT\")"

  umount_remote_encfs 2>/dev/null
  if mount_remote_encfs "$MOUNT"; then
    echo "* Done"
    echo ""
  else
    echo "ERROR: Mount failed. Please investigate!" >&2
    exit 1
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

  # Rotate logfile
  rm -f "${LOG_FILE}.old"
  if [ -e "${LOG_FILE}" ]; then
    mv "${LOG_FILE}" "${LOG_FILE}.old"
  fi

  # Truncate logfile
  printf "" >"${LOG_FILE}"

  if [ $BACKGROUND -eq 1 -a $FOREGROUND -eq 0 ]; then
    backup_bg_process &
  else
    backup
  fi
fi

exit 0
