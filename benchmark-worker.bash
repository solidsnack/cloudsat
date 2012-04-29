#!/bin/bash
set -o errexit -o nounset -o pipefail

packages=( postgresql-client-9.1 postgresql-contrib-9.1 )
function packages {
  sudo aptitude install -y "${packages[@]}"
}

function pgbench {
  /usr/lib/postgresql/9.1/bin/pgbench -n -c 10 -T 20 \
  'host=pgbench.aws.airbnb.com dbname=cloudsat user=cloudsat password=none'
}

function nway_insert_posts {
  init
  local clients=$(( 10#$1 ))
  local posts=$(( 10#$2 ))
  local s=200
  msg "Striping $clients connections over ${s}s before starting inserts..."
  for n in $(seq 1 $clients)
  do
    ( before=$(bc <<<"scale=2; $s * $RANDOM / 65535")
      after=$(bc <<<"scale=2; $s - $before")
      sleep $before
      { echo "SELECT pg_sleep($after);" ; insert_posts $posts ;} |
      psql_ --quiet 1>/dev/null ) &
  done
  msg 'Waiting for clients...'
  wait
  msg 'All done.'
}

function insert_posts {
  init
  local inserts=$(( 10#$1 ))
  local poster=
  local chan=
  local message=
  printf '%s\n' 'SET search_path TO cloudsat,public;'
  for n in $(seq 1 $inserts)
  do
    poster="${posters[$RANDOM % ${#posters[@]}]}"
    chan="${chans[$RANDOM % ${#chans[@]}]}"
    message="${messages[$RANDOM % ${#messages[@]}]}"
    printf '%s\n' \
      "SELECT post('$poster'::text, '$chan'::text, '$message'::text);"
  done
}

function psql_ {
  psql "$@" --dbname \
  'host=pgbench.aws.airbnb.com dbname=cloudsat user=cloudsat password=none'
}

posters=(
  {harry,amy,raph,dave,jason,spike,topher,bekki}@staff.airbnb.com
  {conf,routing,build,cron}@system.airbnb.com
  {newrelic,akamai,aws,misc}@external.airbnb.com
  {app@,}{i-421f6d25,i-441f6d23,i-461f6d21,i-601f6d07}.inst.aws.airbnb.com
  {db@,}{i-681f6d0f,i-6a1f6d0d,i-6c1f6d0b,i-6e1f6d09}.inst.aws.airbnb.com
)
chans=( "${posters[@]}"
  {app,redis,mysql,gopher}.{production,staging}.monorail.airbnb.com
  {app,redis,mysql,gopher}.{production,staging}.adexploder.airbnb.com
  {app,redis,mysql,gopher}.{production,staging}.aircorps.airbnb.com
  {app,redis,mysql,gopher}.{production,staging}.communities.airbnb.com
)
messages=()
function init_messages {
  for n in {0..1023}
  do
    messages[$n]="$( head -c 512 /dev/urandom | xxd |
                     tr "'"'\\' '.' | tail -c $(( $RANDOM % 512 )) )"
  done
}

init=true
function init {
  $init || return 0
  msg 'Generating random message bodies.'
  init_messages
  msg 'Done generating random message bodies.'
  init=false
}

function out { printf "%s  %s\n" "$(date -u +%FT%TZ)" "$*" ;}
function msg { out "$@" 1>&2 ;}
function err { msg "$@" ; exit 1 ;}


if [[ $# = 0 ]]
then
  packages
  pgbench
else
  "$@" # A little setup is needed for the other commands, anyways.
fi

