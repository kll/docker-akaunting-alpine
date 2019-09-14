#!/bin/bash
source ${AKAUNTING_RUNTIME_DIR}/env-defaults.sh

AKAUNTING_APP_CONFIG=${AKAUNTING_INSTALL_DIR}/.env

# Compares two version strings `a` and `b`
# Returns
#   - negative integer, if `a` is less than `b`
#   - 0, if `a` and `b` are equal
#   - non-negative integer, if `a` is greater than `b`
vercmp() {
  expr '(' "$1" : '\([^.]*\)' ')' '-' '(' "$2" : '\([^.]*\)' ')' '|' \
       '(' "$1.0" : '[^.]*[.]\([^.]*\)' ')' '-' '(' "$2.0" : '[^.]*[.]\([^.]*\)' ')' '|' \
       '(' "$1.0.0" : '[^.]*[.][^.]*[.]\([^.]*\)' ')' '-' '(' "$2.0.0" : '[^.]*[.][^.]*[.]\([^.]*\)' ')' '|' \
       '(' "$1.0.0.0" : '[^.]*[.][^.]*[.][^.]*[.]\([^.]*\)' ')' '-' '(' "$2.0.0.0" : '[^.]*[.][^.]*[.][^.]*[.]\([^.]*\)' ')'
}

# Read YAML file from Bash script
# Credits: https://gist.github.com/pkuczynski/8665367
parse_yaml() {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
      }
   }'
}

php_config_get() {
  local config=${1?config file not specified}
  local key=${2?key not specified}
  exec_as_akaunting sed -n -e "s/^\(${key}=\)\(.*\)\(.*\)$/\2/p" ${config}
}

php_config_set() {
  local config=${1?config file not specified}
  local key=${2?key not specified}
  local value=${3?value not specified}
  local verbosity=${4:-verbose}

  if [[ ${verbosity} == verbose ]]; then
    echo "Setting ${config} parameter: ${key}=${value}"
  fi

  local current=$(php_config_get ${config} ${key})
  if [[ "${current}" != "${value}" ]]; then
    if [[ $(sed -n -e "s/^[;]*[ ]*\(${key}\)=.*/\1/p" ${config}) == ${key} ]]; then
      value="$(echo "${value}" | sed 's|[&]|\\&|g')"
      exec_as_akaunting sed -i "s|^[;]*[ ]*${key}=.*|${key}=${value}|" ${config}
    else
      echo "${key}=${value}" | exec_as_akaunting tee -a ${config} >/dev/null
    fi
  fi
}

## Execute a command as AKAUNTING_USER
exec_as_akaunting() {
  if [[ $(whoami) == ${AKAUNTING_USER} ]]; then
    $@
  else
    sudo -HEu ${AKAUNTING_USER} "$@"
  fi
}

artisan_cli() {
  exec_as_akaunting php artisan "$@"
}

akaunting_finalize_database_parameters() {
  # is a mysql database linked?
  # requires that the mysql container has exposed port 3306.
  if [[ -n ${MYSQL_PORT_3306_TCP_ADDR} ]]; then
    DB_TYPE=${DB_TYPE:-mysql}
    DB_HOST=${DB_HOST:-mysql}
    DB_PORT=${DB_PORT:-$MYSQL_PORT_3306_TCP_PORT}

    # support for linked sameersbn/mysql image
    DB_USER=${DB_USER:-$MYSQL_ENV_DB_USER}
    DB_PASS=${DB_PASS:-$MYSQL_ENV_DB_PASS}
    DB_NAME=${DB_NAME:-$MYSQL_ENV_DB_NAME}

    # support for linked orchardup/mysql and enturylink/mysql image
    # also supports official mysql image
    DB_USER=${DB_USER:-$MYSQL_ENV_MYSQL_USER}
    DB_PASS=${DB_PASS:-$MYSQL_ENV_MYSQL_PASSWORD}
    DB_NAME=${DB_NAME:-$MYSQL_ENV_MYSQL_DATABASE}
  fi

  if [[ -z ${DB_HOST} ]]; then
    echo
    echo "ERROR: "
    echo "  Please configure the database connection."
    echo "  Cannot continue without a database. Aborting..."
    echo
    return 1
  fi

  # use default port number if it is still not set
  case ${DB_TYPE} in
    mysql) DB_PORT=${DB_PORT:-3306} ;;
    *)
      echo
      echo "ERROR: "
      echo "  Please specify the database type in use via the DB_TYPE configuration option."
      echo "  Accepted values are \"mysql\". Aborting..."
      echo
      return 1
      ;;
  esac

  # set default user and database
  DB_USER=${DB_USER:-root}
  DB_NAME=${DB_NAME:-akauntingdb}
}

akaunting_check_database_connection() {
  akaunting_finalize_database_parameters
  case ${DB_TYPE} in
    mysql)
      prog="mysqladmin -h ${DB_HOST} -P ${DB_PORT} -u ${DB_USER} ${DB_PASS:+-p$DB_PASS} status"
      ;;
  esac
  timeout=60
  while ! ${prog} >/dev/null 2>&1
  do
    timeout=$(expr $timeout - 1)
    if [[ $timeout -eq 0 ]]; then
      echo
      echo "Could not connect to database server. Aborting..."
      return 1
    fi
    echo -n "."
    sleep 1
  done
  echo
}

akaunting_configure_database() {
  echo -n "Configuring Akaunting::database"
  akaunting_check_database_connection
  if [[ -f ${AKAUNTING_APP_CONFIG} ]]; then
    php_config_set ${AKAUNTING_APP_CONFIG} DB_CONNECTION ${DB_TYPE}
    php_config_set ${AKAUNTING_APP_CONFIG} DB_HOST ${DB_HOST}
    php_config_set ${AKAUNTING_APP_CONFIG} DB_PORT ${DB_PORT}
    php_config_set ${AKAUNTING_APP_CONFIG} DB_DATABASE ${DB_NAME}
    php_config_set ${AKAUNTING_APP_CONFIG} DB_USERNAME ${DB_USER}
    php_config_set ${AKAUNTING_APP_CONFIG} DB_PASSWORD ${DB_PASS} quiet
  fi
}

akaunting_upgrade() {
  # perform installation on firstrun
  case ${DB_TYPE} in
    mysql)
      QUERY="SELECT count(*) FROM information_schema.tables WHERE table_schema = '${DB_NAME}';"
      COUNT=$(mysql -h ${DB_HOST} -P ${DB_PORT} -u ${DB_USER} ${DB_PASS:+-p$DB_PASS} -ss -e "${QUERY}")
      ;;
  esac

  local update_version=false
  if [[ -z ${COUNT} || ${COUNT} -eq 0 ]]; then
    echo "Setting up Akaunting for firstrun..."
    artisan_cli install \
      --locale "${APP_LOCALE}" \
      --db-host "${DB_HOST}" --db-port "${DB_PORT}" \
      --db-name "${DB_NAME}" --db-username "${DB_USER}" --db-password "${DB_PASS}" \
      --company-name "${AKAUNTING_COMPANY_NAME}" --company-email "${AKAUNTING_COMPANY_EMAIL}" \
      --admin-email "${AKAUNTING_ADMIN_EMAIL}" --admin-password "${AKAUNTING_ADMIN_PASSWORD}"

    update_version=true
  else
    CACHE_VERSION=
    [[ -f ${AKAUNTING_CONFIG_DIR}/VERSION ]] && CACHE_VERSION=$(cat ${AKAUNTING_CONFIG_DIR}/VERSION)
    if [[ ${AKAUNTING_VERSION} != ${CACHE_VERSION} ]]; then
      ## version check, only upgrades are allowed
      if [[ -n ${CACHE_VERSION} && $(vercmp ${AKAUNTING_VERSION} ${CACHE_VERSION}) -lt 0 ]]; then
        echo
        echo "ERROR: "
        echo "  Cannot downgrade from Akaunting version ${CACHE_VERSION} to ${AKAUNTING_VERSION}."
        echo "  Only upgrades are allowed. Please use sameersbn/akaunting:${CACHE_VERSION} or higher."
        echo "  Cannot continue. Aborting!"
        echo
        return 1
      fi

      echo "Upgrading Akaunting..."
      artisan_cli down
      artisan_cli migrate --force
      artisan_cli up

      update_version=true
    fi
  fi

  echo "Optimizing Akaunting..."
  artisan_cli optimize

  if [[ ${update_version} == true ]]; then
    echo -n "${AKAUNTING_VERSION}" | exec_as_akaunting tee ${AKAUNTING_CONFIG_DIR}/VERSION >/dev/null
  fi
}

akaunting_configure_domain() {
  echo "Configuring Akaunting::URL..."
  php_config_set ${AKAUNTING_APP_CONFIG} APP_URL ${AKAUNTING_URL}
}

backup_dump_database() {
  case ${DB_TYPE} in
    mysql)
      echo "Dumping MySQL database ${DB_NAME}..."
      MYSQL_PWD=${DB_PASS} mysqldump --lock-tables --add-drop-table \
        --host ${DB_HOST} --port ${DB_PORT} \
        --user ${DB_USER} ${DB_NAME} > ${AKAUNTING_BACKUPS_DIR}/database.sql
      ;;
  esac
  chown ${AKAUNTING_USER}: ${AKAUNTING_BACKUPS_DIR}/database.sql
  exec_as_akaunting gzip -f ${AKAUNTING_BACKUPS_DIR}/database.sql
}

backup_dump_directory() {
  local directory=${1}
  local dirname=$(basename ${directory})
  local extension=${2}

  echo "Dumping ${dirname}..."
  exec_as_akaunting tar -cf ${AKAUNTING_BACKUPS_DIR}/${dirname}${extension} -C ${directory} .
}

backup_dump_information() {
  (
    echo "info:"
    echo "  akaunting_version: ${AKAUNTING_VERSION}"
    echo "  database_adapter: $(php_config_get ${AKAUNTING_APP_CONFIG} DB_CONNECTION)"
    echo "  created_at: $(date)"
  ) > ${AKAUNTING_BACKUPS_DIR}/backup_information.yml
  chown ${AKAUNTING_USER}: ${AKAUNTING_BACKUPS_DIR}/backup_information.yml
}

backup_create_archive() {
  local tar_file="$(date +%s)_akaunting_backup.tar"

  echo "Creating backup archive: ${tar_file}..."
  exec_as_akaunting tar -cf ${AKAUNTING_BACKUPS_DIR}/${tar_file} -C ${AKAUNTING_BACKUPS_DIR} $@
  exec_as_akaunting chmod 0755 ${AKAUNTING_BACKUPS_DIR}/${tar_file}

  for f in $@
  do
    exec_as_akaunting rm -rf ${AKAUNTING_BACKUPS_DIR}/${f}
  done
}

backup_purge_expired() {
  if [[ ${AKAUNTING_BACKUPS_EXPIRY} -gt 0 ]]; then
    echo -n "Deleting old backups... "
    local removed=0
    local now=$(date +%s)
    local cutoff=$(expr ${now} - ${AKAUNTING_BACKUPS_EXPIRY})
    for backup in $(ls ${AKAUNTING_BACKUPS_DIR}/*_akaunting_backup.tar)
    do
      local timestamp=$(stat -c %Y ${backup})
      if [[ ${timestamp} -lt ${cutoff} ]]; then
        rm ${backup}
        removed=$(expr ${removed} + 1)
      fi
    done
    echo "(${removed} removed)"
  fi
}

backup_restore_unpack() {
  local backup=${1}
  echo "Unpacking ${backup}..."
  tar xf ${AKAUNTING_BACKUPS_DIR}/${backup} -C ${AKAUNTING_BACKUPS_DIR}
}

backup_restore_validate() {
  eval $(parse_yaml ${AKAUNTING_BACKUPS_DIR}/backup_information.yml backup_)

  ## version check
  if [[ $(vercmp ${AKAUNTING_VERSION} ${backup_info_akaunting_version}) -lt 0 ]]; then
    echo
    echo "ERROR: "
    echo "  Cannot restore backup for version ${backup_info_akaunting_version} on a ${AKAUNTING_VERSION} instance."
    echo "  You can only restore backups generated for versions <= ${AKAUNTING_VERSION}."
    echo "  Please use sameersbn/akaunting:${backup_info_akaunting_version} to restore this backup."
    echo "  Cannot continue. Aborting!"
    echo
    return 1
  fi

  ## database adapter check
  if [[ ${DB_TYPE} != ${backup_info_database_adapter} ]]; then
    echo
    echo "ERROR:"
    echo "  Your current setup uses the ${DB_TYPE} adapter, while the database"
    echo "  backup was generated with the ${backup_info_database_adapter} adapter."
    echo "  Cannot continue. Aborting!"
    echo
    return 1
  fi
  exec_as_akaunting rm -rf ${AKAUNTING_BACKUPS_DIR}/backup_information.yml
}

backup_restore_database() {
  case ${DB_TYPE} in
    mysql)
      echo "Restoring MySQL database..."
      gzip -dc ${AKAUNTING_BACKUPS_DIR}/database.sql.gz | \
        MYSQL_PWD=${DB_PASS} mysql \
          --host ${DB_HOST} --port ${DB_PORT} \
          --user ${DB_USER} ${DB_NAME}
      ;;
    *)
      echo "Database type ${DB_TYPE} not supported."
      return 1
      ;;
  esac
  exec_as_akaunting rm -rf ${AKAUNTING_BACKUPS_DIR}/database.sql.gz
}

backup_restore_directory() {
  local directory=${1}
  local dirname=$(basename ${directory})
  local extension=${2}

  echo "Restoring ${dirname}..."
  files=($(shopt -s nullglob;shopt -s dotglob;echo ${directory}/*))
  if [[ ${#files[@]} -gt 0 ]]; then
    exec_as_akaunting mv ${directory} ${directory}.$(date +%s)
  else
    exec_as_akaunting rm -rf ${directory}
  fi
  exec_as_akaunting mkdir -p ${directory}
  exec_as_akaunting tar -xf ${AKAUNTING_BACKUPS_DIR}/${dirname}${extension} -C ${directory}
  exec_as_akaunting rm -rf ${AKAUNTING_BACKUPS_DIR}/${dirname}${extension}
}

initialize_datadir() {
  echo "Initializing datadir..."
  mkdir -p ${AKAUNTING_DATA_DIR}
  chmod 0755 ${AKAUNTING_DATA_DIR}
  chown ${AKAUNTING_USER}: ${AKAUNTING_DATA_DIR}

  # create uploads directory
  mkdir -p ${AKAUNTING_UPLOADS_DIR}
  chown -R ${AKAUNTING_USER}: ${AKAUNTING_UPLOADS_DIR}
  chmod -R 0750 ${AKAUNTING_UPLOADS_DIR}

  # setup symlink to uploads directory
  rm -rf ${AKAUNTING_INSTALL_DIR}/storage/app/uploads
  ln -sf ${AKAUNTING_UPLOADS_DIR} ${AKAUNTING_INSTALL_DIR}/storage/app/uploads

  # create config directory
  mkdir -p ${AKAUNTING_CONFIG_DIR}
  chown -R ${AKAUNTING_USER}: ${AKAUNTING_CONFIG_DIR}
  chmod -R 0750 ${AKAUNTING_CONFIG_DIR}

  # create backups directory
  mkdir -p ${AKAUNTING_BACKUPS_DIR}
  chmod -R 0755 ${AKAUNTING_BACKUPS_DIR}
  chown -R ${AKAUNTING_USER}: ${AKAUNTING_BACKUPS_DIR}
}

configure_akaunting() {
  # check to see if it needs to be installed or not
  if [[ ! -f "${AKAUNTING_INSTALL_DIR}/index.php" ]]; then
    echo "Installing Akaunting..."
    akaunting-install
  fi

  initialize_datadir
  
  echo "Configuring Akaunting..."
  akaunting_configure_database
  akaunting_upgrade
  akaunting_configure_domain

  if [[ -f ${AKAUNTING_APP_CONFIG} ]]; then
    artisan_cli up
  fi
}

backup_create() {
  echo -n "Checking database connection"
  akaunting_check_database_connection

  artisan_cli down
  backup_dump_database
  backup_dump_directory ${AKAUNTING_CONFIG_DIR} .tar.gz
  backup_dump_directory ${AKAUNTING_UPLOADS_DIR} .tar.gz
  backup_dump_information
  backup_create_archive backup_information.yml database.sql.gz config.tar.gz uploads.tar.gz
  backup_purge_expired
  artisan_cli up
}

backup_restore() {
  local tar_file=
  local interactive=true
  for arg in $@
  do
    if [[ $arg == BACKUP=* ]]; then
      tar_file=${arg##BACKUP=}
      interactive=false
      break
    fi
  done

  # user needs to select the backup to restore
  if [[ $interactive == true ]]; then
    num_backups=$(ls ${AKAUNTING_BACKUPS_DIR}/*_akaunting_backup.tar | wc -l)
    if [[ $num_backups -eq 0 ]]; then
      echo "No backups exist at ${AKAUNTING_BACKUPS_DIR}. Cannot continue."
      return 1
    fi

    echo
    for b in $(ls ${AKAUNTING_BACKUPS_DIR} | grep _akaunting_backup.tar | sort -r)
    do
      echo "‣ $b (created at $(date --date="@${b%%_akaunting_backup.tar}" +'%d %b, %G - %H:%M:%S %Z'))"
    done
    echo

    read -p "Select a backup to restore: " tar_file

    if [[ -z ${tar_file} ]]; then
      echo "Backup not specified. Exiting..."
      return 1
    fi
  fi

  if [[ ! -f ${AKAUNTING_BACKUPS_DIR}/${tar_file} ]]; then
    echo "Specified backup does not exist. Aborting..."
    return 1
  fi

  echo -n "Checking database connection"
  akaunting_check_database_connection

  backup_restore_unpack ${tar_file}
  backup_restore_validate
  backup_restore_database
  backup_restore_directory ${AKAUNTING_CONFIG_DIR} .tar.gz
  backup_restore_directory ${AKAUNTING_UPLOADS_DIR} .tar.gz
}
