#!/bin/sh

EOL='
'
TAB=$(printf '\t')

# Settings:
DIRS="/mnt/archive/backup/barno/snapshots/0-hlc762KPRxK,dPoNxpcSQ2/ /mnt/archive/backup/barno/snapshots/NizqzNKnjGYq-X1XeFKkXjGq/ /mnt/archive/backup/barno/snapshots/OoORCk6QW2SyfZX-Vj90Ecjl/"

IFS=' '
for DIR in $DIRS; do

  if [ ! -d "$DIR" ]; then
    echo " DIR DOES NOT EXIST!" >&2
    continue;
  fi

  MTIME_SUBDIR_LIST="$(find "$DIR/" -maxdepth 1 -mindepth 1 -type d -print0 |xargs -r0 stat -c "%y${TAB}%n" |sort -r)"

  echo "$DIR: $(echo "$MTIME_SUBDIR_LIST" |head -n1 |cut -f1 -d' ')=$(du -h --max-depth 0 $(echo "$MTIME_SUBDIR_LIST" |head -n1 |cut -f2) |cut -f1) $(echo "$MTIME_SUBDIR_LIST" |tail -n1 |cut -f1 -d' ')=$(du -h --max-depth 0 $(echo "$MTIME_SUBDIR_LIST" |tail -n1 |cut -f2) |cut -f1)"
done

