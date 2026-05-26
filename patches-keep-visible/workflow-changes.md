# Workflow changes

The kernel-build fork (`happyjake/oppo_oplus_realme_sm8850`) needs to:

1. **Copy `patches/keep-visible/` into the fork repo** so the workflow can call them. Easiest: add this folder as a sibling of `.github/workflows/`.
2. **Patch `.github/workflows/fastbuild_6.12.23_gki.yml`** to invoke `01-common-patch.sh`, `02-kernelsu-patch.sh`, `03-ksud-patch.sh` at the right points.

## Where to insert each script

Look at the existing workflow steps (line numbers approximate, from current main):

| Existing step | Action | Where to inject our script |
|---|---|---|
| ReSukiSU setup (line ~300, `bash -s main` against `setup.sh`) | clones ReSukiSU into `kernel_workspace/KernelSU/` | Inject `02-kernelsu-patch.sh` immediately after, run from `kernel_workspace/KernelSU/` |
| susfs apply (line ~357-362, `patch -p1 < 50_add_susfs_in_gki-...patch`) | applies susfs patches to `kernel_workspace/common/` | Inject `01-common-patch.sh` immediately after the `cd ..` that closes the susfs step, run from `kernel_workspace/common/` |
| ksud build (find where `cargo build` for ksud happens) | builds ksud from `kernel_workspace/KernelSU/userspace/ksud/` | Inject `03-ksud-patch.sh` *before* the cargo build, run from `kernel_workspace/KernelSU/userspace/ksud/` |

## Concrete YAML diff

Two new steps to add. Add them right after the existing susfs / ksud steps:

```yaml
      - name: keep-visible — apply ReSukiSU dispatch patch
        if: inputs.susfs_enable && (inputs.ksu_type == 'resukisu')
        run: |
          cd kernel_workspace/KernelSU
          bash "${GITHUB_WORKSPACE}/patches/keep-visible/02-kernelsu-patch.sh"

      - name: keep-visible — apply common kernel patch
        if: inputs.susfs_enable
        run: |
          cd kernel_workspace/common
          bash "${GITHUB_WORKSPACE}/patches/keep-visible/01-common-patch.sh"

      - name: keep-visible — apply ksud CLI patch
        if: inputs.susfs_enable && (inputs.ksu_type == 'resukisu')
        run: |
          cd kernel_workspace/KernelSU/userspace/ksud
          bash "${GITHUB_WORKSPACE}/patches/keep-visible/03-ksud-patch.sh"
```

Place these **after** the existing "susfs setup" step (the one that runs
`patch -p1 < 50_add_susfs_in_gki-…patch`) and **before** the kernel `make`
step. The ksud patch goes anywhere before the artifact-build step that picks
up `ksud` (search for `cargo build` or for the artifact upload that names
`ksud-aarch64-linux-android`).

## Verification post-build

After CI succeeds and the AnyKernel3 zip is downloaded:

```bash
# Confirm the kernel image has our changes (look for the new symbol):
strings <unpacked Image> | grep -E 'CMD_SUSFS_ADD_KEEP_VISIBLE|susfs_add_keep_visible'

# Confirm the ksud binary has the new CLI:
strings <ksud-aarch64-linux-android> | grep -E 'keep-visible|KeepVisible|0x60030'
```

If both grep matches return non-empty, the patches landed.

## Smoke test on device after flash

```bash
adb shell "su -c 'ksud susfs keep-visible --help'"
# Should print: "Mark a mount-point's mount as KEEP_VISIBLE…"

adb shell "su -c 'mount --bind /data/local/Modules/fix-mipay/test.txt /product/app/MITSMClientGlobal/MITSMClientGlobal.apk && \
                  ksud susfs keep-visible add /product/app/MITSMClientGlobal/MITSMClientGlobal.apk && \
                  am force-stop com.miui.home && \
                  sleep 2 && \
                  nsenter -t \$(pidof com.miui.home) -m cat /product/app/MITSMClientGlobal/MITSMClientGlobal.apk'"
# Should print: test contents (not the original PK… EEA stub)
```

If the fresh-fork `com.miui.home` reads the test contents, the patch works
and the FixMiPay module can be re-flashed with confidence.
