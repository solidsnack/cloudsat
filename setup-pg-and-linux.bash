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
    # listen_addresses = '*'
    sed -i -r 's/^(max_connections) += +([0-9]+)([^0-9].*$)?/\1 = 2048\3/' \
        postgresql.conf
    sed -i -r 's|^(host +all +all +) 127.0.0.1/32 ( +md5.*)$|\1 0.0.0.0/0 \2|' \
        pg_hba.conf
  )
  /etc/init.d/postgresql restart
}

function pg_db {
sudo -u postgres psql <<\SQL
CREATE TABLESPACE ram LOCATION '/var/lib/postgresql/9.1/ram';
CREATE ROLE cloudsat PASSWORD 'none' NOSUPERUSER NOCREATEDB NOCREATEROLE LOGIN;
CREATE DATABASE cloudsat OWNER cloudsat ENCODING 'UTF8' TABLESPACE ram;
SQL
}

function ramfs {
  local d=/var/lib/postgresql/9.1/ram
  mkdir "$d"
  chmod 0700 "$d"
  chown postgres:postgres "$d"
  mount -t ramfs ramfs "$d"
}

function all {
  packages
  kernel_params
  ramfs
  pg_configuration
  pg_db
}


if [[ $# = 0 ]]
then
  all
else
  "$@"
fi

