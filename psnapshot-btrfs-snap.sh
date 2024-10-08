#!/bin/sh

MY_VERSION="0.1-BETA10"
# ----------------------------------------------------------------------------------------------------------------------
# Arno's BTRFS Snapshot Script
# Last update: July 25, 2022
# (C) Copyright 2020-2022 by Arno van Amersfoort
# Web                   : https://github.com/arnova/psnapshot-enc
# Email                 : a r n o DOT v a n DOT a m e r s f o o r t AT g m a i l DOT c o m
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

# Set some defaults. May be overriden by conf or commandline options
CONF_FILE="/etc/psnapshot-btrfs-snap.conf"

SNAPSHOT_FOLDER_NAME=".snapshots"

DRY_RUN=0
EOL='
'

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
    exit 1
  fi
}


sanity_check()
{

  if [ -z "$BACKUP_VOLS" ]; then
    echo "ERROR: Missing BACKUP_VOLS-variable in config file!" >&2
    echo ""
    exit 1
  fi

  IFS=' '
  for VOL in $BACKUP_VOLS; do
    if [ ! -d "$VOL" ]; then
      echo "ERROR: BACKUP_VOLS volume \"$VOL\" does not exist!" >&2
      echo ""
      exit 1
    fi
  done

  check_command_error rsync
  check_command_error btrfs
  check_command_error date
}


cleanup_snapshots()
{
  local SNAPSHOT_SUBDIR="$1"
  local DAILY_COUNT=0 MONTHLY_COUNT=0 YEARLY_COUNT=0 MONTH_LAST=0 YEAR_LAST=0

  if [ -z $DAILY_KEEP -o $DAILY_KEEP -le 0 ]; then
    echo "ERROR: Bad or missing config variable DAILY_KEEP" >&2
    return 1
  fi

  if [ -z $MONTHLY_KEEP -o $MONTHLY_KEEP -le 0 ]; then
    echo "ERROR: Bad or missing config variable MONTHLY_KEEP" >&2
    return 1
  fi

  if [ -z $YEARLY_KEEP -o $YEARLY_KEEP -le 0 ]; then
    echo "ERROR: Bad or missing config variable YEARLY_KEEP" >&2
    return 1
  fi

  echo "* Performing cleanup for: $SNAPSHOT_SUBDIR"
  echo "* Retention config: Dailies=$DAILY_KEEP Monthlies=$MONTHLY_KEEP Yearlies=$YEARLY_KEEP"

  SNAPSHOT_DIR_LIST="$(find "$SNAPSHOT_SUBDIR/" -maxdepth 1 -mindepth 1 -type d |sort -r)"
  COUNT_TOTAL="$(echo "$SNAPSHOT_DIR_LIST" |wc -l)"

  echo "* Currently have $COUNT_TOTAL snapshot(s) stored"

  # Make sure there are sufficient backups
  if [ $COUNT_TOTAL -le 3 ]; then
    echo "  NOTE: Not performing cleanup due to low amount of existing backups($COUNT_TOTAL)"
    return 0
  fi

  COUNT=0
  IFS=$EOL
  for SNAPSHOT_DIR in $SNAPSHOT_DIR_LIST; do
    MTIME="$(echo "$SNAPSHOT_DIR" |sed s,'.*/',,)"

    if [ -z "$MTIME" ]; then
      echo "ASSERTION FAILURE: EMPTY MTIME IN SNAPSHOT DIR \"$SNAPSHOT_DIR\"" >&2
      return 1
    fi

    COUNT=$((COUNT + 1))

    YEAR_MTIME="$(echo "$MTIME" |cut -f1 -d'-')"
    MONTH_MTIME="$(echo "$MTIME" |cut -f2 -d'-')"
    DIR_NAME="$(basename "$SNAPSHOT_DIR")"

    KEEP=0
    if [ $DAILY_COUNT -lt $DAILY_KEEP ]; then
      DAILY_COUNT=$((DAILY_COUNT + 1))
      # We want to keep this day
      echo "  KEEP DAILY  : $DIR_NAME"
      KEEP=1
    fi

    if [ $KEEP -eq 0 -a $MONTHLY_COUNT -lt $MONTHLY_KEEP ]; then
      #TODO: Review the logic below
      if [ $MONTH_MTIME -ne $MONTH_LAST -o $YEAR_MTIME -ne $YEAR_LAST ] || [ $COUNT -eq $COUNT_TOTAL ]; then
        # We want to keep this month
        MONTHLY_COUNT=$((MONTHLY_COUNT + 1))
        MONTH_LAST=$MONTH_MTIME

        echo "  KEEP MONTHLY: $DIR_NAME"
        YEAR_LAST=$YEAR_MTIME
        KEEP=1
      fi
    fi

    if [ $KEEP -eq 0 -a $YEARLY_COUNT -lt $YEARLY_KEEP ]; then
      if [ $YEAR_MTIME -ne $YEAR_LAST ] || [ $COUNT -eq $COUNT_TOTAL ]; then
        YEARLY_COUNT=$((YEARLY_COUNT + 1))
        YEAR_LAST=$YEAR_MTIME

        # We want to keep this year
        echo "  KEEP YEARLY : $DIR_NAME"
        KEEP=1
      fi
    fi

    if [ $KEEP -eq 0 ]; then
      echo "  REMOVE      : $DIR_NAME"
      echo "    btrfs subvolume delete $SNAPSHOT_DIR"

      if [ $DRY_RUN -eq 0 ]; then
        if ! btrfs subvolume delete "$SNAPSHOT_DIR"; then
          echo "  ERROR: Removing snapshot $SNAPSHOT_DIR failed" >&2
          return 1
        fi
      fi
    fi
  done
  echo ""

  return 0
}


create_snapshot()
{
  local ROOT_DIR="$1"
  local COUNT=0

  TODAY="$(date +%Y-%m-%d)"
  echo "* Today is: \"$TODAY\""

  if [ -d "$ROOT_DIR/$SNAPSHOT_FOLDER_NAME/$TODAY" ]; then
    echo "* NOTE: Not creating snapshot since one already exists for \"$TODAY\"" >&2
    return 1
  fi

  local LAST_SNAPSHOT="$(find "$ROOT_DIR/$SNAPSHOT_FOLDER_NAME/" -mindepth 1 -maxdepth 1 -type d |sort -r |head -n1)"

  if [ -z "$LAST_SNAPSHOT" ]; then
    echo "* NOTE: No existing snapshot(s) found, generating initial one"
  else
    echo "* Found previous snapshot \"$LAST_SNAPSHOT\""

    # NOTE: Ignore root (eg. permission) changes with ' ./$' and non-regular files
    COUNT="$(rsync -a --delete --log-format='%o: %n%L' --exclude=.snapshots/ --dry-run "$ROOT_DIR/" "$LAST_SNAPSHOT/" |grep -e '^send: ' -e '^del\.: '|grep -v -e '^$' -e ' ./$' -e '^skipping non-regular file' |wc -l)"

    if [ $COUNT -eq 0 ]; then
      echo "* No changes found, skipping creation of a new snapshot"
      return 1
    fi
  fi

  # Create read-only snapshot
  echo "* $COUNT change(s) found, creating new snapshot"
  if ! btrfs subvolume snapshot -r "$ROOT_DIR" "$ROOT_DIR/$SNAPSHOT_FOLDER_NAME/$TODAY"; then
    echo "ERROR: Unable to create btrfs snapshot" >&2
    return 1
  fi

  return 0
}


# Mainline:
###########
echo "btrfs-snapshot v$MY_VERSION - (C) Copyright 2020 by Arno van Amersfoort"
echo ""

if [ -z "$CONF_FILE" -o ! -f "$CONF_FILE" ]; then
  echo "ERROR: Missing config file ($CONF_FILE)!" >&2
  echo "" >&2
  exit 1
fi

# Source config file
. "$CONF_FILE"

if [ "$1" = "--dryrun" -o "$1" = "-n" ]; then
  DRY_RUN=1
fi

sanity_check

IFS=' '
for VOL in $BACKUP_VOLS; do
  echo "* Processing volume \"$VOL\"..."
  if ! create_snapshot "$VOL"; then
    echo ""
  else
    cleanup_snapshots "$VOL/$SNAPSHOT_FOLDER_NAME"
  fi
done

echo "$(date +'%b %d %k:%M:%S') All backups done..."

