################################################################################
# Following variables defines how the NS_USER (Non Secure User - Client
# Application), NS_KERNEL (Non Secure Kernel), S_KERNEL (Secure Kernel) and
# S_USER (Secure User - TA) are compiled
################################################################################
COMPILE_NS_USER   ?= 64
override COMPILE_NS_KERNEL := 64
COMPILE_S_USER    ?= 64
COMPILE_S_KERNEL  ?= 64

OPTEE_OS_PLATFORM = vexpress-fvp

include common.mk

################################################################################
# Variables used for TPM configuration.
################################################################################
BR2_ROOTFS_OVERLAY = $(ROOT)/build/br-ext/board/fvp/overlay
BR2_PACKAGE_FTPM_OPTEE_EXT_SITE ?= $(CURDIR)/br-ext/package/ftpm_optee_ext
BR2_PACKAGE_FTPM_OPTEE_PACKAGE_SITE ?= $(ROOT)/ms-tpm-20-ref

# The fTPM implementation is based on ARM32 architecture whereas the rest of the
# system is built to run on 64-bit mode (COMPILE_S_USER = 64). Therefore set
# BR2_PACKAGE_FTPM_OPTEE_EXT_SDK manually to the arm32 OPTEE toolkit rather than
# relying on OPTEE_OS_TA_DEV_KIT_DIR variable.
BR2_PACKAGE_FTPM_OPTEE_EXT_SDK ?= $(OPTEE_OS_PATH)/out/arm/export-ta_arm32

BR2_PACKAGE_LINUX_FTPM_MOD_EXT_SITE ?= $(CURDIR)/br-ext/package/linux_ftpm_mod_ext
BR2_PACKAGE_LINUX_FTPM_MOD_EXT_PATH ?= $(LINUX_PATH)

################################################################################
# Paths to git projects and various binaries
################################################################################
MEASURED_BOOT		?= n
TF_A_PATH		?= $(ROOT)/trusted-firmware-a
ifeq ($(MEASURED_BOOT),y)
# Prefer release mode for TF-A if using Measured Boot, debug may exhaust memory.
TF_A_BUILD		?= release
endif
TF_A_DEBUG		?= $(DEBUG)
ifeq ($(TF_A_DEBUG),1)
TF_A_LOGLVL		?= 40
TF_A_BUILD		?= debug
else
TF_A_LOGLVL 		?= 20
TF_A_BUILD		?= release
endif
FVP_PATH		?= $(ROOT)/Base_RevC_AEMvA_pkg/models/Linux64_GCC-9.3
FVP_BIN			?= FVP_Base_RevC-2xAEMvA
FVP_LINUX_DTB		?= $(LINUX_PATH)/arch/arm64/boot/dts/arm/fvp-base-revc.dtb
OUT_PATH		?= $(ROOT)/out
BINARIES_PATH		?= $(ROOT)/out/bin
UBOOT_PATH		?= $(ROOT)/u-boot
UBOOT_BIN		?= $(UBOOT_PATH)/u-boot.bin
MKIMAGE_PATH		?= $(UBOOT_PATH)/tools
UBOOT_BOOT_SCRIPT	?= $(OUT_PATH)/boot.scr
BOOT_IMG		?= $(OUT_PATH)/boot-fat.uefi.img
FTPM_PATH		?= $(ROOT)/ms-tpm-20-ref/Samples/ARM32-FirmwareTPM/optee_ta

# Option to configure FF-A and SPM:
# n:	disabled
# 3:	not supported, SPMC and SPMD at EL3 (in TF-A)
# 2:	not supported, SPMC at S-EL2 (in Hafnium), SPMD at EL3 (in TF-A)
# 1:	SPMC at S-EL1 (in OP-TEE), SPMD at EL3 (in TF-A)
SPMC_AT_EL ?= n
ifneq ($(filter-out n 1,$(SPMC_AT_EL)),)
$(error Unsupported SPMC_AT_EL value $(SPMC_AT_EL))
endif

ifeq ($(MEASURED_BOOT),y)
# By default enable FTPM for backwards compatibility.
MEASURED_BOOT_FTPM ?= y
else
$(call force,MEASURED_BOOT_FTPM,n,requires MEASURED_BOOT enabled)
endif

# Build ancillary components to access fTPM if Measured Boot is enabled.
ifeq ($(MEASURED_BOOT_FTPM),y)
DEFCONFIG_FTPM ?= --br-defconfig build/br-ext/configs/ftpm_optee
DEFCONFIG_TPM_MODULE ?= --br-defconfig build/br-ext/configs/linux_ftpm
DEFCONFIG_TSS ?= --br-defconfig build/br-ext/configs/tss
endif

################################################################################
# Targets
################################################################################
all: arm-tf optee-os ftpm boot-img linux u-boot
clean: arm-tf-clean boot-img-clean buildroot-clean ftpm-clean optee-os-clean u-boot-clean

include toolchain.mk

################################################################################
# Folders
################################################################################
$(OUT_PATH):
	mkdir -p $@

################################################################################
# Shared folder
################################################################################
# Enable accessing the host directory FVP_VIRTFS_HOST_DIR from the FVP.
# The shared folder can be mounted in the following ways:
#  - Run 'mount -t 9p -o trans=virtio,version=9p2000.L FM <mount point>' or,
#  - enable FVP_VIRTFS_AUTOMOUNT.
# The latter will use the Buildroot post-build script to add an entry to the
# target's /etc/fstab, mounting the shared directory to FVP_VIRTFS_MOUNTPOINT
# on the FVP.
# Note: the post-build script can only append to fstab. If FVP_VIRTFS_AUTOMOUNT
# is changed from "y" to "n", run 'rm -r ../out-br/build/skeleton-init-sysv' so
# the target's fstab will be replaced with the unmodified original again.
FVP_VIRTFS_ENABLE	?= n
FVP_VIRTFS_HOST_DIR	?= $(ROOT)
FVP_VIRTFS_AUTOMOUNT	?= n
FVP_VIRTFS_MOUNTPOINT	?= /mnt/host

ifeq ($(FVP_VIRTFS_AUTOMOUNT),y)
$(call force,FVP_VIRTFS_ENABLE,y,required by FVP_VIRTFS_AUTOMOUNT)
endif

BR2_ROOTFS_POST_BUILD_SCRIPT = $(ROOT)/build/br-ext/board/fvp/post-build.sh
BR2_ROOTFS_POST_SCRIPT_ARGS = "$(FVP_VIRTFS_AUTOMOUNT) $(FVP_VIRTFS_MOUNTPOINT)"

################################################################################
# ARM Trusted Firmware
################################################################################
TF_A_EXPORTS ?= \
	CROSS_COMPILE="$(CCACHE)$(AARCH64_CROSS_COMPILE)"

TF_A_FLAGS ?= \
	BL33=$(UBOOT_BIN) \
	FVP_USE_GIC_DRIVER=FVP_GICV3 \
	PLAT=fvp \
	DEBUG=$(TF_A_DEBUG) \
	LOG_LEVEL=$(TF_A_LOGLVL)

ifneq ($(MEASURED_BOOT),y)
	TF_A_FLAGS += MEASURED_BOOT=0
else
	TF_A_FLAGS += MBEDTLS_DIR=$(ROOT)/mbedtls  \
		      ARM_ROTPK_LOCATION=devel_rsa \
		      GENERATE_COT=1 \
		      MEASURED_BOOT=1 \
		      ROT_KEY=plat/arm/board/common/rotpk/arm_rotprivk_rsa.pem \
		      TPM_HASH_ALG=sha256 \
		      TRUSTED_BOARD_BOOT=1 \
		      EVENT_LOG_LEVEL=20
endif

TF_A_FLAGS_BL32_OPTEE  = BL32=$(OPTEE_OS_HEADER_V2_BIN)
TF_A_FLAGS_BL32_OPTEE += BL32_EXTRA1=$(OPTEE_OS_PAGER_V2_BIN)
TF_A_FLAGS_BL32_OPTEE += BL32_EXTRA2=$(OPTEE_OS_PAGEABLE_V2_BIN)
TF_A_FLAGS_BL32_OPTEE += ARM_TSP_RAM_LOCATION=tdram

TF_A_FLAGS_SPMC_AT_EL_n  = $(TF_A_FLAGS_BL32_OPTEE) SPD=opteed
TF_A_FLAGS_SPMC_AT_EL_1  = BL32=$(OPTEE_OS_PAGER_V2_BIN) SPD=spmd
TF_A_FLAGS_SPMC_AT_EL_1 += CTX_INCLUDE_EL2_REGS=0 SPMD_SPM_AT_SEL2=0
TF_A_FLAGS_SPMC_AT_EL_1 += ARM_SPMC_MANIFEST_DTS=../build/fvp/spmc_el1_partitions_manifest.dts
TF_A_FLAGS_SPMC_AT_EL_1 += SPMC_OPTEE=1

TF_A_FLAGS += $(TF_A_FLAGS_SPMC_AT_EL_$(SPMC_AT_EL))

arm-tf: optee-os u-boot
	$(TF_A_EXPORTS) $(MAKE) -C $(TF_A_PATH) $(TF_A_FLAGS) all fip

arm-tf-clean:
	$(TF_A_EXPORTS) $(MAKE) -C $(TF_A_PATH) $(TF_A_FLAGS) clean

################################################################################
# Linux kernel
################################################################################
LINUX_DEFCONFIG_COMMON_ARCH := arm64
LINUX_DEFCONFIG_COMMON_FILES ?= \
		$(LINUX_PATH)/arch/arm64/configs/defconfig \
		$(CURDIR)/kconfigs/fvp.conf

.PHONY: linux-ftpm-module
linux-ftpm-module: linux
ifeq ($(MEASURED_BOOT_FTPM),y)
linux-ftpm-module:
	$(MAKE) -C $(LINUX_PATH) $(LINUX_COMMON_FLAGS) M=drivers/char/tpm  \
		modules_install INSTALL_MOD_PATH=$(LINUX_PATH)
endif

linux-defconfig: $(LINUX_PATH)/.config

LINUX_COMMON_FLAGS += ARCH=arm64

linux: linux-common

linux-defconfig-clean: linux-defconfig-clean-common

LINUX_CLEAN_COMMON_FLAGS += ARCH=arm64

linux-clean: linux-clean-common

LINUX_CLEANER_COMMON_FLAGS += ARCH=arm64

linux-cleaner: linux-cleaner-common

################################################################################
# OP-TEE
################################################################################
OPTEE_OS_COMMON_FLAGS += CFG_ARM_GICV3=y
OPTEE_OS_COMMON_FLAGS_SPMC_AT_EL_1 = CFG_CORE_SEL1_SPMC=y

OPTEE_OS_COMMON_FLAGS += $(OPTEE_OS_COMMON_FLAGS_SPMC_AT_EL_$(SPMC_AT_EL))

ifeq ($(MEASURED_BOOT),y)
	OPTEE_OS_COMMON_FLAGS += CFG_DT=y CFG_CORE_TPM_EVENT_LOG=y
endif

optee-os: optee-os-common

optee-os-clean: ftpm-clean optee-os-clean-common

################################################################################
# Buildroot
################################################################################

buildroot: linux-ftpm-module

################################################################################
# U-Boot
################################################################################
UBOOT_DEFCONFIG_FILES := $(ROOT)/build/kconfigs/u-boot_fvp.conf

UBOOT_COMMON_FLAGS ?= CROSS_COMPILE=$(CROSS_COMPILE_NS_KERNEL)

$(UBOOT_PATH)/.config: $(UBOOT_DEFCONFIG_FILES)
	cd $(UBOOT_PATH) && scripts/kconfig/merge_config.sh $(UBOOT_DEFCONFIG_FILES)

.PHONY: u-boot-defconfig
u-boot-defconfig: $(UBOOT_PATH)/.config

.PHONY: u-boot
u-boot: u-boot-defconfig
	$(MAKE) -C $(UBOOT_PATH) $(UBOOT_COMMON_FLAGS)

.PHONY: u-boot-clean
u-boot-clean:
	$(MAKE) -C $(UBOOT_PATH) $(UBOOT_COMMON_FLAGS) distclean

$(UBOOT_BOOT_SCRIPT): $(BUILD_PATH)/fvp/uboot_boot_cmd.txt u-boot | $(OUT_PATH)
	$(MKIMAGE_PATH)/mkimage -A arm64 \
				-O linux \
				-T script \
				-C none \
				-d $(BUILD_PATH)/fvp/uboot_boot_cmd.txt \
				$(UBOOT_BOOT_SCRIPT)

################################################################################
# Boot Image
################################################################################

.PHONY: boot-img
boot-img: buildroot u-boot $(UBOOT_BOOT_SCRIPT)
	rm -f $(BOOT_IMG)
	mformat -i $(BOOT_IMG) -n 64 -h 255 -T 131072 -v "BOOT IMG" -C ::
	mcopy -i $(BOOT_IMG) $(LINUX_PATH)/arch/arm64/boot/Image ::
	mcopy -i $(BOOT_IMG) $(FVP_LINUX_DTB) ::/fvp.dtb
	mcopy -i $(BOOT_IMG) $(ROOT)/out-br/images/rootfs.cpio.gz ::/initrd.img
	mcopy -i $(BOOT_IMG) $(UBOOT_BOOT_SCRIPT) ::

.PHONY: boot-img-clean
boot-img-clean:
	rm -f $(BOOT_IMG)

################################################################################
# Run targets
################################################################################
# This target enforces updating root fs etc
run: all
	$(MAKE) run-only

FVP_ARGS ?= \
	-C bp.ve_sysregs.exit_on_shutdown=1 \
	-C cache_state_modelled=0 \
	-C pctl.startup=0.0.0.0 \
	-C cluster0.NUM_CORES=4 \
	-C cluster1.NUM_CORES=4 \
	-C cluster0.cpu0.enable_crc32=1 \
	-C cluster0.cpu1.enable_crc32=1 \
	-C cluster0.cpu2.enable_crc32=1 \
	-C cluster0.cpu3.enable_crc32=1 \
	-C cluster1.cpu0.enable_crc32=1 \
	-C cluster1.cpu1.enable_crc32=1 \
	-C cluster1.cpu2.enable_crc32=1 \
	-C cluster1.cpu3.enable_crc32=1 \
	-C cluster0.cpu0.semihosting-cwd="$(BINARIES_PATH)" \
	-C cluster0.cpu1.semihosting-cwd="$(BINARIES_PATH)" \
	-C cluster0.cpu2.semihosting-cwd="$(BINARIES_PATH)" \
	-C cluster0.cpu3.semihosting-cwd="$(BINARIES_PATH)" \
	-C cluster1.cpu0.semihosting-cwd="$(BINARIES_PATH)" \
	-C cluster1.cpu1.semihosting-cwd="$(BINARIES_PATH)" \
	-C cluster1.cpu2.semihosting-cwd="$(BINARIES_PATH)" \
	-C cluster1.cpu3.semihosting-cwd="$(BINARIES_PATH)" \
	-C bp.secure_memory=1 \
	-C bp.secureflashloader.fname=$(TF_A_PATH)/build/fvp/$(TF_A_BUILD)/bl1.bin \
	-C bp.flashloader0.fname=$(TF_A_PATH)/build/fvp/$(TF_A_BUILD)/fip.bin \
	-C bp.virtioblockdevice.image_path=$(BOOT_IMG)
ifeq ($(TS_LOGGING_SP),y)
	FVP_ARGS += -C bp.pl011_uart2.out_file=$(TS_LOGGING_SP_LOG)
endif
ifeq ($(FVP_VIRTFS_ENABLE),y)
	FVP_ARGS += -C bp.virtiop9device.root_path=$(FVP_VIRTFS_HOST_DIR)
endif

run-only:
	$(FVP_PATH)/$(FVP_BIN) $(FVP_ARGS) $(FVP_EXTRA_ARGS)
