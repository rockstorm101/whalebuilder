#!/usr/bin/env bash

set -uo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_name=$(basename "${BASH_SOURCE[0]}")
script_path=$(realpath "${BASH_SOURCE[0]}")

usage() {
    cat <<EOF >&3
Usage: ${script_name} [options] [-- <dpkg-buildpackage options>]

Build '.deb' packages in a container using podman.

Options:
  -d, --deps <dir>     Folder with custom build dependencies
  -h, --help           Print this help and exit
  -i, --image <name>   Image to use to build [default: debian:sid-slim]
  -k, --keep           Keep container after build (default is to remove it)
  -nb, --no-build      Don't build the package (but install dependencies)
  -nd, --no-auto-deps  Don't auto-install build dependencis from control file
  -o, --output <dir>   Folder to place build artifacts
  -q, --quiet          Suppress all output (will still generate a log file)
  -s, --save <name>    Save container as an image after build
  -v, --verbose        Print more verbose output
  -w, --docker         Use docker to run containers (default is podman)
  -- <options>         Options for 'dpgk-buildpackage' [default: -i -I -us -uc]
  --debug              Generate debugging information
  --entry              Build without a container (meant for debugging only)
EOF
    exit
}

cleanup() {
    trap - SIGINT SIGTERM ERR EXIT
    if [[ -n "${tail_pid-}" ]]; then
        sleep 0.5  # allow logging to catch up
        kill "${tail_pid}"
    fi
}

# Logging functions
# shellcheck disable=SC2086
msg() { echo -e "${script_name}: ${1-}" | tee -a ${debug_log-} >&3; }
die() { msg "ERROR: ${1-}"; exit "${2-1}"; }

# Parameter checks
_ck_val() {
    [[ -z "${2-}" ]] && die "Missing value for parameter: $1"
}
_ck_dir() {
    _ck_val "$1" "${2-}"
    [[ -d "$2" ]] || die "Could not find folder '${2}'"
}

_parse_params() {
    # default values for flags and parameters
    dep_dir=''
    image_name='debian:sid-slim'
    build_flag=1
    auto_deps_flag=1
    keep_container=0
    output_dir=''
    verbosity=1
    _cp='cp'
    save_name=''
    _docker='podman'
    dpkg_options=("-i" "-I" "-us" "-uc")
    debug_flag=0
    action='_whale_build'

    while :; do
        case "${1-}" in
            --debug) set -x; debug_flag=1 ;;
            -d | --deps)
                _ck_dir "$1" "${2-}"; dep_dir="$2"; shift ;;
            -h | --help) usage ;;
            -i | --image)
                _ck_val "$1" "${2-}"; image_name="$2"; shift ;;
            -nb | --no-build) build_flag=0 ;;
            -nd | --no-auto-deps) auto_deps_flag=0 ;;
            -k | --keep) keep_container=1 ;;
            -o | --output)
                _ck_dir "$1" "${2-}"; output_dir="$2"; shift ;;
            -q | --quiet) verbosity=0 ;;
            -s | --save)
                _ck_val "$1" "${2-}"; save_name="$2"; shift ;;
            -v | --verbose) verbosity=2; _cp='cp -v' ;;
            -w | --docker) _docker='docker'; shift ;;
            --) shift; dpkg_options=("$@"); break ;;
            --entry) action='_build' ;;  # run as container entry-point
            -?*) die "Unknown option: $1" ;;
            *) break ;;
        esac
        shift
    done

    return 0
}

_whale_build() {
    # Build using a container

    # Check if podman/docker is installed
    [[ -z $(which $_docker) ]] && \
        die "Could not find '${_docker}'. Not installed?"

    # Set up the build command to be used inside the container
    local bcmd=()
    bcmd+=("/${script_name}")
    [[ -n "$dep_dir" ]] && bcmd+=("--deps" "/deps")
    [[ $debug_flag -eq 1 ]] && bcmd+=("--debug")
    [[ $build_flag -eq 0 ]] && bcmd+=("--no-build")
    [[ $auto_deps_flag -eq 0 ]] && bcmd+=("--no-auto-deps")
    bcmd+=("--output" "/output")
    [[ $verbosity -eq 0 ]] && bcmd+=("--quiet")
    [[ $verbosity -eq 2 ]] && bcmd+=("--verbose")
    bcmd+=("--entry")

    # Set up `docker run` command
    local container_name="whale_$$"
    local cmd=()
    cmd+=("${_docker}" "run")
    cmd+=("-v" "${script_path}:/${script_name}:ro")
    cmd+=("-v" "$PWD/..:/source-ro:ro")
    [[ -n "$dep_dir" ]] && cmd+=("-v" "${dep_dir}:/deps")
    cmd+=("-v" "${session_dir}:/output")
    cmd+=("--workdir" "/source-ro/$(basename "$PWD")")
    cmd+=("--name" "${container_name}")
    cmd+=("${image_name}")
    cmd+=("${bcmd[@]}")

    # Run `docker run`
    err_msg="Failure at image run. See logs at ${session_dir}\n"
    err_msg+="Container '${container_name}' retained for inspection."
    msg "Launching container using image '${image_name}'"
    "${cmd[@]}" | tee -a "${debug_log}" >&3 || die "${err_msg}"

    # Save container at current state (like for later use)
    if [[ -n "${save_name}" ]]; then
        msg "Saving container as image '${save_name}'"
        $_docker commit ${container_name} "${save_name}"
    fi

    # Remove container
    if [[ ${keep_container} -eq 0 ]]; then
        err_msg="Failure removing container ${container_name}. "
        err_msg+="See ${debug_log}"
        msg "Removing container"
        $_docker container rm "${container_name}" || die "${err_msg}"
    else
        msg "Container ${container_name} kept."
    fi

    [[ $build_flag -eq 0 ]] && return 0

    # Move build outputs to given folder
    if [[ -n "${output_dir}" ]]; then
        err_msg="Failure copying build artifacts. "
        err_msg+="See ${debug_log}\n"
        err_msg+="Build files remain at '${session_dir}'."
        msg "Copying output files to '${output_dir}'"
        $_cp -af "${session_dir}"/* "${output_dir}"/ || die "${err_msg}"
    else
        msg "Build output stored at '${session_dir}'."
    fi
}

_build() {
    # Build without a container. Intended to be used *inside* the container
    # when this script is used as the container entry-point or for debugging
    # the building process

    # We treat current directory as read-only so we copy everything somewhere
    # else and we will work there. We also copy potential orig tarballs from
    # parent directory
    local ro_work_dir; ro_work_dir="$(pwd)"
    local rw_parent_dir; rw_parent_dir="$(mktemp -d)"
    local rw_work_dir; rw_work_dir="${rw_parent_dir}/$(basename "$(pwd)")"

    msg "Copying source files"
    $_cp -a "${ro_work_dir}" "${rw_work_dir}"
    $_cp ../*orig* "${rw_parent_dir}"/
    cd "${rw_work_dir}" || die "Could not access ${rw_work_dir}"

    # Install the required package(s) to run dpkg-buildpackage
    msg "Installing dpkg-buildpackage"
    apt-get update
    apt-get install -y --no-install-recommends dpkg-dev

    # Guess what build dependencies are required from debian/control file and
    # install them
    if [[ $auto_deps_flag -eq 1 ]]; then
        local control_file="${rw_work_dir}/debian/control"
        [[ -f "$control_file" ]] || \
            die "Could not find {$control_file}"
        msg "Gathering build dependencies from 'debian/control'"

        apt-get install -y --no-install-recommends devscripts equivs
        local auto_dep_dir; auto_dep_dir="$(mktemp -d)"
        cd "${auto_dep_dir}" || die "Could not access ${auto_dep_dir}"
        mk-build-deps --install "${control_file}"
        cd "${rw_work_dir}" || die "Could not access ${rw_work_dir}"
    fi

    # Install any other custom dependencies
    if [[ -n "${dep_dir}" ]]; then
        msg "Installing build dependencies"
        apt-get install -y --no-install-recommends \
                -o Debug::pkgProblemResolver=yes "${dep_dir}"/*.deb
    fi

    # Build the package
    if [[ $build_flag -eq 1 ]]; then
        msg "Building package"
        if dpkg-buildpackage "${dpkg_options[@]}"; then
            msg "Build finished successfully"
        else
            msg "WARNING: Build finished with error $?"
        fi
    fi

    if [[ -n ${output_dir} ]]; then
        # Copy build artifacts to output location
        if [[ $build_flag -eq 1 ]]; then
            msg "Collecting build outputs"
            $_cp -af ../*.deb ../*.buildinfo ../*.changes ../*.dsc \
                 ../*.debian.* "${output_dir}"/
        fi
        # Export container log
        $_cp -f "$debug_log" "${output_dir}/build.log"
    else
        msg "Build artifacts remain at '${rw_parent_dir}'."
    fi
}

exec 3>&1

_parse_params "$@"

# Set up logging
session_dir=$(mktemp --tmpdir -d "${script_name}_XXXXXX")
debug_log="${session_dir}/${script_name}.log"
exec 1>>"$debug_log" 2>>"$debug_log"

if [[ $verbosity -eq 2 ]]; then
    # verbose mode: make output the same as the log file
    exec 4>&3 3>/dev/null
    tail -f "${debug_log}" >&4 &
    tail_pid=$!
elif [[ $verbosity -eq 0 ]]; then
    # silent mode: no output whatsoever
    exec 3>/dev/null
fi

# Action "switch"
${action}
