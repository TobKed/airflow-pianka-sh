#!/usr/bin/env bash

_SHORT_OPTIONS="
h C: L: v
"

_LONG_OPTIONS="
help composer-name: composer-location: verbose
"

APP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
set -euo pipefail

APP_CACHE_DIR="${APP_DIR}/.pianka-cache-dir"

mkdir -pv "${APP_CACHE_DIR}" &> /dev/null

CMDNAME="$(basename -- "$0")"

KUBECONFIG=$(mktemp)
export KUBECONFIG

function add_trap() {
    trap="${1}"
    shift
    for signal in "${@}"
    do
        # adding trap to exiting trap
        local handlers
        handlers="$( trap -p "${signal}" | cut -f2 -d \' )"
        # shellcheck disable=SC2064
        trap "${trap};${handlers}" "${signal}"
    done
}
# shellcheck disable=SC2016
add_trap 'rm -f "${KUBECONFIG}"' EXIT HUP INT TERM

function save_to_file {
    # shellcheck disable=SC2005
    echo "$(eval echo "\$$1")" > "${APP_CACHE_DIR}/.$1"
}

function read_from_file {
    cat "${APP_CACHE_DIR}/.$1" 2>/dev/null || true
}

# Composer global variables
COMPOSER_NAME=$(read_from_file COMPOSER_NAME)
export COMPOSER_NAME=${COMPOSER_NAME:=}

COMPOSER_LOCATION=$(read_from_file COMPOSER_LOCATION)
export COMPOSER_LOCATION=${COMPOSER_LOCATION:=}

export VERBOSE="false"

usage() {
cat << EOF
Usage: ${CMDNAME} [-h] [-C] [-L] [-v] <command>

Help manage Cloud Composer instances

The script is adapted to work properly when added to the PATH variable. This will allow you to use
this script from any location.

Flags:

-h, --help
        Shows this help message.
-C, --composer-name <COMPOSER_NAME>
        Composer instance used to run the operations on. Defaults to ${COMPOSER_NAME}
-L, --composer-location <COMPOSER_LOCATION>
        Composer locations. Defaults to ${COMPOSER_LOCATION}
-v, --verbose
        Add even more verbosity when running the script.


These are supported commands used in various situations:

shell
        Open shell access to Airflow's worker. This allows you to test commands in the context of
        the Airflow instance.

info
        Print basic information about the environment.

run
        Run arbitrary command on the Airflow worker.

        Example:
        If you want to list currnet running process, run:
        ${CMDNAME} run -- ps -aux

        If you want to list DAGs, run:
        ${CMDNAME} run -- airflow list_dags

mysql
        Starts the MySQL console.

        Additional parameters are passed to the mysql client.

        Example:
        If you want to execute "SELECT 123" query, run:
        ${CMDNAME} mysql -- --execute="SELECT 123"

mysqltunnel
        Starts the tunnel to MySQL database.

        This allows you to connect to the database with any tool, including your IDE.
mysqldump
        Dumps database or selected table(s).

        Additional parameters are passed to the mysqldump.

        To dump "connection" table to "connection.sql" file, run:

        ${CMDNAME} mysqldump -- --column-statistics=0  connection > connection.sql

        Reference:
        https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html

help
        Print help
EOF
echo
}

set +e

getopt -T >/dev/null
GETOPT_RETVAL=$?

if [[ ${GETOPT_RETVAL} != 4 ]]; then
    echo
    if [[ $(uname -s) == 'Darwin' ]] ; then
        echo "You are running ${CMDNAME} in OSX environment"
        echo "And you need to install gnu commands"
        echo
        echo "Run 'brew install gnu-getopt coreutils'"
        echo
        echo "Then link the gnu-getopt to become default as suggested by brew by typing:"
        echo "echo 'export PATH=\"/usr/local/opt/gnu-getopt/bin:\$PATH\"' >> ~/.bash_profile"
        echo ". ~/.bash_profile"
        echo
        echo "Login and logout afterwards"
        echo
    else
        echo "You do not have necessary tools in your path (getopt). Please install the"
        echo "Please install latest/GNU version of getopt."
        echo "This can usually be done with 'apt install util-linux'"
    fi
    echo
    exit 1
fi


if ! PARAMS=$(getopt \
    -o "${_SHORT_OPTIONS:=}" \
    -l "${_LONG_OPTIONS:=}" \
    --name "$CMDNAME" -- "$@")
then
    usage
    exit 1
fi


eval set -- "${PARAMS}"
unset PARAMS

# Parse Flags.
while true
do
  case "${1}" in
    -h|--help)
      usage;
      exit 0 ;;
    -C|--composer-name)
      export COMPOSER_NAME="${2}";
      shift 2 ;;
    -L|--composer-location)
      export COMPOSER_LOCATION="${2}";
      shift 2 ;;
    -v|--verbose)
      export VERBOSE="true";
      echo "Verbosity turned on" >&2
      shift ;;
    --)
      shift ;
      break ;;
    *)
      usage
      echo "ERROR: Unknown argument ${1}"
      exit 1
      ;;
  esac
done

if [ -z "$COMPOSER_NAME" ] && [ -z "$COMPOSER_LOCATION" ] ; then
    echo 'The configuration of the environment is unknown.'
    echo 'Execute this program with "--composer-name" and "--composer-location" flags to set the current environment.'
    echo "The values will be saved and subsequent starts will not require configuration."
    exit 1
fi
save_to_file COMPOSER_NAME
save_to_file COMPOSER_LOCATION

# Utils
function log() {
    if [[ ${VERBOSE} == "true" ]]; then
        echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
    fi
}

# Run functions
function run_command_on_composer {
    log "Running \"$*\" command on \"${COMPOSER_GKE_WORKER_NAME}\""
    kubectl exec --namespace="${COMPOSER_GKE_NAMESPACE_NAME}" -t "${COMPOSER_GKE_WORKER_NAME}" --container airflow-worker -- "$@"
}

function run_interactive_command_on_composer {
    log "Running \"$*\" command on \"${COMPOSER_GKE_WORKER_NAME}\""
    kubectl exec --namespace="${COMPOSER_GKE_NAMESPACE_NAME}" -it "${COMPOSER_GKE_WORKER_NAME}" --container airflow-worker -- "$@"
}

# Fetch info functions
function fetch_composer_gke_info {
    log "Fetching information about the GKE cluster"

    COMPOSER_GKE_CLUSTER_NAME=$(gcloud beta composer environments describe "${COMPOSER_NAME}" --location "${COMPOSER_LOCATION}" '--format=value(config.gkeCluster)')

    gcloud container clusters get-credentials "${COMPOSER_GKE_CLUSTER_NAME}" --zone "any" &>/dev/null
    COMPOSER_GKE_NAMESPACE_NAME=$(kubectl get namespaces | grep "composer" | cut -d " " -f 1)
    COMPOSER_GKE_WORKER_NAME=$(kubectl get pods --namespace="${COMPOSER_GKE_NAMESPACE_NAME}" | grep "airflow-worker" | grep "Running" | head -1 | cut -d " " -f 1)

    if [[ ${COMPOSER_GKE_WORKER_NAME} == "" ]]; then
        echo "No running airflow-worker!"
        exit 1
    fi
    log "GKE Cluster Name:     ${COMPOSER_GKE_CLUSTER_NAME}"
    log "GKE Worker Name:      ${COMPOSER_GKE_WORKER_NAME}"
}

function fetch_composer_bucket_info {
    log "Fetching information about the bucket"

    COMPOSER_DAG_BUCKET=$(gcloud beta composer environments describe "${COMPOSER_NAME}" --location "${COMPOSER_LOCATION}" --format='value(config.dagGcsPrefix)')
    COMPOSER_DAG_BUCKET=${COMPOSER_DAG_BUCKET%/dags}
    COMPOSER_DAG_BUCKET=${COMPOSER_DAG_BUCKET#gs://}

    log "DAG Bucket:           ${COMPOSER_DAG_BUCKET}"
}

function fetch_composer_webui_info {
    log "Fetching information about the GCS bucket"

    COMPOSER_WEB_UI_URL=$(gcloud beta composer environments describe "${COMPOSER_NAME}" --location "${COMPOSER_LOCATION}" --format='value(config.airflowUri)')

    log "WEB UI URL:           ${COMPOSER_WEB_UI_URL}"
}

function fetch_composer_mysql_credentials {
    log "Fetching MySQL credentials"

    # shellcheck disable=SC2016
    COMPOSER_MYSQL_URL="$(run_command_on_composer bash -c 'echo $AIRFLOW__CORE__SQL_ALCHEMY_CONN')"
    [[ ${COMPOSER_MYSQL_URL} =~ ([^:]*)://([^@/]*)@?([^/:]*):?([0-9]*)/([^\?]*)\??(.*) ]] && \
      DETECTED_MYSQL_AUTHINFO=${BASH_REMATCH[2]} &&
      COMPOSER_MYSQL_HOST=${BASH_REMATCH[3]} &&
      COMPOSER_MYSQL_DATABASE=${BASH_REMATCH[5]}

    COMPOSER_MYSQL_USER="$(echo "${DETECTED_MYSQL_AUTHINFO}" | cut -d ":" -f 1)"
    COMPOSER_MYSQL_PASSWORD="$(echo "${DETECTED_MYSQL_AUTHINFO}" | cut -d ":" -f 2)"

    log "SQL Alchemy URL: ${COMPOSER_MYSQL_URL}"
    log "  Host:          ${COMPOSER_MYSQL_HOST}"
    log "  User:          ${COMPOSER_MYSQL_USER}"
    log "  Password:      ${COMPOSER_MYSQL_PASSWORD}"
    log "  Database:      ${COMPOSER_MYSQL_DATABASE}"
}


if [[ "$#" -eq 0 ]]; then
    echo "You must provide at least one command."
    usage
    exit 1
fi

CMD=$1
shift

if [[ "${CMD}" == "shell" ]] ; then
    fetch_composer_gke_info
    run_interactive_command_on_composer /bin/bash
    exit 0
elif [[ "${CMD}" == "info" ]] ; then
    fetch_composer_bucket_info
    echo "DAG Bucket:            ${COMPOSER_DAG_BUCKET}"

    fetch_composer_gke_info
    echo "GKE Cluster Name:      ${COMPOSER_GKE_CLUSTER_NAME}"
    echo "GKE Worker Name:       ${COMPOSER_GKE_WORKER_NAME}"

    fetch_composer_webui_info
    echo "WEB UI URL:            ${COMPOSER_WEB_UI_URL}"

    fetch_composer_mysql_credentials
    echo "SQL Alchemy URL: ${COMPOSER_MYSQL_URL}"
    echo "  Host:          ${COMPOSER_MYSQL_HOST}"
    echo "  User:          ${COMPOSER_MYSQL_USER}"
    echo "  Password:      ${COMPOSER_MYSQL_PASSWORD}"
    echo "  Database:      ${COMPOSER_MYSQL_DATABASE}"

    exit 0
elif [[ "${CMD}" == "run" ]] ; then
    fetch_composer_gke_info
    run_command_on_composer "$@"
    exit 0
elif [[ "${CMD}" == "mysql" ]] ; then
    fetch_composer_gke_info
    fetch_composer_mysql_info
    fetch_composer_gke_info
    fetch_composer_mysql_info
    run_interactive_command_on_composer \
      mysql \
      --user="${COMPOSER_MYSQL_USER}" \
      --password="${COMPOSER_MYSQL_PASSWORD}" \
      --host="${COMPOSER_MYSQL_HOST}" \
      "${COMPOSER_MYSQL_DATABASE}" \
        "$@"
    exit 0
elif [[ "${CMD}" == "mysqltunnel" ]] ; then
    fetch_composer_gke_info
    fetch_composer_mysql_credentials
    fetch_composer_gke_info
    echo "To connect, run:"
    echo "mysql \\"
    echo "  --user='${COMPOSER_MYSQL_USER}' \\"
    echo "  --password='${COMPOSER_MYSQL_PASSWORD}' \\"
    echo "  --host=127.0.0.1 \\"
    echo "  --port=3306 \\"
    echo "  '${COMPOSER_MYSQL_DATABASE}'"
    echo ""
    echo "or"
    echo ""
    echo "Configure IDE to use this connection URI:"
    echo "jdbc:mysql://root:${COMPOSER_MYSQL_PASSWORD}@127.0.0.1:3306/${COMPOSER_MYSQL_DATABASE}"
    kubectl port-forward \
      --namespace="default" \
      "deployment/airflow-sqlproxy" \
      3306
    exit 0
elif [[ "${CMD}" == "mysqldump" ]] ; then
    fetch_composer_gke_info
    fetch_composer_mysql_credentials
    fetch_composer_gke_info

    kubectl port-forward \
      --namespace="default" \
      "deployment/airflow-sqlproxy" \
      3306 1>&2 &
    sleep 5;
    TUNNEL_PID=$!
    # shellcheck disable=SC2064,SC2016
    add_trap '$(kill '${TUNNEL_PID}' || true)' EXIT HUP INT TERM
    mysqldump \
      --user="${COMPOSER_MYSQL_USER}" \
      --password="${COMPOSER_MYSQL_PASSWORD}" \
      --host="127.0.0.1" \
      --port=3306 \
      "${COMPOSER_MYSQL_DATABASE}" "$@"
    exit 0
else
    usage
    exit 0
fi
