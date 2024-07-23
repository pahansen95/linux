"""

Common Linux Kernel Operations

See: https://gitlab.alpinelinux.org/alpine/aports/-/blob/3.19-stable/main/linux-lts/APKBUILD?ref_type=heads

"""
from __future__ import annotations
import pathlib, subprocess, sys, os
from loguru import logger

DEFAULT_BUILD_OPTS = {
  "CC": "gcc",
  "AWK": "mawk",
}

def _assemble_build_opts(
  target_arch: str,
  build_version: str,
  opts: dict[str, str],
  build_out_dir: pathlib.Path = None,
  verbose: int = 0,
) -> dict[str, str]:
  return { k: v for k, v in (
    {
      "ARCH": target_arch,
      "KERNELVERSION": build_version,
      "COLOR": 1,
      "O": build_out_dir.as_posix() if build_out_dir else None,
      "V": verbose,
    } | opts.copy()
  ).items() if v is not None }

def _assemble_build_env(
  env: dict[str, str] = {},
) -> dict[str, str]:
  _env = os.environ.copy()
  for k in (
    'CFLAGS',
    'CPPFLAGS',
    'CXXFLAGS',
  ): _env.pop(k, None)
  return _env | env.copy()

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
  proc_args = [
    'curl', '-fL', '--progress-bar',
      '-O',
        '--remote-header-name',
        '--output-dir', workdir.as_posix(),
      kernel_url,
  ]
  logger.debug(f"Running: {' '.join(proc_args)}")
  proc: subprocess.CompletedProcess = subprocess.run(
    proc_args,
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to fetch the Linux Kernel Source: {kernel_url}")
  logger.debug("Folder Contents...\n{contents}".format(
    contents='\n'.join(f"  {f.name}" for f in workdir.iterdir())
  ))

  logger.debug(f"Extracting Linux Kernel Source: {kernel_url}")
  if not kernel_src.exists(): raise RuntimeError(f"Couldn't find the downloaded Kernel Source: {kernel_src.as_posix()}")

  logger.info("Extracting the Linux Kernel Source, verbose output is suppressed so please be patient...")
  proc_args = [
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
  ]
  logger.debug(f"Running: {' '.join(proc_args)}")
  proc: subprocess.CompletedProcess = subprocess.run(
    proc_args,
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to extract the Linux Kernel Source: {kernel_src.as_posix()}")

  extract_dir = dest_dir if dest_dir else workdir / f'linux-{".".join(kernel_semver)}'
  if not (extract_dir.exists() and extract_dir.is_dir()): raise RuntimeError(f"Couldn't find the extracted Kernel Source: {extract_dir.as_posix()}")

  return (extract_dir, kernel_src)

def clean(
  kernel_src_dir: pathlib.Path,
  target_arch: str,
  build_version: str,
  build_out_dir: pathlib.Path = None,
  build_opts: dict[str, str] = DEFAULT_BUILD_OPTS
):
  """Cleans the Kernel Source Directory for a Fresh Build"""

  if not (kernel_src_dir.exists() and kernel_src_dir.is_dir()): raise RuntimeError(f"Kernel Source Directory does not exist or is not a directory: {kernel_src_dir.as_posix()}")

  _build_out_dir = build_out_dir if build_out_dir else kernel_src_dir
  _build_opts = _assemble_build_opts(target_arch, build_version, build_opts, build_out_dir=build_out_dir)
  _build_env = _assemble_build_env()

  logger.debug("Cleaning the Kernel Source Directory")
  proc_args = [
    'make',
    *[f"{k}={v}" for k, v in _build_opts.items()],
    'mrproper',
  ]
  logger.debug(f"Running: {' '.join(proc_args)}")
  proc: subprocess.CompletedProcess = subprocess.run(
    proc_args,
    env=_build_env,
    cwd=kernel_src_dir.as_posix(),
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to clean the Kernel Source Directory")


def build_vmlinux(
  kernel_src_dir: pathlib.Path,
  target_arch: str,
  build_version: str,
  build_out_dir: pathlib.Path = None,
  build_opts: dict[str, str] = DEFAULT_BUILD_OPTS
):
  """Builds the Linux Kernel"""

  if not (kernel_src_dir.exists() and kernel_src_dir.is_dir()): raise RuntimeError(f"Kernel Source Directory does not exist or is not a directory: {kernel_src_dir.as_posix()}")

  _build_out_dir = build_out_dir if build_out_dir else kernel_src_dir
  _build_opts = _assemble_build_opts(target_arch, build_version, build_opts, build_out_dir=build_out_dir)
  _build_env = _assemble_build_env()

  logger.info("Building the Linux Kernel")
  proc_args = [
    'make', f'-j{len(os.sched_getaffinity(0))}',
      *[f"{k}={v}" for k, v in _build_opts.items()],
      "vmlinux"
  ]
  logger.debug(f"Running: {' '.join(proc_args)}")
  proc: subprocess.CompletedProcess = subprocess.run(
    proc_args,
    env=_build_env,
    cwd=kernel_src_dir.as_posix(),
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to build the Linux Kernel")

def build_modules(
  kernel_src_dir: pathlib.Path,
  target_arch: str,
  build_version: str,
  build_out_dir: pathlib.Path = None,
  build_opts: dict[str, str] = DEFAULT_BUILD_OPTS
) -> pathlib.Path:
  """Builds the Linux Kernel Modules"""
  
  if not (kernel_src_dir.exists() and kernel_src_dir.is_dir()): raise RuntimeError(f"Kernel Source Directory does not exist or is not a directory: {kernel_src_dir.as_posix()}")

  # TODO: Set Build Output Directory

  _build_out_dir = build_out_dir if build_out_dir else kernel_src_dir
  _build_opts = _assemble_build_opts(target_arch, build_version, build_opts, build_out_dir=build_out_dir)
  _build_env = _assemble_build_env()

  logger.info("Building the Linux Kernel Modules")
  proc_args = [
    'make', f'-j{len(os.sched_getaffinity(0))}',
      *[f"{k}={v}" for k, v in _build_opts.items()],
      "modules"
  ]
  logger.debug(f"Running: {' '.join(proc_args)}")
  proc: subprocess.CompletedProcess = subprocess.run(
    proc_args,
    env=_build_env,
    cwd=kernel_src_dir.as_posix(),
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to build the Linux Kernel Modules")

  return kernel_src_dir / 'modules'

def build_image(
  kernel_src_dir: pathlib.Path,
  target_arch: str,
  build_version: str,
  build_out_dir: pathlib.Path = None,
  build_opts: dict[str, str] = DEFAULT_BUILD_OPTS
) -> pathlib.Path:
  """Builds the Linux Kernel Image"""

  if not (kernel_src_dir.exists() and kernel_src_dir.is_dir()): raise RuntimeError(f"Kernel Source Directory does not exist or is not a directory: {kernel_src_dir.as_posix()}")

  # TODO: Set Build Output Directory

  _build_out_dir = build_out_dir if build_out_dir else kernel_src_dir
  _build_opts = _assemble_build_opts(target_arch, build_version, build_opts, build_out_dir=build_out_dir)
  _build_env = _assemble_build_env()

  logger.info("Building the Linux Kernel Image")
  build_target: str; build_output: str
  if target_arch == 'x86_64':
    build_target = 'bzImage'
    build_output = 'arch/x86/boot/bzImage'
  else: raise NotImplementedError(f"Unsupported Target Arch: {target_arch}")

  proc_args = [
    'make', f'-j{len(os.sched_getaffinity(0))}',
      *[f"{k}={v}" for k, v in _build_opts.items()],
      build_target
  ]
  logger.debug(f"Running: {' '.join(proc_args)}")
  proc: subprocess.CompletedProcess = subprocess.run(
    proc_args,
    env=_build_env,
    cwd=kernel_src_dir.as_posix(),
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to build the Linux Kernel Image")

  if not (_build_output := _build_out_dir / build_output).exists(): raise RuntimeError(f"Couldn't find the built Kernel Image: {_build_output.as_posix()}")

  return _build_output

def install_headers(
  kernel_src_dir: pathlib.Path,
  target_arch: str,
  build_version: str,
  build_out_dir: pathlib.Path = None,
  build_opts: dict[str, str] = DEFAULT_BUILD_OPTS
):
  """Installs the Linux Kernel Headers"""

  if not (kernel_src_dir.exists() and kernel_src_dir.is_dir()): raise RuntimeError(f"Kernel Source Directory does not exist or is not a directory: {kernel_src_dir.as_posix()}")

  _build_out_dir = build_out_dir if build_out_dir else kernel_src_dir
  _build_opts = _assemble_build_opts(target_arch, build_version, build_opts, build_out_dir=build_out_dir)
  _build_env = _assemble_build_env()

  logger.info("Installing the Linux Kernel Headers")
  proc_args = [
    'make', f'-j{len(os.sched_getaffinity(0))}',
      *[f"{k}={v}" for k, v in _build_opts.items()],
      "headers_install"
  ]
  logger.debug(f"Running: {' '.join(proc_args)}")
  proc: subprocess.CompletedProcess = subprocess.run(
    proc_args,
    env=_build_env,
    cwd=kernel_src_dir.as_posix(),
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to install the Linux Kernel Headers")

def package(
  kernel_src_dir: pathlib.Path,
  target_arch: str,
  build_version: str,
  build_out_dir: pathlib.Path = None,
  build_opts: dict[str, str] = DEFAULT_BUILD_OPTS
):
  """Package the Kernel as a Directory"""
  
  if not (kernel_src_dir.exists() and kernel_src_dir.is_dir()): raise RuntimeError(f"Kernel Source Directory does not exist or is not a directory: {kernel_src_dir.as_posix()}")

  _build_out_dir = build_out_dir if build_out_dir else kernel_src_dir
  _build_opts = _assemble_build_opts(target_arch, build_version, build_opts, build_out_dir=build_out_dir)
  _build_env = _assemble_build_env()

  logger.info("Packaging the Kernel")
  proc_args = [
    'make', f'-j{len(os.sched_getaffinity(0))}',
      *[f"{k}={v}" for k, v in _build_opts.items()],
      "dir-pkg"
  ]
  logger.debug(f"Running: {' '.join(proc_args)}")
  proc: subprocess.CompletedProcess = subprocess.run(
    proc_args,
    env=_build_env,
    cwd=kernel_src_dir.as_posix(),
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to package the Kernel")