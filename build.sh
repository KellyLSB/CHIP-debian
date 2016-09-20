#!/bin/bash -x
: ${MIRROR:="http://httpredir.debian.org/debian"}
: ${DIST:="stretch"}
: ${ARCH:="armhf"}
: ${ROOT:="$PWD/$DIST-$ARCH"}
: ${TARBALL:="$ROOT.debs.tgz"}
: ${CACHE:="$PWD/cache"}

# Build Root Config URI
: ${BR_ROOT_URI:="https://raw.githubusercontent.com/NextThingCo/CHIP-buildroot/chip/stable"}
: ${BR_CONFIG:="chip_defconfig"}

# Chroot
MOUNTS=("/dev" "/dev/pts" "/proc" "/sys")

# Root Settings
: ${HOSTNAME:="ntc-chip"}
: ${PASSWORD:="changeme"}

# APT
PACKAGES=(
	"sudo" "locales" "bash" "bash-completion" "bash-builtins" "bash-doc"
	"man-db" "build-essential" "kernel-package" "sunxi-tools" "u-boot-tools"
	"git"
)
# Cuts the value of the environment variable
function envValue() {
	grep -Ei "($(strJoin "|" $@))" | cut -d= -f2- <&0
}


# Read the cached file or run the update command.
function readCacheDoc() {
	if [ -f "${CACHE}/$1.cache" ]; then
		cat "${CACHE}/$1.cache"
		return 0
	fi

	if [ -n "$2" ]; then
		bash -rc "$2" 2>/dev/null | saveCacheDoc "$1"
		readCacheDoc "$1"
		return $?
	fi

	return 1
}

# FYI:
# Not handling file deletions correctly
# Might be better to use the HTTP Headers on caching.
# Because I'm a RockStar in any language.
# I just like bash for somethings. I suppose for convienience
# and the amount of shell scripting use.
#
# I suppose I could consider more low level languages though.
# I'm quite partial to GoLang myself... Whatever this is good for now.
function saveCacheDoc() {
	local cachePath="${PWD}/cache"
	mkdir -p "${cachePath}"
	cat - > "${cachePath}/$1.cache"
	echo "${cachePath}/$1.cache"
	trap "rm ${cachePath}/$1.cache" SIGTERM SIGQUIT SIGKILL EXIT
}

function strJoin() {
	local _ifs=$IFS
	IFS="$1"
	echo "${*:2:${#}}"
	IFS=${_ifs}
}

function packagesCSV() {
	strJoin "," "${PACKAGES[*]}"
}

function debian_arch() {
	for e in $(dpkg-architecture -A ${ARCH}); do eval "export ${e}"; done
}

function chroot_prep() {
	for m in $MOUNTS; do sudo mount -obind "${m}" "${ROOT}${m}"; done
	cp -f "$(which qemu-${DEB_TARGET_GNU_CPU}-static)" "${ROOT}/bin/"
}

function chroot_dest() {
	rm -f "${ROOT}/bin/qemu-${DEB_TARGET_GNU_CPU}-static"
	for m in $MOUNTS; do sudo umount "${ROOT}${m}"; done
}

function getRootPrep() {
	cat <<-END_SCRIPT
	echo "${HOSTNAME}" > /etc/hostname
	sed -i 's/localhost/${HOSTNAME} localhost/g' /etc/hosts
	chpasswd <<<"root:${PASSWORD}"
	END_SCRIPT
}

function getBRConfig() {
	readCacheDoc "brconfig" "curl -#L ${BR_ROOT_URI}/configs/${BR_CONFIG}" \
		| grep -Ei "($(strJoin "|" $@))"
}

function getBRKernel() {
	local repoURL="$(getBRConfig BR2_LINUX_KERNEL | envValue REPO_URL)"
	local repoBrn="$(getBRConfig BR2_LINUX_KERNEL | envValue REPO_VERSION)"
	local kernCnf="$(getBRConfig BR2_LINUX_KERNEL | envValue CUSTOM_CONFIG_FILE)"
	local kernDts="$(getBRConfig BR2_LINUX_KERNEL | envValue INTREE_DTS_NAME)"

	cat <<-END_SCRIPT
	export DTS_SUPPORT=y
	export INTREE_DTS_NAME="${kernDts}"
	git clone ${repoURL} -b ${repoBrn} --depth 1 /root/linux
	curl -#L ${BR_ROOT_URI}/${kernCnf} > /root/linux/.config
	cd /root/linux && make olddefconfig && make deb-pkg && cd -
 	cd /root && dpkg -i \$(ls *deb | grep -v dbg) && cd -
	END_SCRIPT
}

function debootstrap() {
	local _tarball="" _tarballDown=0 _foreign="" _foreignSet=0 _ret=0

	# If we need to download a tarball
	if [ ! -f "${TARBALL}" ]; then
		_tarball="--download-only --make-tarball=${TARBALL}"
		_tarballDown=1
	else
		_tarball="--unpack-tarball=${TARBALL}"
	fi

	# Setup the cross compiling environment
	if [ "${DEB_HOST_ARCH}" != "${DEB_TARGET_ARCH}" ]; then
		_foreign="--arch=${ARCH} --foreign"
		_foreignSet=1
	fi

	# Execute debootstrap as sudo in our environment
	# May be a security hole, fakeroot may be better for such
	# a script as it will avoid higher priveleges.
	# => Not sure is command prefix will be required as of yet!
	sudo -E debootstrap ${_tarball} ${_foreign} \
		--include="$(packagesCSV)" $@       \
		"${DIST}" "${ROOT}" "${MIRROR}"; _ret=$?

	# Handle the second stage part
	# The Chroot Prep and Dest methods may
	# create some unecessary action but for ease
	# I'm going to allow this for now because I'm having anxiety.
	# I hate being like this. The way that today is setup is pretty
	# much locking me into an environment where I don't feel comfortable
	# doing anything but typing on my computer.
	# @ Starbucks, Sep 14 2016
	if [ ${_foreignSet} -eq 1 && ${_tarballDown} -eq 0 ]; then
			chroot_prep
			sudo -E chroot "${ROOT}" /debootstrap/debootstrap --second-stage
			chroot_dest
	fi

	# If we made a tarball then return 2 that way we may
	# allow the script to choose the next path.
	# => @TODO: Does this status code conflict with debootstrap(8)
	[ ${_tarballDown} -eq 1 ] && return 2 || return ${_ret}
}

# Set the Deb Target Architectures
# => Very Useful for Mapping Architecture Presentations
debian_arch

# Bootstrap the root.
debootstrap
# If we got code 2 back then
# unpack the tar archive.
# Should do the second stage in this part
[ $? -eq 2 ] &&  debootstrap

# Setup the ChRoot
chroot_prep
# Execute the ChRoot
sudo -E chroot "${ROOT}" <<-END_SCRIPT
#!/bin/bash -xil
$(getRootPrep)
$(getBRKernel)
END_SCRIPT
# Destroy the ChRoot
chroot_dest

exit 0
