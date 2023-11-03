#!/usr/bin/env bash

if [ "$(id -u)" = '0' ]; then
  chown -R gwemix:gwemix /var/lib/gwemix
  exec gosu gwemix docker-entrypoint.sh "$@"
fi

# Set verbosity
shopt -s nocasematch
case ${LOG_LEVEL} in
  error)
    __verbosity="--verbosity 1"
    ;;
  warn)
    __verbosity="--verbosity 2"
    ;;
  info)
    __verbosity="--verbosity 3"
    ;;
  debug)
    __verbosity="--verbosity 4"
    ;;
  trace)
    __verbosity="--verbosity 5"
    ;;
  *)
    echo "LOG_LEVEL ${LOG_LEVEL} not recognized"
    __verbosity=""
    ;;
esac

if [ "${ARCHIVE_NODE}" = "true" ]; then
  echo "Gwemix archive node without pruning"
  __prune="--syncmode=full --gcmode=archive"
elif [ -n "${SNAPSHOT}" ] && [ ! -d "/var/lib/gwemix/geth/" ]; then
# Prep datadir
#  wget -q -O - "${SNAPSHOT}" | tar xvf - -C /var/lib/op-geth
  mkdir -p /var/lib/gwemix/snapshot
  cd /var/lib/gwemix/snapshot
  aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true ${SNAPSHOT}
  filename=`echo ${SNAPSHOT} | awk -F/ '{print $NF}'`
  tar xzvf ${filename} -C /var/lib/gwemix
  rm -f ${filename}
  __prune=""
else
  __prune="--syncmode=snap"
fi

if [ -f /var/lib/gwemix/prune-marker ]; then
  rm -f /var/lib/gwemix/prune-marker
  if [ "${ARCHIVE_NODE}" = "true" ]; then
    echo "Gwemix is an archive node. Not attempting to prune: Aborting."
    exit 1
  fi
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${EXTRAS} snapshot prune-state
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__prune} ${__verbosity} ${EXTRAS}
fi
