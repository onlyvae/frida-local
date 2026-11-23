export TARGET := iphone:clang:latest:15.0
export ARCHS := arm64
export THEOS_PACKAGE_SCHEME := roothide
export CODESIGN := ldid
export FL_VERSION := 17.27.4

include $(THEOS)/makefiles/common.mk

SUBPROJECTS := App Daemon

include $(THEOS_MAKE_PATH)/aggregate.mk

.PHONY: deps
deps:
	./scripts/prepare-frida.sh $(FL_VERSION)


install-app:
	$(MAKE) clean
	$(MAKE)
	$(MAKE) package
	DEB=$$(ls -t packages/dev.fridalocal_*.deb 2>/dev/null | head -1) && \
	scp "$$DEB" iphone:~/ && \
	ssh -t iphone "echo 'alpine'|sudo -S dpkg -r dev.fridalocal || true; sudo dpkg -i ~/$$(basename $$DEB)"