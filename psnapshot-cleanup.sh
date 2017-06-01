#!/bin/sh

MY_VERSION="0.20-ALPHA1"
# ----------------------------------------------------------------------------------------------------------------------
# Arno's Push-Snapshot Server-Side Cleanup Script
# Last update: May 17, 2017
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

# Set some defaults. May be overriden by conf or commandline options
CONF_FILE="/etc/psnapshot-cleanup.conf"

EOL='
'
TAB=$(printf "\t")


cleanup()
{
  IFS=' '
  for DIR in $SNAPSHOT_DIRS; do
    echo "* Checking: $DIR"
    if [ ! -d "$DIR" ]; then
      echo " DIR \"$DIR\" DOES NOT EXIST!" >&2
      continue
    fi

    # Set sticky bit on base dir
#    chmod 1750 "$DIR"

    DAILY_COUNT=0
    MONTHLY_COUNT=0
    YEARLY_COUNT=0
    MONTH_LAST=0
    YEAR_LAST=0

    MTIME_SUBDIR_LIST="$(find "$DIR/" -maxdepth 1 -mindepth 1 -type d -print0 |xargs -r0 stat -c "%y${TAB}%n" |sort -r)"
    COUNT_TOTAL="$(echo "$MTIME_SUBDIR_LIST" |wc -l)"
    COUNT=0
    IFS=$EOL
    for MTIME_SUBDIR in $MTIME_SUBDIR_LIST; do
      SUBDIR="$(echo "$MTIME_SUBDIR" |cut -f2)"
      MTIME="$(echo "$MTIME_SUBDIR" |cut -f1 -d' ')"

      if [ -z "$SUBDIR" ]; then
        echo "ASSERTION FAILURE: EMPTY SUBDIR" >&2
        exit 1
      fi

  #    echo "* SUBDIR: $SUBDIR"
      COUNT=$((COUNT + 1))

      # Skip the newest (.sync and newest date)
      if [ $COUNT -gt 1 ]; then
        if [ $DRYRUN -eq 0 ]; then
          chown 0:0 "$SUBDIR"
          chmod 755 "$SUBDIR"
        else
          echo "chown 0:0 $SUBDIR"
          echo "chmod 755 $SUBDIR"
        fi

        IFS=$EOL
        find "$SUBDIR/" ! -uid 0 ! -type l |while read FN; do
          # Make files readonly
          if [ $DRYRUN -eq 0 ]; then
            chmod -w "$FN"
          else
            echo "chmod -w $FN"
          fi
        done

        MTIME_YEAR="$(echo "$MTIME" |cut -f1 -d'-')"
        MTIME_MONTH="$(echo "$MTIME" |cut -f2 -d'-')"
        DIR_NAME="$(basename "$SUBDIR")"

        KEEP=0
        if [ $DAILY_COUNT -le $DAILY_KEEP ]; then
          DAILY_COUNT=$((DAILY_COUNT + 1))
          # We want to keep this day
          echo "KEEP DAILY $MTIME: $DIR_NAME"
          KEEP=1
        fi

        if [ $MONTHLY_COUNT -le $MONTHLY_KEEP ] && [ $MTIME_MONTH -ne $MONTH_LAST -o $MTIME_YEAR -ne $YEAR_LAST ]; then
          # We want to keep this month
          MONTHLY_COUNT=$((MONTHLY_COUNT + 1))
          MONTH_LAST=$MTIME_MONTH

          echo "KEEP MONTHLY $MTIME: $DIR_NAME"
          YEAR_LAST=$MTIME_YEAR
          KEEP=1
        fi

        if [ $YEARLY_COUNT -le $YEARLY_KEEP ] && [ $MTIME_YEAR -ne $YEAR_LAST -o $COUNT -eq $COUNT_TOTAL ]; then
          YEARLY_COUNT=$((YEARLY_COUNT + 1))
          YEAR_LAST=$MTIME_YEAR

          # We want to keep this year
          echo "KEEP YEARLY $MTIME: $DIR_NAME"
          KEEP=1
        fi

        if [ $KEEP -eq 0 ]; then
          echo "REMOVE $MTIME: $DIR_NAME"
          if [ $DRYRUN -eq 0 ]; then
            rm -rf "$SUBDIR"
          else
            echo "rm -rf $SUBDIR"
          fi
        fi
      fi
    done
    echo ""
  done
}


sanity_check()
{
  if [ -z "$SNAPSHOT_DIRS" -o -z "$DAILY_KEEP" -o -z "$MONTHLY_KEEP" -o -z "$YEARLY_COUNT" ]; then
    echo "ERROR: Missing config options in $CONF_FILE" >&2
    echo "" >&2
    exit 1
  fi
}


show_help()
{
  echo "Usage: psnapshot-cleanup.sh [options]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "--help|-h                   - Print this help" >&2
  echo "--test|--dry-run            - Only show what would be performed (test run)" >&2
  echo "--verbose                   - Be verbose with displaying info" >&2
  echo "--conf|-c={config_file}     - Specify alternate configuration file (default=$CONF_FILE)" >&2
  echo ""
}


process_commandline_and_load_conf()
{
  # Set environment variables to default
  DRY_RUN=0

  OPT_VERBOSE=0
  OPT_CONF_FILE=""

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
                           OPT_CONF_FILE="$ARGVAL"
                         fi
                         ;;
       --dry-run|--test) DRY_RUN=1;;
           --verbose|-v) OPT_VERBOSE=1;;
              --help|-h) show_help;
                         exit 0
                         ;;
                     --) shift
                         # Check for remaining arguments
                         if [ -n "$*" ]; then
                           if [ -z "$OPT_CONF_FILE" ]; then
                             OPT_CONF_FILE="$*"
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
                      *) if [ -z "$OPT_CONF_FILE" ]; then
                           OPT_CONF_FILE="$ARG"
                         else
                           echo "ERROR: Bad command syntax with argument \"$ARG\"" >&2
                           show_help
                           exit 1
                         fi
                         ;;
    esac

    shift # Next argument
  done

  # Fallback to default in case it's not specified
  if [ -n "$OPT_CONF_FILE" ]; then
    CONF_FILE="$OPT_CONF_FILE"
  fi

  if [ -z "$CONF_FILE" -o ! -e "$CONF_FILE" ]; then
    echo "ERROR: Missing config file ($CONF_FILE)!" >&2
    echo "" >&2
    exit 1
  fi

  # Source config file
  . "$CONF_FILE"

  # Special handling for verbose
  if [ "$VERBOSE" != "1" ]; then
    VERBOSE="$OPT_VERBOSE"
  fi
}


# Mainline:
###########
echo "psnapshot-enc cleanup v$MY_VERSION - (C) Copyright 2014-2017 by Arno van Amersfoort"
echo ""

process_commandline_and_load_conf $*

sanity_check

cleanup

exit 0
