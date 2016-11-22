#!/bin/bash -x
: ${ROOTCMD:="sudo -E"}
: ${MIRROR:="http://httpredir.debian.org/debian"}
: ${DIST:="stretch"}
: ${ARCH:="armhf"}
: ${ROOT:="$PWD/$DIST-$ARCH"}
: ${TARBALL:="$ROOT.debs.tgz"}
: ${CACHE:="$PWD/cache"}
: ${UPDATE_TGZ:=0}

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
	"man-db" "build-essential" "kernel-package" "make" "sunxi-tools" "u-boot-tools"
	"nano" "vim" "wget" "curl" "ca-certificates" "git" "git-buildpackage" "sed" "grep"
)

# Kernel
: ${KERNEL_PATH:="/root/linux"}
: ${KERNEL_MAKE:="make-kpkg --append-to-version chip-debian --initrd --jobs 2 binary-arch kernel_source libc-kheaders"}
: ${KERNEL_DIST:=0}

# Cuts the value of the environment variable
function envValue() {
	grep -Ei "($(strJoin "|" $@))" <&0 | cut -d= -f2- \
		| sed -e 's/^"//' -e 's/"$//'
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
	strJoin "," ${PACKAGES[@]}
}

function getQEMUStatic() {
	which qemu-${DEB_TARGET_GNU_CPU}-static
}

function debian_arch() {
	for e in $(dpkg-architecture -A ${ARCH}); do eval "export ${e}"; done
}


function chroot_prep() {
	for m in $MOUNTS; do sudo mount -obind "${m}" "${ROOT}${m}"; done
	${ROOTCMD} cp -vf "$(getQEMUStatic)" "${ROOT}/$(getQEMUStatic)"
}

function chroot_dest() {
	${ROOTCMD} rm -vf "${ROOT}/bin/$(basename $(getQEMUStatic))"
	for m in $MOUNTS; do sudo umount "${ROOT}${m}"; done
}

function getRootPrep() {
	cat <<-END_SCRIPT
	locale-gen
	echo "${HOSTNAME}" > /etc/hostname
	sed -i 's/localhost/${HOSTNAME} localhost/g' /etc/hosts
	chpasswd <<<"root:${PASSWORD}"
	END_SCRIPT
}

function getBRConfig() {
	readCacheDoc "brconfig" "curl -#L ${BR_ROOT_URI}/configs/${BR_CONFIG}" \
		| grep -Ei "($(strJoin "|" BR2_$@))"
}

function getAptUpgrade() {
	cat <<-END_SCRIPT
	cat <<-END_SOURCES > /etc/apt/sources.list
	deb     http://httpredir.debian.org/debian         stretch         main contrib non-free
	deb-src http://httpredir.debian.org/debian         stretch         main contrib non-free
	deb     http://ftp.us.debian.org/debian            stretch         main contrib non-free
	deb-src http://ftp.us.debian.org/debian            stretch         main contrib non-free
	deb     http://security.debian.org/debian-security stretch/updates main contrib non-free
	deb-src http://security.debian.org/debian-security stretch/updates main contrib non-free
	END_SOURCES

	apt-get update
	apt-get dist-upgrade -fy ${PACKAGES[@]}
	END_SCRIPT
}

function getChrootEnv() {
	cat <<-END_SCRIPT
	export DEBIAN_FRONTEND=noninteractive
	export LANGUAGE=en_US.UTF-8
	export LANG=\${LANGUAGE}
	export LC_ALL=\${LANGUAGE}
	export ARCH=arm

	sed -ri "s/^# (\${LANGUAGE})/\1/" /etc/locale.gen && locale-gen

	for e in \$(dpkg-architecture -a \${ARCH} -A \${ARCH}); do
		eval "export \${e}"
	done
	END_SCRIPT
}

function runChroot() {
	${ROOTCMD} chroot ${ROOT} /usr/bin/env -i bash -xil <<-END_SCRIPT
	$(getChrootEnv)
	$(cat <&0)
	END_SCRIPT
}

function runStage() {
	local stage="stage$1"; shift;
	if [ ! -f "${ROOT}/${stage}" ]; then
		runChroot <&0
		${ROOTCMD} touch "${ROOT}/${stage}"
	fi
}

function clearStage() {
	local stage="stage$1"; shift;
	${ROOTCMD} rm -vf "${ROOT}/${stage}"
}

function getBRKernel() {
	local repoURL="$(getBRConfig LINUX_KERNEL | envValue REPO_URL)"
	local repoRef="$(getBRConfig LINUX_KERNEL | envValue REPO_VERSION)"
	local kernCnf="$(getBRConfig LINUX_KERNEL | envValue CUSTOM_CONFIG_FILE)"
	local kernDts="$(getBRConfig LINUX_KERNEL | envValue INTREE_DTS_NAME)"

	cat <<-END_SCRIPT
	export DTS_SUPPORT=y
	export INTREE_DTS_NAME="${kernDts}"

	# Clone the repository into a local mirror
	if [ ! -d "${KERNEL_PATH}.git" ]; then
		git clone "${repoURL}" -v -j2 -b "${repoRef}" --depth 1 --mirror "${KERNEL_PATH}.git"
	else
		git --git-dir="${KERNEL_PATH}.git" fetch --depth 1 --tags --all
	fi

	# Dist kernel; (aka clean workdir).
	if [ -d "${KERNEL_PATH}" ] && [ ! -d "${KERNEL_PATH}/.git" ]; then
		KERNEL_DIST=1
	fi

	if [ ${KERNEL_DIST} -eq 1 ]; then
		rm -Rvf "${KERNEL_PATH}"
	fi

	# Checkout git repo and build kernel
	if [ -d "${KERNEL_PATH}.git" ] && [ ! -d "${KERNEL_PATH}" ]; then
		git clone "file://${KERNEL_PATH}.git" -v -b "${repoRef}" --depth 1 "${KERNEL_PATH}"
		curl -#L "${BR_ROOT_URI}/${kernCnf}" > "${KERNEL_PATH}/.config"
	fi

	if [ -d "${KERNEL_PATH}" ]; then
		cd "${KERNEL_PATH}"
		env > /makeEnv.dump && rm /make.log
		bash -c "${KERNEL_MAKE}" 2>&1 | tee /make.log
		cd -
	else
		echo "Skipping Kernel Build" 1>&2
	fi

	ls $(dirname ${KERNEL_PATH})/*deb
	END_SCRIPT

	#cat <<-END_SCRIPT
	#cd /root
	#dpkg -i \$(ls *deb | grep -v dbg)
	#END_SCRIPT
}

function getBRUBoot() {
	local repoURL="$(getBRConfig UBOOT | envValue REPO_URL)"
	local repoRef="$(getBRConfig UBOOT | envValue REPO_VERSION)"
	local ubootBrd="$(getBRConfig UBOOT | envValue BOARDNAME)"
	local ubootFmt="$(getBRConfig UBOOT | envValue FORMAT_CUSTOM_NAME)"
	local ubootSPL="$(getBRConfig UBOOT | envValue SPL_NAME)"
	local ubootEnvImgSrc="$(getBRConfig UBOOT | envValue ENVIMAGE_SOURCE)"
	local ubootEnvImgSze="$(getBRConfig UBOOT | envValue ENVIMAGE_SIZE)"

	cat <<-END_SCRIPT
	export BOARDNAME="${ubootBrd}"
	export ENVIMAGE_SOURCE="${ubootEnvImgSrc}"
	export ENVIMAGE_SIZE="${ubootEnvImgSze}"

	END_SCRIPT
}

function debootstrapTarball() {
	if [ "$1" != "unpack" ]; then
		echo -n --download-only --make-tarball=\"${TARBALL}\"
	else
		echo -n --unpack-tarball=\"${TARBALL}\"
	fi
}

function debootstrap() {
	local _foreign="" _foreignSet=0 _ret=0

	# Setup the cross compiling environment
	if [ "${DEB_HOST_ARCH}" != "${DEB_TARGET_ARCH}" ]; then
		_foreign="--arch=${ARCH} --foreign"
		_foreignSet=1
	fi

	# Execute debootstrap as sudo in our environment
	# May be a security hole, fakeroot may be better for such
	# a script as it will avoid higher priveleges.
	# => Not sure is command prefix will be required as of yet!
	if [ ! -f "${TARBALL}" ] || [ ${UPDATE_TGZ} -eq 1 ]; then
		${ROOTCMD} debootstrap ${_foreign} --include="$(packagesCSV)" \
			$(debootstrapTarball) $@ "${DIST}" "${ROOT}" "${MIRROR}"
	fi

	if [ -f "${TARBALL}" ]; then
		${ROOTCMD} debootstrap ${_foreign} --include="$(packagesCSV)" \
			$(debootstrapTarball unpack) $@ "${DIST}" "${ROOT}" "${MIRROR}"
	else
		${ROOTCMD} debootstrap ${_foreign} \
			--include="$(packagesCSV)" $@ \
			"${DIST}" "${ROOT}" "${MIRROR}"
	fi

	# Handle the second stage part
	if [ ${_foreignSet} -eq 1 ]; then
			chroot_prep
			${ROOTCMD} chroot "${ROOT}" /debootstrap/debootstrap --second-stage
			chroot_dest
	fi
}

# Set the Deb Target Architectures
# => Very Useful for Mapping Architecture Presentations
debian_arch

if [ ! -d ${ROOT}/bin ] || [ ${UPDATE_TGZ} -eq 1 ]; then
	# Bootstrap the root.
	debootstrap
fi

# Setup the ChRoot
chroot_prep

runStage 1 <<-END_SCRIPT
$(getRootPrep)
END_SCRIPT

runStage 2 <<-END_SCRIPT
$(getAptUpgrade)
END_SCRIPT

runStage 3 <<-END_SCRIPT
$(getBRKernel)
END_SCRIPT

# Destroy the ChRoot
chroot_dest

exit 0
