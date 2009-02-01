#
# Dpkg functional testsuite (kind of)
#
# Copyright © 2008 Guillem Jover <guillem@debian.org>
#

BEROOT := sudo
DPKG := dpkg
DPKG_INSTALL := $(BEROOT) $(DPKG) -i
DPKG_PURGE := $(BEROOT) $(DPKG) -P
DPKG_BUILD_DEB := dpkg-deb -b
DPKG_BUILD_DSC := dpkg-source -b
DPKG_QUERY := dpkg-query

PKG_STATUS := $(DPKG_QUERY) -f '$${Status}' -W

DEB = $(addsuffix .deb,$(TESTS_DEB))
DSC = $(addsuffix .dsc,$(TESTS_DSC))

%.deb: %
	$(DPKG_BUILD_DEB) $< $@

%.dsc: %
	$(DPKG_BUILD_DSC) $<


build: $(DEB) $(DSC)

test: build test-case test-clean

clean:
	$(RM) *.deb
	$(RM) *.dsc
	$(RM) *.tar.gz

.PHONY: build test test-case test-clean clean

