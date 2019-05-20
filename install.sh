#!/bin/bash
set -e

# Parse the command line arguments.
while getopts 'e:h' arg; do
    case "${arg}" in
        e) erase="${OPTARG}" ;;
        h) usage 0 ;;
        *)
           echo "Invalid argument '${arg}'"
           usage 1
           ;;
    esac
done
shift $((OPTIND -1))
target=$1

usage() {
    echo "TODO"
    exit $1
}

confirm() {
    read -p "Are you sure? [Y/n] " answer
    case "$answer" in
        [yY][eE][sS]|[yY])
	    ;;
	*)
	    echo "Quitting..."
	    exit 0
	    ;;
    esac
}

bootstrap() {
    # Confirm the target.
    echo "Bootstrapping $target, this will format the device."

    # Warn users about erase time.
    if [ -n "$erase" ]; then
        echo "Erasing $target with $erase, this can take a while."
    fi

    # Display some information about the target device.
    lsblk $target

    confirm
    echo

    # From this point on we don't ask the user for anything.

    # Remove all mounts of the target device.
    umount $target?* 2>/dev/null || true

    # TODO: Mount a plain crypt and wipe with that.
    if [ -n "$erase" ]; then
        dd if=$erase of=$target status=progress
    fi

    echo $target

    # Format the device.
    # NOTE: Try to get the OS to ignore the old partitions.
    partx -u $target
    fdisk $target << EOF
g
n


+512M
t
1
n



p
w
EOF

    # Setup disk encryption for root partition.
    luks=`cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1`
    cryptsetup luksFormat ${target}2
    cryptsetup luksOpen ${target}2 $luks
    pvcreate /dev/mapper/$luks
    vgcreate vg0 /dev/mapper/$luks
    lvcreate -l +100%FREE vg0 --name root

    # Setup the filesystems.
    mkfs.vfat -F32 ${target}1
    mkfs.ext4 /dev/mapper/vg0-root
}

install() {
    mkdir -p mnt
    mount /dev/mapper/vg0-root mnt
    mkdir -p mnt/boot
    mount ${target}1 mnt/boot

    # TODO: Check for network.
    # TODO: Check host locale settings.

    # Install Arch (requires network connection).
    cat packages.txt | xargs pacstrap mnt base

    # Configure fstab for the new install to correctly mount filesystems on boot.
    genfstab -U mnt >> mnt/etc/fstab

    cp rootfs/etc/mkinitcpio.conf mnt/etc/mkinitcpio.conf

    arch-chroot mnt << EOF
mkinitcpio -p linux
bootctl --no-variables --path=/boot install
chsh -s /usr/bin/fish
EOF

    # Configure the bootloader entry.
    mkdir -p mnt/boot/loader/entries
    cp rootfs/boot/loader/loader.conf mnt/boot/loader/loader.conf
    partuuid=`find -L /dev/disk/by-partuuid -samefile ${target}2 | xargs basename`
    sed -e "s/XXXX/${partuuid}/" rootfs/boot/loader/entries/arch.conf > mnt/boot/loader/entries/arch.conf

    umount mnt/boot
    umount mnt
    rm -r mnt
}

# Check for root user.
if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root."
    exit 1
fi

# Check the arguments.
if [ -z "$target" ]; then
    usage 1
fi

# Do the work!
bootstrap
install

