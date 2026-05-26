# wsl-fix-filesystem

A simple tool for repairing a broken WSL distro's ext4 filesystem.

## ⚠️ Disclaimer

Running `e2fsck -yfv` carries risks and is not a guaranteed fix:

- It may not repair the filesystem — some corruption is unrecoverable.
- It may make things worse or delete data.

No warranty. Use at your own risk.

## Usage

1. Download `wsl-fix-filesystem.zip` from the [Releases](../../releases) page.
2. Extract it anywhere.
3. From an elevated PowerShell prompt:

   ```powershell
   cd wsl-fix-filesystem
   .\fix-filesystem.ps1 <DistroName>
   ```

## Requirements

- A WSL version that supports `wsl --mount --bare --vhd`.

## Build locally

```bash
arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
docker build -t wsl-fixer-distro ./distro
cid=$(docker create wsl-fixer-distro)
docker export "$cid" | gzip -9 > "fixer-distro-$arch.tar.gz"
docker rm "$cid"
```

Place `fixer-distro-<arch>.tar.gz` next to `fix-filesystem.ps1` and run.
