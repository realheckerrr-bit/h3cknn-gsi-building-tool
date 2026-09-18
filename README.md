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
- **Automated GitHub Actions CI/CD:**
  - One-click build via `workflow_dispatch`.
  - Automatic runner disk cleanup (+35GB free space optimization).
  - Generates `.img.xz` compressed images and publishes directly to GitHub Releases.

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
5. Click **Run workflow**. Once finished, the compressed GSI (`.img.xz`) will be published in the **Releases** tab!

### 3. Compiling a GSI from Source
1. In the **Actions** tab, select **"Build Source-Based Treble GSI"**.
2. Click **Run workflow**:
   - **Android ROM Manifest URL**: `https://github.com/LineageOS/android.git`
   - **Manifest Branch**: `lineage-21.0` (Android 14) or `lineage-20.0` (Android 13)
   - **Variant**: `treble_arm64_bvN` (Vanilla) or `treble_arm64_bgN` (with GApps)
   - **Build Type**: `userdebug`
3. Click **Run workflow**.

### 4. Capture Android build and home screenshots

The **Android Emulator Screenshots** workflow boots a clean Android emulator,
captures the Android build-information screen and home screen, and uploads both
PNG files as an Actions artifact. Run it from the **Actions** tab and download
the `android-emulator-screenshots` artifact.

The standard GitHub-hosted emulator is x86_64, while this project produces
ARM64 GSIs. Therefore this workflow validates the emulator and screenshot
pipeline; it does not claim to boot-flash the ARM64 GSI itself.

---

## ⚡ How to Flash the Resulting GSI

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
