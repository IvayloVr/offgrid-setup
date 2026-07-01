# =============================================================================
# OffGrid Platform — Makefile
# Single entry point for all build operations.
#
# Usage:
#   make lean VERSION=0.2.0      # build lean headless variant
#   make full VERSION=1.1.0      # build full GUI variant
#   make package-lean            # zip lean VMDK for distribution
#   make package-full            # zip full VMDK for distribution
#   make clean                   # remove all build outputs
#   make help                    # show this help
# =============================================================================

VERSION    ?= $(shell grep '^VERSION=' lean/bootstrap.sh | cut -d'"' -f2)
FULL_VER   ?= $(shell grep '^VERSION=' full/bootstrap.sh  | cut -d'"' -f2)
LEAN_OUT   := lean/build/output
FULL_OUT   := full/build/output
DIST       := dist

.PHONY: lean full package-lean package-full clean help check-deps

# ── Default target ────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "  OffGrid Platform Build System"
	@echo "  ─────────────────────────────────────────────────────────"
	@echo "  make lean  VERSION=0.2.0    Build lean headless variant"
	@echo "  make full  VERSION=1.1.0    Build full GUI variant"
	@echo "  make package-lean           Zip lean VMDK for distribution"
	@echo "  make package-full           Zip full VMDK for distribution"
	@echo "  make clean                  Remove all build outputs"
	@echo "  make check-deps             Verify build dependencies"
	@echo ""
	@echo "  Current lean version: $(VERSION)"
	@echo "  Current full version: $(FULL_VER)"
	@echo ""

# ── Dependency check ──────────────────────────────────────────────────────────
check-deps:
	@echo "[+] Checking build dependencies..."
	@command -v packer           &>/dev/null && echo "  ✓ packer"           || (echo "  ✗ packer missing"  && exit 1)
	@command -v qemu-system-x86_64 &>/dev/null && echo "  ✓ qemu"           || (echo "  ✗ qemu missing"    && exit 1)
	@command -v qemu-img         &>/dev/null && echo "  ✓ qemu-img"         || (echo "  ✗ qemu-img missing" && exit 1)
	@command -v curl             &>/dev/null && echo "  ✓ curl"             || (echo "  ✗ curl missing"    && exit 1)
	@ls /dev/kvm                 &>/dev/null && echo "  ✓ KVM"              || (echo "  ✗ /dev/kvm missing — enable VT-x in BIOS" && exit 1)
	@echo "[+] All dependencies present"

# ── Lean build ────────────────────────────────────────────────────────────────
lean: check-deps
	@echo "[+] Building OffGrid Lean v$(VERSION)..."
	cd lean/build && chmod +x build.sh && ./build.sh $(VERSION)

# ── Full build ────────────────────────────────────────────────────────────────
full: check-deps
	@echo "[+] Building OffGrid Full v$(FULL_VER)..."
	cd full/build && chmod +x build.sh && ./build.sh $(FULL_VER)

# ── Package lean for distribution ─────────────────────────────────────────────
package-lean:
	@echo "[+] Packaging OffGrid Lean v$(VERSION) for distribution..."
	@mkdir -p $(DIST)
	@VMDK="$(LEAN_OUT)/OffGrid-v$(VERSION).vmdk"; \
	if [[ ! -f "$$VMDK" ]]; then echo "✗ VMDK not found: $$VMDK — run make lean first"; exit 1; fi; \
	cp common/OffGrid.vmx $(DIST)/OffGrid.vmx; \
	sed -i 's/VMDK_FILENAME/OffGrid-v$(VERSION).vmdk/' $(DIST)/OffGrid.vmx; \
	cp $$VMDK $(DIST)/; \
	cp common/README-client.txt $(DIST)/README.txt; \
	cd $(DIST) && zip -9 "OffGrid-v$(VERSION).zip" \
	    "OffGrid-v$(VERSION).vmdk" \
	    "OffGrid.vmx" \
	    "README.txt"
	@echo "[+] Done: $(DIST)/OffGrid-v$(VERSION).zip"

# ── Package full for distribution ─────────────────────────────────────────────
package-full:
	@echo "[+] Packaging OffGrid Full v$(FULL_VER) for distribution..."
	@mkdir -p $(DIST)
	@VMDK="$(FULL_OUT)/OffGrid-Full-v$(FULL_VER).vmdk"; \
	if [[ ! -f "$$VMDK" ]]; then echo "✗ VMDK not found: $$VMDK — run make full first"; exit 1; fi; \
	cp common/OffGrid-Full.vmx $(DIST)/OffGrid-Full.vmx; \
	sed -i 's/VMDK_FILENAME/OffGrid-Full-v$(FULL_VER).vmdk/' $(DIST)/OffGrid-Full.vmx; \
	cp $$VMDK $(DIST)/; \
	cp common/README-client.txt $(DIST)/README.txt; \
	cd $(DIST) && zip -9 "OffGrid-Full-v$(FULL_VER).zip" \
	    "OffGrid-Full-v$(FULL_VER).vmdk" \
	    "OffGrid-Full.vmx" \
	    "README.txt"
	@echo "[+] Done: $(DIST)/OffGrid-Full-v$(FULL_VER).zip"

# ── Clean ─────────────────────────────────────────────────────────────────────
clean:
	@echo "[+] Cleaning build outputs..."
	rm -rf lean/build/output
	rm -rf full/build/output
	rm -rf $(DIST)
	rm -f lean/build/build.auto.pkrvars.hcl
	rm -f full/build/build.auto.pkrvars.hcl
	@echo "[+] Clean complete"
