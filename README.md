# Snck HVM

Snck HVM is the Snck-branded installer project for the HVM panel.

## One-command installer

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SnckBoy/Snck-hvm/main/install.sh)
```

## Dependencies

The installer installs the required virtualization utilities:

```bash
sudo apt install qemu-system cloud-image-utils wget
```

It also installs the supporting tools required by the installer (`curl`, `ca-certificates`, `file`, `iproute2`, `lsof`, `procps`, and `sudo`).

## License

Snck HVM uses a separate Snck license gate. Licenses are validated through:

`https://official.snck.fun/api/v1/license/validate`

The installer expects a JSON response containing:

```json
{"valid":true}
```

Configure another validation endpoint before installation with:

```bash
export SNCK_LICENSE_API="https://official.snck.fun/api/v1/license/validate"
```

## Important

The supplied `hkvm-main.zip` contains only `README.md` and installer shell scripts (`v1.sh`, `v2.sh`, `v3.sh`). It does **not** contain the HVM panel's source code or frontend assets. Therefore this repository currently provides the Snck-branded installation layer and license gate; changing the actual compiled panel's UI/GUI/theme requires the panel source (or an officially redistributable build/source package).

The installer currently uses the executable download URL from the supplied HKVM v2 installer. Replace `SNCK_HVM_DOWNLOAD_URL` with your own Snck build once you have the actual rebranded executable:

```bash
export SNCK_HVM_DOWNLOAD_URL="https://your-domain.example/snck-hvm"
```
