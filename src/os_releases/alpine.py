import subprocess, io, sys, os, shutil, pathlib, tempfile
from loguru import logger

APK_DEFAULT_REPOS = """
http://dl-cdn.alpinelinux.org/alpine/v{version}/main
# http://dl-cdn.alpinelinux.org/alpine/v{version}/community
"""

SUPPORTED_VERSIONS = [
  "3.19",
]

DEFAULT_PKGS = [
  # Administration
  'doas', 'htop',
    'eudev', # udev dropin replacement
    'openssh', 'openssl', 'rsync',
    'bash', 'fish',
    'git', 'python3', 'bzip2',
    'tar', 'gzip', 'xz', 'zip',
    'grep', 'mawk', 'nano', 'less',
  # Networking
  'wireguard-tools', 'iproute2', 'nftables', 'tinydns', 'chrony',
  'netcat-openbsd', 'tcpdump',  'iperf3', 'nmap', 'bind-tools',
  # HTTP
  'curl', 'ca-certificates', 'lighttpd', 'jq',
  # Block & Filesystems
  'lsblk', 'findmnt', 'lsof',
    'lvm2', 'mdadm', 'cryptsetup', 'parted',
    'e2fsprogs', 'dosfstools', 'xfsprogs', 'btrfs-progs', 'zfs',
    'nvme-cli', 'smartmontools',
]

def is_version_supported(version: str) -> str:
  """Returns a normalized version string if supported, otherwise an empty string for boolean evaluation"""
  _version = version.lower().strip().lstrip('v')
  if _version in SUPPORTED_VERSIONS: return _version
  else: return ""

def init(
  version: str,
  arch: str,
  rootfs: pathlib.Path,
):
  
  ### Initialize Alpine Linux

  (rootfs / 'var').mkdir(parents=False, mode=0o755, exist_ok=True)
  (rootfs / 'var/cache').mkdir(parents=False, mode=0o755, exist_ok=True)
  (rootfs / 'var/cache/apk').mkdir(parents=False, mode=0o755, exist_ok=True)
  (rootfs / 'etc').mkdir(parents=False, mode=0o755, exist_ok=True)
  (rootfs / 'etc/apk').mkdir(parents=False, mode=0o755, exist_ok=True)
  (rootfs / 'etc/apk/repositories').touch(mode=0o644, exist_ok=True)
  (rootfs / 'etc/apk/repositories').write_text(APK_DEFAULT_REPOS.format(version=version), encoding='utf-8')

  fetch_pkgs = [
    'apk-tools', # Includes APK
    'alpine-keys', # Includes Alpine's Signing Keys
  ]
  """TODO

  We need to ensure that the packages we initially fetch are for the
  correct os release version; currently it fetches whatever is the executing
  environment's version.

  """
  with tempfile.TemporaryDirectory() as tmpdir:
    for pkg in fetch_pkgs:
      logger.debug(f"Fetching Package: {pkg}")
      proc = subprocess.run(
        [
          'apk', 'fetch', '-v', '-v',
            '--arch', arch,
            '--output', tmpdir,
            '--no-cache', '--no-interactive',
            pkg,
        ],
        stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
      )
      if proc.returncode != 0: raise RuntimeError('Failed to Fetch APK Tools')

      pkg_apk = list(pathlib.Path(tmpdir).glob(f'{pkg}*.apk'))
      if len(pkg_apk) > 1: raise RuntimeError(f'Expected 1 APK file for `{pkg}`, found {[f.name for f in pkg_apk]}')
      elif len(pkg_apk) < 1: raise RuntimeError(f'No APK files found for `{pkg}`')
      pkg_apk = pkg_apk[0]

      logger.debug(f"Extracting Package: {pkg}")
      proc = subprocess.run(
        [
          'tar', '-zxf', pkg_apk.as_posix(), '-C', rootfs.as_posix(),
        ],
        stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
      )
      if proc.returncode != 0: raise RuntimeError(f'Failed to Extract APK for `{pkg}`')

  ## Remove unused Artifacts from APK Fetch
  (rootfs / '.PKGINFO').unlink()
  (rootfs / '.SIGN.RSA.*').unlink()

  logger.debug("Initializing APK Database in the Root Filesystem")
  proc = subprocess.run(
    [
      'apk', 'add', '-v', '-v',
        '--root', rootfs.as_posix(),
        '--no-cache', '--no-interactive', '--initdb',
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError('Failed to Initialize the APK Database')

  logger.debug("Updating APK Database in the Root Filesystem")
  proc = subprocess.run(
    [
      'apk', 'update', '-v', '-v',
        '--root', rootfs.as_posix(),
        '--no-cache', '--no-interactive',
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError('Failed to Initialize the APK Database')

  logger.debug("Installing Alpine Base")
  proc = subprocess.run(
    [
      'apk', 'add', '-v', '-v',
        '--root', rootfs.as_posix(),
        '--no-cache', '--no-interactive', '--initdb',
        'alpine-base', # https://pkgs.alpinelinux.org/package/v3.19/main/x86_64/alpine-base
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError('Failed to Install Alpine Base')

def install_pkgs(
  pkgs: list[str],
  arch: str,
  rootfs: pathlib.Path,
):
  proc = subprocess.run(
    [
      'apk', 'add',
        '--root', rootfs.as_posix(),
        '--arch', arch,
        '--keys-dir', (rootfs / 'etc/apk/keys').as_posix(),
        '--repositories-file', (rootfs / 'etc/apk/repositories').as_posix(),
        '--no-cache', '--no-scripts', '--no-interactive',
        *pkgs
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError('Failed to install packages')
