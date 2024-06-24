# Copyright 1999-2024 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

VERIFY_SIG_OPENPGP_KEY_PATH=/usr/share/openpgp-keys/make.asc
inherit flag-o-matic unpacker verify-sig

DESCRIPTION="Standard tool to compile source trees"
HOMEPAGE="https://www.gnu.org/software/make/make.html"
if [[ ${PV} == 9999 ]] ; then
	EGIT_REPO_URI="https://git.savannah.gnu.org/git/make.git"
	inherit autotools git-r3
elif [[ $(ver_cut 3) -ge 90 || $(ver_cut 4) -ge 90 ]] ; then
	SRC_URI="https://alpha.gnu.org/gnu/make/${P}.tar.lz"
	SRC_URI+=" verify-sig? ( https://alpha.gnu.org/gnu/make/${P}.tar.lz.sig )"
else
	SRC_URI="mirror://gnu/make/${P}.tar.lz"
	SRC_URI+=" verify-sig? ( mirror://gnu/make/${P}.tar.lz.sig )"
	KEYWORDS="~alpha amd64 arm arm64 hppa ~ia64 ~loong ~m68k ~mips ppc ppc64 ~riscv ~s390 sparc x86 ~amd64-linux ~x86-linux ~arm64-macos ~ppc-macos ~x64-macos ~x64-solaris"
fi

LICENSE="GPL-3+"
SLOT="0"
IUSE="doc guile nls static test"
RESTRICT="!test? ( test )"

DEPEND="guile? ( >=dev-scheme/guile-1.8:= )"
RDEPEND="
	${DEPEND}
	nls? ( virtual/libintl )
"
BDEPEND="
	$(unpacker_src_uri_depends)
	doc? ( virtual/texi2dvi )
	nls? ( sys-devel/gettext )
	verify-sig? ( sec-keys/openpgp-keys-make )
	test? ( dev-lang/perl )
"

DOCS="AUTHORS NEWS README*"

PATCHES=(
	"${FILESDIR}"/${PN}-4.4-default-cxx.patch
)

src_unpack() {
	if [[ ${PV} == 9999 ]] ; then
		git-r3_src_unpack

		cd "${S}" || die
		./bootstrap || die
	else
		use verify-sig && verify-sig_verify_detached "${DISTDIR}"/${P}.tar.lz{,.sig}
		unpacker ${P}.tar.lz
	fi
}

src_prepare() {
	default

	if [[ ${PV} == 9999 ]] ; then
		eautoreconf
	fi
}

src_configure() {
	use static && append-ldflags -static
	local myeconfargs=(
		--program-prefix=g
		$(use_with guile)
		$(use_enable nls)
	)
	econf "${myeconfargs[@]}"
}

src_compile() {
	emake all $(usev doc 'pdf html')
}

src_install() {
	use doc && HTML_DOCS=( doc/make.html/. ) DOCS="$DOCS doc/make.pdf"
	default

	dosym gmake /usr/bin/make
	dosym gmake.1 /usr/share/man/man1/make.1
}
