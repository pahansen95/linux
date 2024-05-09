"""

Common Linux Kernel Operations

See: https://gitlab.alpinelinux.org/alpine/aports/-/blob/3.19-stable/main/linux-lts/APKBUILD?ref_type=heads

"""
from __future__ import annotations
import pathlib, subprocess, sys, os
from loguru import logger

def fetch_src(
  version: str,
  workdir: pathlib.Path,
  dest_dir: pathlib.Path = None,
) -> tuple[pathlib.Path, pathlib.Path]:
  """Fetch the (Upstream) Linux Kernel Source

  The Kernel Source tarball will be downloaded into the workdir & subsequently extracted.

  If dest_dir is provided, the Kernel Source will be extracted into that directory.

  See: https://www.kernel.org/

  Args:
    version (str): The Kernel Version to fetch
    workdir (pathlib.Path): The Working Directory to store the Kernel Source
    dest_dir (pathlib.Path, optional): The Destination Directory to extract the Kernel Source. Defaults to None.

  Returns:
    tuple[
      pathlib.Path: The Path to the extracted Kernel Source
      pathlib.Path: The Path to the Kernel Source tarball
    ]
  """

  if not (workdir.exists() and workdir.is_dir()): raise RuntimeError(f'Workdir `{workdir.as_posix()}` does not exist or is not a Directory')
  if dest_dir and not (dest_dir.exists() and dest_dir.is_dir()): raise RuntimeError(f'Destination Directory `{dest_dir.as_posix()}` does not exist or is not a Directory')

  try:
    kernel_semver: tuple[int, int, int] = tuple(int(v) for v in version.lstrip('v').split('-', maxsplit=1)[0].split('.'))
    if len(kernel_semver) != 3: raise ValueError("Only Simple SemVer is supported: [v]MAJOR.MINOR.PATCH")
  except Exception as e: raise ValueError(f'Invalid Kernel Version: {version}') from e
  kernel_src = workdir / 'linux-{ver}.tar.xz'.format(
    ver='.'.join(str(v) for v in kernel_semver)
  )
  kernel_url = "https://cdn.kernel.org/pub/linux/kernel/v{ver[0]}.x/linux-{ver[0]}.{ver[1]}.{ver[2]}.tar.xz".format(
    ver=kernel_semver,
  )

  if kernel_src.exists(): raise RuntimeError(f"Kernel Source already exists: {kernel_src.as_posix()}")

  logger.debug(f"Fetching Linux Kernel Source: {kernel_url}")
  logger.info("Downloading the Linux Kernel Source")
  proc: subprocess.CompletedProcess = subprocess.run(
    [
      'curl', '-fL', '--progress-bar',
        '-O',
          '--remote-header-name',
          '--output-dir', workdir.as_posix(),
        kernel_url,
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to fetch the Linux Kernel Source: {kernel_url}")
  logger.debug("Folder Contents...\n{contents}".format(
    contents='\n'.join(f"  {f.name}" for f in workdir.iterdir())
  ))

  logger.debug(f"Extracting Linux Kernel Source: {kernel_url}")
  if not kernel_src.exists(): raise RuntimeError(f"Couldn't find the downloaded Kernel Source: {kernel_src.as_posix()}")

  logger.info("Extracting the Linux Kernel Source, verbose output is suppressed so please be patient...")
  proc: subprocess.CompletedProcess = subprocess.run(
    [
      'tar', '-x', '--xz',
        '-f', kernel_src.as_posix(),
        *(
          [
            '--strip-components', '1',
            '-C', dest_dir.as_posix(),
          ] if dest_dir else [
            '-C', workdir.as_posix(),
          ]
        ),
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to extract the Linux Kernel Source: {kernel_src.as_posix()}")

  extract_dir = dest_dir if dest_dir else workdir / f'linux-{".".join(kernel_semver)}'
  if not (extract_dir.exists() and extract_dir.is_dir()): raise RuntimeError(f"Couldn't find the extracted Kernel Source: {extract_dir.as_posix()}")

  return (extract_dir, kernel_src)

def clean(
  kernel_src_dir: pathlib.Path,
):
  """Cleans the Kernel Source Directory for a Fresh Build"""

  if not (kernel_src_dir.exists() and kernel_src_dir.is_dir()): raise RuntimeError(f"Kernel Source Directory does not exist or is not a directory: {kernel_src_dir.as_posix()}")

  logger.debug("Cleaning the Kernel Source Directory")
  proc: subprocess.CompletedProcess = subprocess.run(
    [
      'make', 'mrproper',
    ],
    cwd=kernel_src_dir.as_posix(),
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to clean the Kernel Source Directory")

DEFAULT_BUILD_OPTS = {
  "CC": "gcc",
  "AWK": "mawk",
}

def build_vmlinux(
  kernel_src_dir: pathlib.Path,
  target_arch: str,
  build_version: str,
  build_out_dir: pathlib.Path = None,
  build_opts: dict[str, str] = DEFAULT_BUILD_OPTS
):
  """Builds the Linux Kernel"""

  if not (kernel_src_dir.exists() and kernel_src_dir.is_dir()): raise RuntimeError(f"Kernel Source Directory does not exist or is not a directory: {kernel_src_dir.as_posix()}")

  _build_opts = build_opts.copy() | {
    "ARCH": target_arch,
    "KERNELVERSION": build_version,
    "COLOR": 1,
  }
  _env = os.environ.copy()
  for k in (
    'CFLAGS',
    'CPPFLAGS',
    'CXXFLAGS',
  ): _env.pop(k, None)

  logger.info("Building the Linux Kernel, verbose output is suppressed so please be patient...")
  proc: subprocess.CompletedProcess = subprocess.run(
    [
      'make', f'-j{len(os.sched_getaffinity(0))}',
        *[f"{k}={v}" for k, v in _build_opts.items()],
        "vmlinux"
    ],
    env=_env,
    cwd=kernel_src_dir.as_posix(),
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to build the Linux Kernel")
  