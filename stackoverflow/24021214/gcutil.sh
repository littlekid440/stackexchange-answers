#!/bin/bash -eu
#
# Copyright 2014 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
################################################################################
#
# Create a number of instances and automatically repartition them.
#
################################################################################

source "$(dirname $0)/settings.sh" || exit 1

# Returns a fully-qualified URL pointing to the VM image.
#
# Args:
#   $1: project
#   $2: VM image
function vm_image_url() {
  local project="${1}"
  local image="${2}"
  echo "https://www.googleapis.com/compute/v1/projects/${project}/global/images/${image}"
}

# The startup script to run at boot to automatically repartition or grow the
# root partition to fill the available disk space.
declare -r STARTUP_SCRIPT_GROWROOT="growroot.sh"
declare -r STARTUP_SCRIPT_FDISK="fdisk.sh"
STARTUP_SCRIPT="${STARTUP_SCRIPT:-${STARTUP_SCRIPT_FDISK}}"

if [ -z "${IMAGE:-}" ]; then
  declare -r IMAGE_OS="${IMAGE_OS:-centos}"
  case "${IMAGE_OS}" in
    centos)
      declare -r IMAGE="$(vm_image_url 'centos-cloud' 'centos-6-v20140619')"
      ;;
    container-vm)
      declare -r IMAGE="$(vm_image_url 'google-containers' 'container-vm-v20140624')"
      # The fdisk.sh script does not work well on the container-vm image and
      # locks it up after reboot, so we have to use the growroot approach
      # instead.
      STARTUP_SCRIPT="${STARTUP_SCRIPT_GROWROOT}"
      ;;
    debian)
      declare -r IMAGE="$(vm_image_url 'debian-cloud' 'debian-7-wheezy-v20140619')"
      # Note: Debian does not have the growroot package (only available in backports).
      STARTUP_SCRIPT="${STARTUP_SCRIPT_FDISK}"
      ;;
    debian-backports)
      declare -r IMAGE="$(vm_image_url 'debian-cloud' 'backports-debian-7-wheezy-v20140619')"
      ;;
    rhel)
      declare -r IMAGE="$(vm_image_url 'rhel-cloud' 'rhel-6-v20140619')"
      ;;
    suse)
      declare -r IMAGE="$(vm_image_url 'suse-cloud' 'sles-11-sp3-v20140609')"
      ;;
    *)
      echo "Valid IMAGE_OS values: centos, container-vm, debian, debian-backports, rhel, suse." >&2
      exit 1
      ;;
  esac
fi

# Creates an instance name given an instance size.
#
# Args:
#   $1: instance disk size in GB
function instance_name() {
  echo "instance-${1}"
}

# Creates several instances given their disk sizes. Instance names will be
# computed automatically.
#
# Args:
#   $*: instance disk sizes in GB
function create_instances() {
  local pids=""
  for gb in $*; do
    local instance="$(instance_name ${gb})"
    gcutil \
      --service_version="v1" \
      --project="${PROJECT}" \
      addinstance "${instance}" \
      --zone="${ZONE}" \
      --boot_disk_size_gb=${gb} \
      --machine_type="${MACHINE_TYPE}" \
      --network="default" \
      --external_ip_address="ephemeral" \
      --metadata_from_file="startup-script:${STARTUP_SCRIPT}" \
      --service_account_scopes="https://www.googleapis.com/auth/userinfo.email,https://www.googleapis.com/auth/compute,https://www.googleapis.com/auth/devstorage.full_control" \
      --image="${IMAGE}" \
      --persistent_boot_disk="true" \
      --auto_delete_boot_disk="true" &
    pids="${pids} $!"
  done
  wait ${pids}
}

# Deletes instances corresponding to the given disk sizes. Instance names will
# be computed automatically, and will correspond to the ones created by
# `create_instances()`.
#
# Args:
#   $*: instance disk sizes in GB
function delete_instances() {
  local pids=""
  for gb in $*; do
    local instance="$(instance_name ${gb})"
    gcutil \
      --service_version="v1" \
      --project="${PROJECT}" \
      deleteinstance \
      --force \
      --delete_boot_pd \
      --zone="${ZONE}" \
      "${instance}" &
    pids="${pids} $!"
  done
  wait ${pids}
}

# Runs `df` on each instance corresponding to the given disk sizes and shows the
# output. Useful for testing the automatic repartitioning script interactively.
#
# Args:
#   $*: instance disk sizes in GB
function disk_free() {
  for gb in $*; do
    local instance="$(instance_name ${gb})"
    echo "Running df on [${instance}] ..."
    gcutil \
      --service_version="v1" \
      --project="${PROJECT}" \
      --log_level=ERROR \
      ssh \
      --zone="${ZONE}" \
      --ssh_arg=-q \
      "${instance}" \
      df / | grep ' /$' | awk '{ print $2 }'
  done
}

# Runs an interactive `ssh` session (in serial) on every instance corresponding
# to the list of disk sizes provided. This is only useful for a small number of
# instances.
#
# Alternatively, this can be changed to create several separate terminal
# windows, each running its own `ssh` command.
#
# Args:
#   $*: instance disk sizes in GB
function ssh() {
  for gb in $*; do
    local instance="$(instance_name ${gb})"
    echo "Running ssh on [${instance}] ..."
    gcutil \
      --service_version="v1" \
      --project="${PROJECT}" \
      --log_level=ERROR \
      ssh \
      --zone="${ZONE}" \
      --ssh_arg=-q \
      "${instance}"
  done
}

declare -r COMMAND="$1"
shift

case "${COMMAND}" in
  create)
    create_instances $*
    ;;

  delete)
    delete_instances $*
    ;;

  df)
    disk_free $*
    ;;

  ssh)
    ssh $*
    ;;

  *)
    echo "Valid commands: create, delete, df, ssh." >&2
    exit 1
esac
