#!/bin/bash

# Copyright (c) 2009 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Script to convert the output of build_image.sh to a usb image.

# Load common constants.  This should be the first executable line.
# The path to common.sh should be relative to your script's location.
. "$(dirname "$0")/common.sh"

get_default_board

# Flags
DEFINE_string board "${DEFAULT_BOARD}" "Board for which the image was built"
DEFINE_string from "" \
  "Directory containing rootfs.image and mbr.image"
DEFINE_string to "" "${DEFAULT_TO_HELP}"
DEFINE_boolean yes ${FLAGS_FALSE} "Answer yes to all prompts" "y"
DEFINE_boolean install_autotest ${FLAGS_FALSE} \
  "Whether to install autotest to the stateful partition."
DEFINE_boolean copy_kernel ${FLAGS_FALSE} \
  "Copy the kernel to the fourth partition."
DEFINE_boolean test_image "${FLAGS_FALSE}" \
  "Uses test image if available, otherwise creates one as rootfs_test.image."
DEFINE_string build_root "/build" \
  "The root location for board sysroots."

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Inside the chroot, so output to usb.img in the same dir as the other
# Script can be run either inside or outside the chroot.
if [ ${INSIDE_CHROOT} -eq 1 ]
then
  SYSROOT="${FLAGS_build_root}/${FLAGS_board}"
else
  SYSROOT="${DEFAULT_CHROOT_DIR}${FLAGS_build_root}/${FLAGS_board}"
fi
AUTOTEST_SRC="${SYSROOT}/usr/local/autotest"

# Die on any errors.
set -e

# No board, no default and no image set then we can't find the image
if [ -z ${FLAGS_from} ] && [ -z ${FLAGS_board} ] ; then 
  setup_board_warning
  exit 1
fi

# We have a board name but no image set.  Use image at default location
if [ -z "${FLAGS_from}" ]; then
  IMAGES_DIR="${DEFAULT_BUILD_ROOT}/images/${FLAGS_board}"
  FLAGS_from="${IMAGES_DIR}/$(ls -t ${IMAGES_DIR} 2>&-| head -1)"
fi

if [ ! -d "${FLAGS_from}" ] ; then
  echo "Cannot find image directory ${FLAGS_from}"
  exit 1
fi

# If to isn't explicitly set
if [ -z "${FLAGS_to}" ]; then
  # Script can be run either inside or outside the chroot.
  if [ ${INSIDE_CHROOT} -eq 1 ]
  then
    # Inside the chroot, so output to usb.img in the same dir as the other
    # images.
    FLAGS_to="${FLAGS_from}/usb.img"
  else
    # Outside the chroot, so output to the default device for a usb key.
    FLAGS_to="/dev/sdb"
  fi
fi

# Convert args to paths.  Need eval to un-quote the string so that shell
# chars like ~ are processed; just doing FOO=`readlink -f ${FOO}` won't work.
FLAGS_from=`eval readlink -f ${FLAGS_from}`
FLAGS_to=`eval readlink -f ${FLAGS_to}`

# Uses this rootfs image as the source image to copy
ROOTFS_IMAGE="${FLAGS_from}/rootfs.image"
PART_SIZE=$(stat -c%s "${ROOTFS_IMAGE}")  # Bytes

# Setup stateful partition variables
STATEFUL_IMG="${FLAGS_from}/stateful_partition.image"
STATEFUL_DIR="${FLAGS_from}/stateful_partition"

# TODO(sosa@chromium.org) - Remove legacy support.
if [ ! -f "${STATEFUL_IMG}" ] ; then
  echo "WARNING!  Stateful partition not found.  Creating clean stateful"
  STATEFUL_LOOP_DEV=$(sudo losetup -f)
  if [ -z "${STATEFUL_LOOP_DEV}" ] ; then
    echo "No free loop device.  Free up a loop device or reboot.  exiting. "
    exit 1
  fi
  set -x
  dd if=/dev/zero of="${STATEFUL_IMG}" bs=1 count=1 \
      seek=$(( (${PART_SIZE} - 1) ))
  set +x
  trap do_cleanup INT TERM EXIT
  sudo losetup "$STATEFUL_LOOP_DEV" "$STATEFUL_IMG"
  sudo mkfs.ext3 "$STATEFUL_LOOP_DEV"
  sudo tune2fs -L "C-STATE" -c 0 -i 0 "$STATEFUL_LOOP_DEV"
  sudo losetup -d "${STATEFUL_LOOP_DEV}"
  trap - INT TERM EXIT
fi

# Modifies image for test if requested
if [ ${FLAGS_test_image} -eq ${FLAGS_TRUE} ] ; then
  if [ ! -f "${FLAGS_from}/rootfs_test.image" ] ; then
    echo "Test image not found, creating test image from original ... "
    cp "${FLAGS_from}/rootfs.image" "${FLAGS_from}/rootfs_test.image"
    "${SCRIPTS_DIR}/mod_image_for_test.sh" \
      --image "${FLAGS_from}/rootfs_test.image"
  fi
  # Use the test image instead
  ROOTFS_IMAGE="${FLAGS_from}/rootfs_test.image"
fi

function do_cleanup {
  echo "Cleaning loopback devices: ${STATEFUL_LOOP_DEV}"
  if [ "${STATEFUL_LOOP_DEV}" != "" ]; then
    sudo umount "${STATEFUL_DIR}"
    sudo losetup -d "${STATEFUL_LOOP_DEV}"
    echo "Cleaned"
  fi
}

function install_autotest {
  echo "Detecting autotest at ${AUTOTEST_SRC}"
  if [ -d ${AUTOTEST_SRC} ]
  then
    local stateful_loop_dev=$(sudo losetup -f)
    if [ -z "${stateful_loop_dev}" ]
    then
      echo "No free loop device. Free up a loop device or reboot. exiting."
      exit 1
    fi
    trap do_cleanup INT TERM EXIT
    STATEFUL_LOOP_DEV=$stateful_loop_dev
    echo "Mounting ${STATEFUL_DIR} loopback"
    sudo losetup "${stateful_loop_dev}" "${STATEFUL_DIR}.image"
    sudo mount "${stateful_loop_dev}" "${STATEFUL_DIR}"

    echo -ne "Install autotest into stateful partition..."
    local autotest_client="/home/autotest-client"
    sudo mkdir -p "${STATEFUL_DIR}${autotest_client}"
    sudo cp -fpru ${AUTOTEST_SRC}/client/* \
        "${STATEFUL_DIR}${autotest_client}"
    sudo chmod 755 "${STATEFUL_DIR}${autotest_client}"
    sudo chown -R 1000:1000 "${STATEFUL_DIR}${autotest_client}"

    sudo umount ${STATEFUL_DIR}
    sudo losetup -d "${stateful_loop_dev}"
    trap - INT TERM EXIT
  else
    echo "/usr/local/autotest under ${DEFAULT_CHROOT_DIR} is not installed."
    echo "Please call make_autotest.sh inside chroot first."
    exit -1
  fi
}

# Copy MBR and rootfs to output image
if [ -b "${FLAGS_to}" ]
then
  # Output to a block device (i.e., a real USB key), so need sudo dd
  echo "Copying USB image ${FLAGS_from} to device ${FLAGS_to}..."

  # Warn if it looks like they supplied a partition as the destination.
  if echo ${FLAGS_to} | grep -q '[0-9]$'; then
    local drive=$(echo ${FLAGS_to} | sed -re 's/[0-9]+$//')
    if [ -b "${drive}" ]; then
      echo
      echo "NOTE: It looks like you may have supplied a partition as the "
      echo "destination.  This script needs to write to the drive's device "
      echo "node instead (i.e. ${drive} rather than ${FLAGS_to})."
      echo
    fi
  fi

  # Make sure this is really what the user wants, before nuking the device
  if [ ${FLAGS_yes} -ne ${FLAGS_TRUE} ]
  then
    echo "This will erase all data on this device:"
    sudo fdisk -l "${FLAGS_to}" | grep Disk | head -1
    read -p "Are you sure (y/N)? " SURE
    SURE="${SURE:0:1}" # Get just the first character
    if [ "${SURE}" != "y" ]
    then
      echo "Ok, better safe than sorry."
      exit 1
    fi
  fi

  echo "attempting to unmount any mounts on the USB device"
  for i in "${FLAGS_to}"*
  do
    ! sudo umount "$i"
  done
  sleep 3

  if [ ${FLAGS_install_autotest} -eq ${FLAGS_TRUE} ] ; then
    install_autotest
  fi

  # Write stateful partition to first partition. 
  echo "Copying stateful partition ..."
  sudo "${SCRIPTS_DIR}"/file_copy.py \
      if="${STATEFUL_IMG}" of="${FLAGS_to}" bs=4M \
      seek_bytes=512

  # Write root fs to third partition.
  echo "Copying root fs partition ..."
  sudo "${SCRIPTS_DIR}"/file_copy.py \
      if="${ROOTFS_IMAGE}" of="${FLAGS_to}" bs=4M \
      seek_bytes=$(( (${PART_SIZE} * 2) + 512 ))

  trap - EXIT

  if [ ${FLAGS_copy_kernel} -eq ${FLAGS_TRUE} ]
  then
    echo "Copying Kernel..."
    "${SCRIPTS_DIR}"/kernel_fetcher.sh \
      --from "${FLAGS_from}" \
      --to "${FLAGS_to}" \
      --offset "$(( (${PART_SIZE} * 3) + 512 ))"
  fi

  echo "Copying MBR..."
  sudo "${SCRIPTS_DIR}"/file_copy.py \
    if="${FLAGS_from}/mbr.image" of="${FLAGS_to}"
  sync
  echo "Done."
else
  # Output to a file, so just cat the source images together

  PART_SIZE=$(stat -c%s "${ROOTFS_IMAGE}")

  if [ ${FLAGS_install_autotest} -eq ${FLAGS_TRUE} ] ; then
    install_autotest
  fi

  # Create a sparse output file
  dd if=/dev/zero of="${FLAGS_to}" bs=1 count=1 \
      seek=$(( (${PART_SIZE} * 2) + 512 - 1))

  echo "Copying USB image to file ${FLAGS_to}..."

  dd if="${FLAGS_from}/mbr.image" of="${FLAGS_to}" conv=notrunc
  dd if="${FLAGS_from}/stateful_partition.image" of="${FLAGS_to}" seek=1 bs=512 \
      conv=notrunc
  cat "${ROOTFS_IMAGE}" >> "${FLAGS_to}"

  echo "Done.  To copy to USB keyfob, outside the chroot, do something like:"
  echo "   sudo dd if=${FLAGS_to} of=/dev/sdb bs=4M"
  echo "where /dev/sdb is the entire keyfob."
  if [ ${INSIDE_CHROOT} -eq 1 ]
  then
    echo "NOTE: Since you are currently inside the chroot, and you'll need to"
    echo "run dd outside the chroot, the path to the USB image will be"
    echo "different (ex: ~/chromeos/trunk/src/build/images/SOME_DIR/usb.img)."
  fi
fi
