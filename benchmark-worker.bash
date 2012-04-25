#!/bin/bash
set -o errexit -o nounset -o pipefail

packages=( postgresql-client-9.1 postgresql-contrib-9.1 )
function packages {
  sudo aptitude install -y "${packages[@]}"
}

function bench {
  /usr/lib/postgresql/9.1/bin/pgbench -n -c 10 -T 20 \
  'host=pgbench.aws.airbnb.com dbname=cloudsat user=cloudsat password=none'
}

function all {
  packages
  bench
}

if [[ $# = 0 ]]
then
  all
else
  "$@"
fi


