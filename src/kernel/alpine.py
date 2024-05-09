"""

Alpine Linux Kernel

See: https://gitlab.alpinelinux.org/alpine/aports/-/blob/3.19-stable/main/linux-lts/APKBUILD?ref_type=heads

"""
from __future__ import annotations
import pathlib, subprocess, sys, shutil
from typing import Literal
from loguru import logger

def fetch_build_info(
  ref: str,
  workdir: pathlib.Path,
  dest_dir: pathlib.Path = None,
) -> tuple[pathlib.Path, pathlib.Path]:
  """Fetch the Alpine Linux Kernel Package Build Info
  
  See: https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.19-stable/main/linux-lts?ref_type=heads

  Args:
    ref (str): The Git Reference to fetch the Alpine Linux Kernel Package Build Info
    workdir (pathlib.Path): The Working Directory to store the Alpine Linux Kernel Package Build Info
    dest_dir (pathlib.Path, optional): The Destination Directory to extract the Alpine Linux Kernel Package Build Info. Defaults to None.

  Returns:
    tuple[
      pathlib.Path: The Path to the extracted Alpine Linux Kernel Package Build Info
      pathlib.Path: The Path to the Alpine Linux Kernel Package Build Info tarball
    ] 
  """
  if not (workdir.exists() and workdir.is_dir()): raise RuntimeError(f'Workdir `{workdir.as_posix()}` does not exist or is not a Directory')

  src_url = f"https://gitlab.alpinelinux.org/alpine/aports/-/archive/{ref}/aports-{ref}.tar.gz"
  dl_archive = workdir / "aports.tar.gz"

  logger.debug(f"Fetching Alpine Linux Kernel Package Build Info: {src_url}")
  logger.info("Downloading the Alpine Linux Kernel Package Build Info")
  proc: subprocess.CompletedProcess = subprocess.run(
    [
      'curl', '-fL', '--progress-bar',
        '--output', dl_archive.as_posix(),
        src_url,
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to fetch the Alpine Linux Kernel Package Build Info: {dl_archive.as_posix()}")
  logger.debug("Folder Contents...\n{contents}".format(
    contents='\n'.join(f"  {f.name}" for f in workdir.iterdir())
  ))

  logger.debug(f"Extracting Alpine Linux Kernel Package Build Info: {dl_archive.as_posix()}")
  if not dl_archive.exists(): raise RuntimeError(f"Couldn't find the downloaded Alpine Linux Kernel Package Build Info: {dl_archive.as_posix()}")

  logger.info("Extracting the Alpine Linux Kernel Package Build Info")
  proc: subprocess.CompletedProcess = subprocess.run(
    [
      'tar', '-vx', '--gzip',
        '-f', dl_archive.as_posix(),
        '--strip-components', '3' if dest_dir else '2',
        '-C', dest_dir.as_posix() if dest_dir else workdir.as_posix(),
        f'aports-{ref}/main/linux-lts'
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to extract the Alpine Linux Kernel Package Build Info: {dl_archive.as_posix()}")

  extract_dir = dest_dir if dest_dir else workdir / f'linux-lts'
  if not (extract_dir.exists() and extract_dir.is_dir()): raise RuntimeError(f"Couldn't find the extracted Alpine Linux Kernel Package Build Info: {extract_dir.as_posix()}")

  return (extract_dir, dl_archive)

def apply_build_info(
  build_info_src: pathlib.Path,
  kernel_src: pathlib.Path,
  build_kind: Literal['lts', 'virt'],
  build_arch: Literal['x86', 'x86_64', 'armv7', 'aarch64', 'ppc64le', 's390x'],
) -> None:
  """Apply the Alpine Linux Build Info to the Linux Kernel Source"""

  if not (build_info_src.exists() and build_info_src.is_dir()): raise RuntimeError(f'Build Info Source `{build_info_src.as_posix()}` does not exist or is not a Directory')
  if not (kernel_src.exists() and kernel_src.is_dir()): raise RuntimeError(f'Kernel Source `{kernel_src.as_posix()}` does not exist or is not a Directory')
  if build_kind not in ['lts', 'virt']: raise ValueError(f"Unsupported Alpine Linux Kernel Build Kind: {build_kind}")

  build_combos: dict[str, set[str]] = {}
  for _cfg_file in build_info_src.glob('*.config'):
    _kind, _arch, _ = _cfg_file.name.split('.', 2)
    if _kind not in build_combos: build_combos[_kind] = set()
    build_combos[_kind].add(_arch)

  logger.debug(f"Supported Alpine Linux Kernel Build Combos: {build_combos}")
  if build_arch not in build_combos.get(build_kind, set()): raise ValueError(f"Unsupported Alpine Linux Kernel Build Arch for Kind: {build_kind}.{build_arch}")
  cfg_src = build_info_src / f"{build_kind}.{build_arch}.config"
  if not cfg_src.exists(): raise RuntimeError(f"Kernel Config File does not exist: {cfg_src.as_posix()}")

  ### Apply the Patches
  logger.info("Applying Patches to the Linux Kernel Source")
  for patch_file in build_info_src.glob('*.patch'):
    logger.debug(f"Applying Patch: {patch_file.name}")
    proc: subprocess.CompletedProcess = subprocess.run(
      [
        'patch', '-p', '1',
          '-i', patch_file.as_posix(),
          '-d', kernel_src.as_posix(),
      ],
      stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
    )
    if proc.returncode != 0: raise RuntimeError(f"Failed to apply Patch: {patch_file.name}")

  ### Copy the Config File
  logger.info("Assembling the Linux Kernel Config")
  shutil.copy2(cfg_src, kernel_src / '.config')
  logger.trace(f"Kernel Config...\n{cfg_src.read_text()}")
