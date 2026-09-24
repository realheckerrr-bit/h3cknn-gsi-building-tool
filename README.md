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
  - Disables AVB, dm-verity, and encryption enforcement loops.
  - Disables OEM-specific proprietary daemons that crash without stock vendor HALs (`knox`, `vaultkeeper`, `miui_daemon`, `faceunlock`).
  - Injects **Treble hardware overlays** (`treble-overlay.apk`) for adaptive brightness, cutouts, and status bar padding.
  - Injects **TrebleApp** (`packages/apps/TrebleApp`) for hardware toggles (VoLTE, fingerprint scanner, high refresh rates).
  - Detects direct community GSI inputs and preserves their original sparse/filesystem layout instead of unpacking and rebuilding them. Set `FORCE_REPACK_GSI=1` only when deliberately converting an OEM system image.
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
│       └── build_source_gsi.yml   # GitHub Actions workflow: Source GSI Builder
├── configs/
│   └── default_props.txt          # Universal Project Treble system properties
├── scripts/
│   ├── clean_disk.sh              # Frees 35GB+ space on GitHub Actions runner
│   ├── extract_rom.sh             # Multi-format unpacker (payload.bin, super, br)
│   ├── patch_treble.sh            # Treble compatibility and overlay patcher
│   ├── port_rom.sh                # Master end-to-end porting runner
│   ├── repack_gsi.sh              # Formatter (ext4/erofs) & sparse converter
│   └── setup_deps.sh              # Installs all required Linux packages & tools
├── source/
│   ├── manifests/
│   │   └── treble_manifest.xml    # Treble manifest (phh/trebledroid)
│   ├── apply_patches.sh           # Patch manager for frameworks/base, etc.
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

With TWRP, extract the `.img.xz` file on the PC, choose **Install → Install
Image**, select the extracted `.img`, choose **System Image**, and wipe data
before the first boot. The exact recovery and vendor firmware must match the
phone model.

For Galaxy M12/A12-family devices, the GSI is only the system partition. A
bootloop can still come from the Samsung vendor, AVB/multidisabler state, the
device-specific recovery, or the kernel. Keep the stock vendor/firmware for
the exact model and use the matching recovery/kernel instructions before
blaming the downloaded image.

DSU is a separate path from TWRP. It needs a working Android installation,
dynamic partitions, an unlocked bootloader, and a device/installer mode that
accepts the GSI signature ([Android DSU requirements](https://developer.android.com/topic/dsu)). DSU Sideloader can provide extra ADB, Shizuku, root,
or system modes, but the builder cannot create Samsung's OEM signing key. If
DSU reports verification or installation failure, use its diagnostic log and
try the TWRP System Image path instead; repacking the GSI will not solve a
signature, vendor, kernel, or AVB failure.

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
