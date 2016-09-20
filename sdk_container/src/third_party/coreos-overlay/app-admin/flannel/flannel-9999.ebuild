# Copyright (c) 2014 CoreOS, Inc.. All rights reserved.
# Distributed under the terms of the GNU General Public License v2

EAPI=6

if [[ "${PV}" == 9999 ]]; then
	KEYWORDS="~amd64 ~arm64"
else
	KEYWORDS="amd64 arm64"
fi

inherit systemd coreos-go-utils

DESCRIPTION="flannel"
HOMEPAGE="https://github.com/coreos/flannel"
SRC_URI=""

LICENSE="Apache-2.0"
SLOT="0"
IUSE=""

RDEPEND="app-emulation/rkt"
S="$WORKDIR"

src_install() {
	local arch_tag="$(go_arch)"
	sed "s/{{flannel_ver}}/v${PV}-${arch_tag}/" "${FILESDIR}"/flanneld.service >"${T}"/flanneld.service
	systemd_dounit "${T}"/flanneld.service

	insinto /usr/lib/systemd/network
	doins "${FILESDIR}"/50-flannel.network
}
