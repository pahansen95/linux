from __future__ import annotations
from typing import TypedDict, Required, NotRequired, Literal
from loguru import logger
import pathlib, re, sys, os, platform, orjson, uuid, tempfile

### Local src imports
import configs.alpine
import configs.default
import utils
import schemas
import os_releases.alpine as alpine
import blkdev.utils, blkdev.raw
import fs.utils, fs.ext4
import artifact.tar
import configs
import kernel.utils, kernel.alpine
###

def safe_cleanup_blkdev(dev: schemas.BlkDevStatus) -> None:
  """Cleanup the Block Device & Mount Points without failing"""
  logger.info(f"Cleaning up Block Device: {dev['img_path']}")
  device_path = pathlib.Path(dev['device_path'])

  mount_point = dev.get('mount_point')
  if mount_point:
    logger.debug(f"Unmounting Block Device: {mount_point}")
    mount_point = pathlib.Path(mount_point)
    if blkdev.utils.is_mounted(mount_point):
      try:
        blkdev.utils.unmount(mount_point)
        logger.success(f"Block Device Unmounted: {mount_point.as_posix()}")
      except: logger.opt(exception=True).warning(f"Failed to unmount block device: {mount_point.as_posix()}")
    logger.success(f"Block Device Unmounted: {mount_point.as_posix()}")

  device_path = dev.get('device_path')
  if device_path:
    device_path = pathlib.Path(device_path)
    logger.debug(f"Detaching Block Device: {device_path}")
    img_path = pathlib.Path(dev['img_path'])
    if dev['kind'] == 'raw':
      if blkdev.raw.is_attached(img_path, dev['device_info']):
        try:
          blkdev.raw.cleanup(dev['device_info'])
          logger.success(f"Block Device Detached: {device_path.as_posix()}")
        except: logger.opt(exception=True).warning(f"Failed to cleanup block device: {device_path.as_posix()}")
    else: raise BuildError(f"Unknown Block Device Kind: {dev['kind']}")
    logger.success(f"Block Device Detached: {device_path.as_posix()}")
  
  logger.success(f"Block Device Cleaned Up: {dev['img_path']}")

def build_blkdevs(cfg: schemas.BuildConfig) -> schemas.BuildResult:
  """Creates & Setup the Block Devices"""
  logger.info("Building Block Devices")

  devs: list[str] = []
  for dev in cfg['block_devices']:
    logger.debug(f"Building Block Device: {dev['path']}")
    img_path = pathlib.Path(dev['path'])
    dev_size = utils.convert_to_bytes(dev['size'])
    mount_path = pathlib.Path(dev['mount_point'])
    fs_uuid = uuid.UUID(dev['fs_uuid']) if 'fs_uuid' in dev else None
    dev_status: schemas.BlkDevStatus = { # Fill in defaults, but we expect the operations to override
      "size_bytes": dev_size,
      "kind": dev['kind'],
      "img_path": img_path.as_posix(),
      "device_info": {},
      "fs_label": dev['volume_label'],
      "fs_uuid": dev.get('fs_uuid'),
      "fs_info": {},
      "mount_point": mount_path.as_posix(),
      "mount_info": {},
    }

    logger.info(f"Creating Block Device `{img_path.as_posix()}`")    
    try:
      if dev['kind'] == 'raw': dev_status |= blkdev.raw.create(img_path, dev_size)
      else: raise BuildError(f"Unknown Block Device Kind: {dev['kind']}")
    except RuntimeError as e: raise BuildError(f"Failed to create block device: {e}")
    logger.success(f"Block Device Created: {img_path.as_posix()}")

    logger.info(f"Attaching Block Device `{img_path.as_posix()}`")
    try:
      if dev['kind'] == 'raw': dev_status |= blkdev.raw.attach(img_path)
      else: raise BuildError(f"Unknown Block Device Kind: {dev['kind']}")
    except RuntimeError as e: raise BuildError(f"Failed to attach block device: {e}")

    device_path = pathlib.Path(dev_status['device_path'])
    logger.success(f"Block Device {img_path.as_posix()} attached at {device_path.as_posix()}")

    logger.info(f"Formatting Block Device `{device_path.as_posix()}`")
    try:
      if dev['fs_type'] == 'ext4': dev_status |= fs.ext4.format(device_path, dev['volume_label'], fs_uuid=fs_uuid)
      else: raise BuildError(f"Unknown Filesystem Type: {dev['fs_type']}")
    except RuntimeError as e: raise BuildError(f"Failed to format block device: {e}")
    logger.success(f"Block Device Formatted: {device_path.as_posix()}")

    logger.debug(f"Mounting Block Device `{device_path.as_posix()}` to `{mount_path.as_posix()}`")
    try:
      if dev['kind'] == 'raw': dev_status |= blkdev.utils.mount(device_path, mount_path, dev['fs_type'])
      else: raise BuildError(f"Unknown Block Device Kind: {dev['kind']}")
    except RuntimeError as e: raise BuildError(f"Failed to mount block device: {e}")

    devs.append(dev_status)
    logger.success(f"Block Device `{img_path.as_posix()}` attached at `{device_path.as_posix()}` is mounted at `{mount_path.as_posix()}`")

  return { "block_devices": devs }

def cleanup_blkdevs(build_result: schemas.BuildResult) -> None:
  for dev in build_result['block_devices']:
    safe_cleanup_blkdev(dev)
    
def build_rootfs(cfg: schemas.BuildConfig) -> tuple[schemas.RootFSConfig, schemas.RootFSStatus]:
  """Writes the RootFS for the target architecture onto the specified target"""
  logger.info('Building the RootFS')

  def _build_rootfs(rootfs: pathlib.Path) -> schemas.RootFSStatus:
    logger.debug(f'Checking for RootFS Path: {rootfs.as_posix()}')
    if not (rootfs.exists() and rootfs.is_dir()): raise BuildError(f'Rootfs path does not exist or is not a directory: {rootfs.as_posix()}')
    logger.success(f'Target RootFS located at {rootfs.as_posix()}')

    try:
      os_release = cfg['os']['release'].lower()
      if os_release == 'alpine':
        if not (os_version := alpine.is_version_supported(cfg['os']['version'])): raise BuildError(f'Unsupported Alpine Version: {cfg["os"]["version"]}')
        logger.debug('Initializing Alpine')
        alpine.init(os_version, cfg['target_arch'], rootfs)
        logger.success('Alpine Initialized')
        logger.debug('Installing Packages')
        alpine.install_pkgs(alpine.DEFAULT_PKGS, cfg['target_arch'], rootfs)
        logger.success(f'Packages Installed: {alpine.DEFAULT_PKGS}')
      else: raise BuildError(f'Unsupported OS Release: {cfg["os"]["release"]}')
    except RuntimeError as e:
      raise BuildError(f'Failed to build rootfs: {e}')

    logger.success('RootFS Build Complete')
    return {
      'fmt': cfg['rootfs']['fmt'],
      'build_path': rootfs.as_posix(),
    }

  if 'build_path' in cfg['rootfs']: build_dir = pathlib.Path(cfg['rootfs']['build_path'])
  else: build_dir = pathlib.Path(tempfile.mkdtemp(dir=cfg['workdir']))
  return (
    cfg['rootfs'] | { 'build_path': build_dir.as_posix() },
    { 'rootfs': _build_rootfs(build_dir) }
  )

def package_rootfs(cfg: schemas.BuildConfig) -> schemas.BuildResult:
  """Package the RootFS into an artifact"""
  src_path = pathlib.Path(cfg['rootfs']['build_path'])
  dst_path = pathlib.Path(cfg['rootfs']['artifact_path'])
  logger.info(f'Packaging the RootFS: {dst_path.as_posix()}')

  _artifat_status: schemas.ArtifactStatus = {}
  if cfg['rootfs']['fmt'].startswith('tar.'): _artifat_status |= artifact.tar.create(src_path, dst_path, cfg['rootfs']['fmt'].split('.', maxsplit=1)[1])
  elif cfg['rootfs']['fmt'] == 'tar': _artifat_status |= artifact.tar.create(src_path, dst_path, None)
  else: raise BuildError(f'Unsupported RootFS Artifact Format: {cfg["rootfs"]["fmt"]}')

  return { 'artifacts': [_artifat_status] }

def deploy_rootfs(
  cfg: schemas.BuildConfig,
  rootfs_artifact: schemas.ArtifactStatus,
) -> schemas.BuildResult:
  """Deploys the RootFS from the artifact to the mount directory of the root disk
  
  The First Block Device is assumed to be the root disk
  """
  if len(cfg['block_devices']) > 1: raise NotImplementedError('Only a single block device is supported for deployment')
  artifact_file = pathlib.Path(rootfs_artifact['path'])
  mount_point = pathlib.Path(cfg['block_devices'][0]['mount_point'])

  if not artifact_file.exists(): raise BuildError(f'RootFS Artifact does not exist: {artifact_file.as_posix()}')
  if not (mount_point.exists() and mount_point.resolve().is_dir()): raise BuildError(f'Bloc Device Mount Point does not exist or is not a directory: {mount_point.as_posix()}')

  logger.info(f'Deploying RootFS from {artifact_file.as_posix()} to {mount_point.as_posix()}')

  if cfg['rootfs']['fmt'].startswith('tar.'): artifact.tar.extract(artifact_file, mount_point, rootfs_artifact['hash'], cfg['rootfs']['fmt'].split('.', maxsplit=1)[1])
  elif cfg['rootfs']['fmt'] == 'tar': artifact.tar.extract(artifact_file, mount_point, rootfs_artifact['hash'], None)
  else: raise BuildError(f'Unsupported RootFS Artifact Format: {cfg["rootfs"]["fmt"]}')

  return {}

def build_kernel(
  # ...
) -> ...:
  """Build the Linux Kernel
  
  !!! NOTE: Under Development !!!
  """
  target_arch = 'x86_64'
  kernel_version = 'v6.6.30' # Current Stable
  aports_ref = '3.19-stable'
  kernel_build_semver = f'{kernel_version.lstrip("v")}+alpine-{aports_ref}'
  kernel_build_kind = 'lts'

  logger.info(f'Building Kernel: {kernel_version}')

  with tempfile.TemporaryDirectory() as tmpdir:
    workdir = pathlib.Path(tmpdir)

    ### Fetch the Kernel Source

    (kernel_src := workdir / f'linux-{kernel_version}').mkdir(mode=0o755, parents=False, exist_ok=True)
    logger.debug(f'Fetching Kernel Source: {kernel_version}')
    (
      _kernel_src,
      _kernel_archive,
    ) = kernel.utils.fetch_src(kernel_version, workdir, kernel_src)
    assert _kernel_src.as_posix() == kernel_src.as_posix(), f'{_kernel_src.as_posix()} != {kernel_src.as_posix()}'
    logger.debug(f'Kernel Source `{_kernel_archive.as_posix()}` extracted to `{kernel_src.as_posix()}`')
    logger.success(f'Kernel Source Fetched: {kernel_version}')

    ### Fetch the build info

    (build_info_src := workdir / 'alpine-kernel').mkdir(mode=0o755, parents=False, exist_ok=True)
    logger.debug(f'Fetching Alpine Linux Kernel Package Build Info: {aports_ref}')
    (
      _build_info_src,
      _build_info_archive,
    ) = kernel.alpine.fetch_build_info(aports_ref, workdir, build_info_src)
    assert _build_info_src.as_posix() == build_info_src.as_posix(), f'{_build_info_src.as_posix()} != {build_info_src.as_posix()}'
    logger.debug(f'Alpine Linux Kernel Package Build Info `{_build_info_archive.as_posix()}` extracted to `{build_info_src.as_posix()}`')
    logger.success(f'Alpine Linux Kernel Package Build Info Fetched: {aports_ref}')

    ### Prepare the Kernel Build
    logger.info('Preparing Kernel Build')

    logger.info('Cleaning Kernel Source')
    kernel.utils.clean(
      kernel_src_dir=kernel_src,
    )
    logger.success('Kernel Source Cleaned')

    logger.info('Applying Alpine Linux Kernel Build Info')
    kernel.alpine.apply_build_info(
      build_info_src=build_info_src,
      kernel_src=kernel_src,
      build_kind=kernel_build_kind,
      build_arch=target_arch,
    )
    logger.success('Alpine Linux Kernel Build Info Applied')

    ### Build the Kernel
    logger.info('Building the Kernel')

    logger.info('Building vmlinux')
    kernel.utils.build_vmlinux(
      kernel_src_dir=kernel_src,
      target_arch=target_arch,
      build_version=kernel_build_semver,
    )
    logger.success('vmlinux Built')

    # kernel.alpine.build(_extract_dir, workdir)
  
  raise NotImplementedError

def main() -> int:
  logger.debug('Checking for an AlpineLinux Environment')
  if not re.search(r'ID=alpine', pathlib.Path('/etc/os-release').read_text()): raise BuildError('Not running in an Alpine environment')
  logger.success("AlpineLinux Environment Detected")

  logger.debug('Checking we are root')
  if not os.getuid() == 0: raise BuildError('Must run as root')
  logger.success('Running as Root')


  ### NOTE: Development
  build_kernel()
  ###

  build_cfg: schemas.BuildConfig = None
  build_cfg_json = sys.stdin.read().strip()
  if build_cfg_json: build_cfg = orjson.loads(build_cfg_json, object_hook=schemas.BuildConfig)
  else: build_cfg = configs.default.assemble() | configs.alpine.assemble()
  assert build_cfg is not None
  logger.info(f"Using Build Configuration...\n{orjson.dumps(build_cfg, option=orjson.OPT_INDENT_2).decode()}")

  build_result: schemas.BuildResult = {
    'rootfs': None,
    'block_devices': [],
    'artifacts': [],
  }
  (patched_cfg, status) = build_rootfs(build_cfg)
  build_cfg['rootfs'] |= patched_cfg
  build_result['rootfs'] = status
  build_result['artifacts'].extend(package_rootfs(build_cfg)['artifacts'])
  if 'block_devices' in build_cfg:
    try:
      build_result['block_devices'].extend(build_blkdevs(build_cfg)['block_devices'])
      build_result |= deploy_rootfs(build_cfg, build_result['artifacts'][0]) # We assume the first artifact is the rootfs
    finally: 
      if '--no-cleanup' not in sys.argv: cleanup_blkdevs(build_result)
  
  buf = orjson.dumps(build_result, default=schemas.BuildResult.json_default, option=orjson.OPT_APPEND_NEWLINE)
  buf_len = len(buf)
  buf_offset = 0
  while buf_offset < buf_len: buf_offset += sys.stdout.buffer.write(buf[0:])

  return 0

# if __name__ == '__main__':
#   _rc = 1
#   logger.remove()
#   logger.add(sys.stderr, level=os.environ.get('LOG_LEVEL', 'DEBUG'), enqueue=True, colorize=True)
#   try: _rc = main()
#   except BuildError as e: logger.error(f'Build Failed: {e}')
#   except Exception as e: logger.opt(exception=e).critical("Unhandled Exception")
#   finally:
#     logger.complete()
#     sys.stderr.flush()
#     sys.stdout.flush()
#     exit(_rc)

class BuildError(RuntimeError): ...
class CLIError(RuntimeError): ...
def load_from_env(name: str) -> str:
  try:
    val = os.environ[name]
    if not val: raise KeyError()
    return val
  except KeyError: raise CLIError(f"Missing or Empty Environment Variable: {name}")
def write_to_stdout(data: bytes):
  buf_len = len(data)
  bytes_written = 0
  while bytes_written < buf_len: bytes_written += sys.stdout.buffer.write(data[bytes_written:])
def setup_logging():
  logger.remove()
  logger.add(sink=sys.stderr, level=os.environ.get('LOG_LEVEL', 'INFO'), enqueue=True, colorize=True)
def finalize():
  logger.complete()
  sys.stderr.flush()
  sys.stdout.flush()
def _build_error(e: Exception):
  logger.error(f'Build Failed: {e}')
  return 1
def _cli_error(e: Exception):
  logger.error(e)
  return 2
def _unhandled_error(e: Exception):
  logger.opt(exception=e).critical('Unhandled exception')
  return 3
def _interrupt_error():
  logger.warning("Interrupt Detected, Exiting...")
  return 4

if __name__ == '__main__':
  _rc = 255
  setup_logging()
  try: _rc = main()
  except (KeyboardInterrupt, SystemExit): _rc = _interrupt_error()
  except CLIError as e: _rc = _cli_error(e)
  except BuildError as e: _rc = _build_error(e)
  except Exception as e: _rc = _unhandled_error(e)
  finally: finalize()
  sys.exit(_rc)