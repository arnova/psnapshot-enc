#!/bin/sh

EOL='
'
TAB=$(printf '\t')

# Settings:
DIRS="/mnt/archive/backup/barno/snapshots/0-hlc762KPRxK,dPoNxpcSQ2/ /mnt/archive/backup/barno/snapshots/NizqzNKnjGYq-X1XeFKkXjGq/ /mnt/archive/backup/barno/snapshots/OoORCk6QW2SyfZX-Vj90Ecjl/"
DAILY_KEEP=14
MONTHLY_KEEP=3
YEARLY_KEEP=3

IFS=' '
for DIR in $DIRS; do
  echo "* Checking: $DIR"
  if [ ! -d "$DIR" ]; then
    echo " DIR DOES NOT EXIST!" >&2
    continue;
  fi

  # Set sticky bit on base dir
  chmod 1750 "$DIR"

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
      IFS=$EOL
      find "$SUBDIR/" ! -uid 0 ! -type l |while read FN; do
        chown -v 0:0 "$FN"
        chmod -v u+rw,g+r-w,o+r-w "$FN"
      done

      MTIME_YEAR="$(echo "$MTIME" |cut -f1 -d'-')"
      MTIME_MONTH="$(echo "$MTIME" |cut -f2 -d'-')"

      KEEP=0
      if [ $DAILY_COUNT -le $DAILY_KEEP ]; then
        DAILY_COUNT=$((DAILY_COUNT + 1))
        # We want to keep this day
        echo "KEEP DAILY: $MTIME"
        KEEP=1
      fi

      if [ $MONTHLY_COUNT -le $MONTHLY_KEEP ] && [ $MTIME_MONTH -ne $MONTH_LAST -o $MTIME_YEAR -ne $YEAR_LAST ]; then
        # We want to keep this month
        MONTHLY_COUNT=$((MONTHLY_COUNT + 1))
        MONTH_LAST=$MTIME_MONTH

        echo "KEEP MONTHLY: $MTIME"
        YEAR_LAST=$MTIME_YEAR
        KEEP=1
      fi

      if [ $YEARLY_COUNT -le $YEARLY_KEEP ] && [ $MTIME_YEAR -ne $YEAR_LAST -o $COUNT -eq $COUNT_TOTAL ]; then
        YEARLY_COUNT=$((YEARLY_COUNT + 1))
        YEAR_LAST=$MTIME_YEAR

        # We want to keep this year
        echo "KEEP YEARLY: $MTIME"
        KEEP=1
      fi

      if [ $KEEP -eq 0 ]; then
        echo "* Removing: $SUBDIR"
        rm -rf "$SUBDIR"
      fi
    fi
  done
done

