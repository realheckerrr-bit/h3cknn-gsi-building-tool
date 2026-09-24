# 🚀 h3cknn GSI Building Tool

A complete, automated cloud-powered **Generic System Image (GSI)** toolkit with full **Project Treble** support.

Designed to run completely on **GitHub Actions** (with free Ubuntu runners and high-bandwidth cloud infrastructure) or locally on Linux/WSL.

---

## 🌟 Key Features

- **2-in-1 Dual Architecture:**
  1. **OEM ROM to GSI Porting Engine (`port_rom.sh`)**: Converts existing stock or OEM firmware (Pixel, HyperOS/MIUI, OneUI, OxygenOS/ColorOS, Motorola, etc.) into universal generic system images.
  2. **AOSP / LineageOS Source Builder (`build_source.sh`)**: Compiles clean GSIs directly from source trees (LineageOS, TrebleDroid, AOSP) with Treble manifests and patchsets.
- **Universal Multi-Format Unpacker:**
  - `payload.bin` (via high-speed `payload-dumper-go`)
  - `super.img` dynamic partitions (via `lpunpack`)
  - `system.new.dat.br` (via `brotli` & `sdat2img`)
  - `erofs` & `ext4` filesystem extraction.
- **Treble Compatibility Layer:**
  - Injects universal `ro.treble.enabled` properties and generic Dalvik heaps.
  - Does not claim to disable AVB, dm-verity, or Samsung encryption: those are controlled by device vbmeta, vendor, boot, and recovery components.
  - Disables OEM-specific proprietary daemons that crash without stock vendor HALs (`knox`, `vaultkeeper`, `miui_daemon`, `faceunlock`).
  - Injects **Treble hardware overlays** (`treble-overlay.apk`) for adaptive brightness, cutouts, and status bar padding.
  - Injects **TrebleApp** (`packages/apps/TrebleApp`) for hardware toggles (VoLTE, fingerprint scanner, high refresh rates).
  - Detects direct community GSI inputs and preserves their original sparse/filesystem layout instead of unpacking and rebuilding them. Set `FORCE_REPACK_GSI=1` only when deliberately converting an OEM system image.
  - The OEM repack path is experimental; it cannot create a complete bootable Samsung ROM without the matching device vendor, boot image/kernel, vbmeta, and recovery setup.
  - Provides an opt-in Samsung stock-super workflow that replaces only `system` while preserving logical partitions from a matching stock super/AP image.
- **Automated GitHub Actions CI/CD:**
  - One-click build via `workflow_dispatch`.
  - Automatic runner disk cleanup (+35GB free space optimization).
  - Generates `.img.xz` images for normal flashing and `.img.gz` images for DSU Sideloader, then publishes both to GitHub Releases.

---

## 📂 Repository Structure

```tree
gsi-builder-tool/
├── .github/
│   └── workflows/
│       ├── port_gsi.yml           # GitHub Actions workflow: OEM ROM to GSI
│       ├── build_source_gsi.yml   # GitHub Actions workflow: Source GSI Builder
│       └── build_samsung_super.yml # Workflow: matching stock-super package
├── configs/
│   └── default_props.txt          # Universal Project Treble system properties
├── scripts/
│   ├── clean_disk.sh              # Frees 35GB+ space on GitHub Actions runner
│   ├── extract_rom.sh             # Multi-format unpacker (payload.bin, super, br)
│   ├── patch_treble.sh            # Treble compatibility and overlay patcher
│   ├── port_rom.sh                # Master end-to-end porting runner
│   ├── repack_gsi.sh              # Formatter (ext4/erofs) & sparse converter
│   ├── build_samsung_super.sh     # Replace system in matching stock super
│   └── setup_deps.sh              # Installs all required Linux packages & tools
├── source/
│   ├── manifests/
│   │   └── treble_manifest.xml    # Treble manifest (phh/trebledroid)
│   ├── build_source.sh            # mka systemimage runner
│   └── sync_and_patch.sh          # Shallow repo sync and patch application
├── tools/
│   └── sdat2img.py                # Sparse dat to raw image converter
└── README.md
```

---

## 🚀 How to Use on GitHub Actions

### 1. Push to your GitHub Repository
Create a new private or public repository on GitHub and push this directory:
```bash
git init
git add .
git commit -m "Initial commit: Treble GSI Builder"
git branch -M main
git remote add origin https://github.com/<your-username>/<your-repo-name>.git
git push -u origin main
```

### 2. Porting an OEM ROM into a GSI
1. Open your repository on GitHub.
2. Go to the **Actions** tab.
3. Select **"Port Treble GSI (OEM to GSI)"** on the left menu.
4. Click **Run workflow**:
   - **Direct ROM Download URL**: Provide a direct download link to the ROM (e.g. fastboot tgz, recovery zip, payload.bin zip).
   - **Output GSI Name**: e.g., `Pixel_14_ARM64_GSI`
   - **OEM Profile**: Select `generic`, `pixel`, `hyperos`, `oneui`, etc.
   - **Output Filesystem**: `ext4` or `erofs`.
5. Click **Run workflow**. Once finished, the compressed GSI (`.img.xz`) and DSU-compatible GZIP image (`.img.gz`) will be published in the **Releases** tab. For DSU Sideloader, select the `.img.gz` file.

### 3. Compiling a GSI from Source
1. In the **Actions** tab, select **"Build Source-Based Treble GSI"**.
2. Click **Run workflow**:
   - **Android ROM Manifest URL**: `https://github.com/LineageOS/android.git`
   - **Manifest Branch**: `lineage-21.0` (Android 14) or `lineage-20.0` (Android 13)
   - **Variant**: `treble_arm64_bvN` (Vanilla) or `treble_arm64_bgN` (with GApps)
   - **Build Type**: `userdebug`
3. Click **Run workflow**.

### 4. Building a Samsung stock-super package

Use **Build Samsung Super GSI Package** only with the exact stock firmware for
the phone. Provide a direct URL to the matching `AP.tar.md5`, the GSI URL, and
the exact model. An AP archive is required for the Odin output: the workflow
preserves the stock logical partitions, replaces only `system`, converts the
result to Samsung content-size `super.img.lz4`, and carries the matching root,
system, and vendor vbmeta images present in the AP with AVB
hashtree/verification-disabled flags. It never
changes boot, vendor, recovery, or kernel files. The `remove_product` input is
enabled by default for Exynos 850 packages because the stock Samsung `product`
logical partition can conflict with the GSI or consume dynamic-partition space
needed by `system`; set it to `false` only when the exact device guide requires
keeping it. A standalone `super.img` or
`super.img.lz4` input is accepted for inspection/raw output, but it cannot
produce a safe Odin tar without the matching AP vbmeta.

The release contains a `*-odin.tar` only when the AP includes root
`vbmeta.img.lz4`, plus a `*-super-only.tar` for the raw super image. Flash the
Odin tar only on the exact same model and firmware family. Keep the matching
BL/CP/CSC package available; a factory reset and the device-specific
multidisabler/kernel procedure may still be required. For Exynos 850 Android
14+ installations that need a custom kernel, use the workflow's optional
`boot_url` input with an exact-device `boot.img.lz4`; never use a boot image
from another model or firmware binary.

The resulting `.tar` remains device-specific. Follow the matching Samsung
recovery, multidisabler, data-format, and kernel procedure. A package made
from another M12 regional firmware is not safe to flash.

## 📣 Telegram release notifications

After a successful port build, the workflow sends the GSI name, a direct link
to the matching GitHub Release, and the actual build metadata to Telegram. The
metadata is hidden in an expandable section. Add these repository secrets in
**Settings → Secrets and variables → Actions**:

- `TELEGRAM_BOT_TOKEN` — token from [@BotFather](https://t.me/BotFather).
- `TELEGRAM_CHAT_ID` — the destination user, group, or channel chat ID.

If either secret is absent, the workflow skips Telegram without failing the build.


t.me/h3cknnGSI

## ⚡ How to Flash the Resulting GSI

### Samsung Galaxy M12 / Samsung devices

Samsung phones do not use the normal fastboot flashing commands. For DSU
Sideloader, keep the `.img.gz` asset compressed and select it from a working
Android installation. If the phone has no working Android installation, first
restore stock firmware with Odin; Odin cannot flash a raw GSI `.img` file.

For a normal fastboot-style device, extracting `.img.xz` and flashing the
system image is enough. Samsung Exynos 850 phones are different: on many M12
/ A12 variants, a raw system image alone is not a complete Odin package. Use
the exact-model installation procedure with the matching stock AP/vendor,
patched vbmeta or multidisabler, recovery, and kernel. The community Exynos
850 guide documents the required sequence: format data, run `multidisabler`
twice, convert data to the expected filesystem, and flash the matching
Physwizz kernel when using Android 14 or newer.

If your exact TWRP supports direct system-image flashing, extract the
`.img.xz`, choose **Install → Install Image → System Image**, then follow the
device-specific data/multidisabler/kernel steps before the first boot. Do not
flash a raw GSI `.img` directly through Odin; Odin needs the appropriate
Samsung package/container.

For Galaxy M12/A12-family devices, the GSI is only the system partition. A
bootloop can still come from the Samsung vendor, AVB/multidisabler state, the
device-specific recovery, or the kernel. Keep the stock vendor/firmware for
the exact model and use the matching recovery/kernel instructions before
blaming the downloaded image.

On Exynos 850 M12/A12 devices, Android 14+ GSI installations commonly also
need a compatible device kernel (often the Physwizz kernel variant for the
loader/firmware binary) in addition to the system image. The builder cannot
embed that kernel safely because `SM-M127F`, `SM-M127G`, and regional firmware
binary versions are not interchangeable. Also avoid changing PHH Treble
settings during the first boot; some Exynos 850 builds reboot or bootloop
after those settings are changed. See the
[Exynos 850 GSI notes](https://github-wiki-see.page/m/phhusson/treble_experimentations/wiki/Samsung-Galaxy-A12s-%28Exynos-850%29)
and use the kernel/TWRP package matching the exact model and bootloader.

DSU is a separate path from TWRP. It needs a working Android installation,
dynamic partitions, an unlocked bootloader, and a device/installer mode that
accepts the GSI signature ([Android DSU requirements](https://developer.android.com/topic/dsu)). DSU Sideloader can provide extra ADB, Shizuku, root,
or system modes, but the builder cannot create Samsung's OEM signing key. If
DSU reports verification or installation failure, use its diagnostic log and
try the TWRP System Image path instead; repacking the GSI will not solve a
signature, vendor, kernel, or AVB failure.

Standard Android DSU requires a Google/OEM-trusted system signature. This
project cannot manufacture Samsung's signing key, so a community `.img.gz`
may install only through a device/DSU-Sideloader mode that accepts unlocked or
custom images; a failed DSU install is not evidence that the gzip is corrupt.

### Fastboot-based devices

1. Extract the downloaded image:
   ```bash
   unxz <image_name>.img.xz
   ```
2. Reboot your device to fastboot:
   ```bash
   adb reboot bootloader
   ```
3. If your device has dynamic partitions (Android 10+):
   ```bash
   fastboot reboot fastboot
   ```
4. Flash the GSI system image:
   ```bash
   fastboot flash system <image_name>.img
   ```
5. Wipe user data and reboot:
   ```bash
   fastboot -w
   fastboot reboot
   ```
