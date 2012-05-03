#!/bin/bash
set -o errexit -o nounset -o pipefail

packages=( postgresql-client-9.1 postgresql-9.1 postgresql-9.1-pllua
           postgresql-contrib-9.1 )
function packages {
  aptitude install -y "${packages[@]}"
}

function kernel_params {
  echo 5368709120             >/proc/sys/kernel/shmmax  # 5G
  echo $'250\t32000\t32\t512' >/proc/sys/kernel/sem     # Up SEMMNI to 512
}

function pg_configuration {
  ( cd /etc/postgresql/9.1/main/
    sed -i -r "s/^#(listen_addresses) += +'localhost'(.*)$/\1 = '*'\2/
               s/^(max_connections) += +([0-9]+)([^0-9].*$)?/\1 = 2048\3/
              " postgresql.conf
    sed -i -r 's|^(host +all +all +) 127.0.0.1/32 ( +md5.*)$|\1 0.0.0.0/0 \2|
              ' pg_hba.conf
  )
  /etc/init.d/postgresql restart
}

function pg_db {
sudo -u postgres psql <<\SQL
CREATE ROLE cloudsat PASSWORD 'none' NOSUPERUSER NOCREATEDB NOCREATEROLE LOGIN;
CREATE DATABASE cloudsat OWNER cloudsat ENCODING 'UTF8';
ALTER DATABASE cloudsat SET default_transaction_isolation TO serializable;
SQL
}

function total_kB {
  cat /proc/meminfo | sed -rn '/^MemTotal: +([0-9]+) kB/ { s//\1/ ; p }'
}

# Take 5/8 of RAM or RAM minus 8G, whichever is the greater. That's 6G for
# peak transient connection load of 2000 and then 2G for general use.
function reservation {
  local total_kB="$(total_kB)"
  local proportional="$(bc <<<"$total_kB * 5/8")"
  local absolute="$(bc <<<"$total_kB - (8 * 1024 * 1024)")"
  [[ $absolute -gt $proportional ]] && echo "$absolute" ||
                                       echo "$proportional"
}

function ram_for_pg {
  local d=/var/lib/postgresql
  mkdir -p "$d"
  mount -t tmpfs -o size="$(reservation)"k tmpfs "$d"
}

function all {
  ram_for_pg
  packages
  kernel_params
  pg_configuration
  pg_db
}


if [[ $# = 0 ]]
then
  all
else
  "$@"
fi

