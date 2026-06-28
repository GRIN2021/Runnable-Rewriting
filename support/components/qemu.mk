# QEMU
# ====

define do-clone-qemu
	echo "error: legacy QEMU 2.4.50 is archived at archive/qemu-legacy-2.4.50 and must not be recreated under qemu/" >&2
	echo "error: use an explicit modern QEMU source tree for QEMU V2 experiments" >&2
	exit 1
endef

# $(1): source path
# $(2): build path
# $(3): extra configure flags
define do-configure-qemu-common
	   if test "$${RUNNABLE_ALLOW_LEGACY_QEMU_BUILD:-0}" != "1"; then \
	       echo "error: legacy QEMU 2.4.50 is archived at archive/qemu-legacy-2.4.50" >&2; \
	       echo "error: set RUNNABLE_ALLOW_LEGACY_QEMU_BUILD=1 only for intentional archaeology builds" >&2; \
	       exit 1; \
	   fi
	   mkdir -p "$(2)"
	   cd "$(2)"; \
	export LLVM_CONFIG="$(INSTALL_PATH)/bin/llvm-config"; \
	   "$(1)/configure" \
	       --prefix="$(INSTALL_PATH)" \
	       --target-list=" \
	           x86_64-libtinycode \
	           x86_64-linux-user \
	           " \
	       --disable-werror \
	       --enable-llvm-helpers \
	       --disable-kvm \
	       --without-pixman \
	       --disable-tools \
	       --disable-system \
	       --python=$(shell which python2) \
	       $(3)
endef

define do-configure-qemu-debug
$(call do-configure-qemu-common,$(1),$(2),--enable-debug --extra-cflags="-ggdb -O0")
endef

define do-configure-qemu-release
$(call do-configure-qemu-common,$(1),$(2),--extra-cflags="-ggdb")
endef

$(eval \
  $(call strip-call,component-source, \
    QEMU, \
    qemu, \
    archive/qemu-legacy-2.4.50, \
    archive/qemu-legacy-2.4.50, \
    configure, \
    qemu-debug))

$(eval \
  $(call strip-call,autotools-component-build, \
    qemu, \
    -debug, \
    $(LLVM_INSTALL_TARGET_FILE)))

$(eval \
  $(call strip-call,autotools-component-build, \
    qemu, \
    -release, \
    $(LLVM_INSTALL_TARGET_FILE)))
