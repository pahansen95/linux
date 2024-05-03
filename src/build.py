from typing import TypedDict, Required, NotRequired, Literal
from loguru import logger
import pathlib, re, sys, os, platform, orjson, uuid

### Local src imports
import utils
import os_releases.alpine as alpine
import blkdev.utils, blkdev.raw
import fs.utils, fs.ext4
###

supported_arch_t = Literal['x86_64', 'aarch64']
supported_blkdev_t = Literal['raw']
supported_fs_t = Literal['ext4']
supported_osrel_t = Literal['alpine']

class BuildError(RuntimeError): ...

class BlkDevCfg(TypedDict):
  """TODO: Breakout Partition/Filesystem Configs"""
  kind: supported_blkdev_t
  """The kind of Block Device to create"""
  path: str
  """Path to create the Image Path"""
  size: str
  """Human readable Size of the Block Device"""
  fs_type: supported_fs_t
  """The Filesystem Type to format the Block Device as"""
  volume_label: str
  """The Label to assign to the Filesystem"""
  fs_uuid: NotRequired[str]
  """(Optional) The UUID to assign to the Filesystem"""
  mount_point: str
  """Path to mount the Block Device"""

class BlkDevStatus(TypedDict):
  size_bytes: int
  """The size of the Block Device in bytes"""
  kind: supported_blkdev_t
  """The backing kind of the Block Device"""
  img_path: str
  """Path to the Block Device File"""
  device_path: str
  """The `/dev/` path to the attached block device"""
  device_info: dict[str, str]
  """Device Specific Information"""
  fs_label: str
  """The Label assigned to the Filesystem"""
  fs_uuid: str
  """The UUID assigned to the Filesystem"""
  fs_info: dict[str, str]
  """Filesystem Specific Information"""
  mount_point: str
  """Path to where the Block Device is mounted"""
  mount_info: dict[str, str]
  """Mount Backend Specific Information"""

class OSConfig(TypedDict):
  release: supported_osrel_t
  """What OS Release to build"""
  version: str
  """What version of the OS to build for"""

class BuildConfig(TypedDict):
  target_arch: supported_arch_t
  """The target architecture to build for"""
  os: OSConfig
  """The OS to build for"""
  rootfs: str
  """The path of the rootfs being built"""
  block_devices: list[BlkDevCfg]
  """The Block Devices to Configure"""

class BuildResult(TypedDict):
  block_devices: list[BlkDevStatus]
  """The Runtime State for each Block Device ordered by the configuration"""

  @staticmethod
  def json_default(obj) -> object:
    if isinstance(obj, pathlib.Path): return obj.as_posix()
    elif isinstance(obj, uuid.UUID): return str(obj)
    else: return obj

def safe_cleanup_blkdev(dev: BlkDevStatus) -> None:
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

def build_blkdevs(cfg: BuildConfig) -> BuildResult:
  """Creates & Setup the Block Devices"""
  logger.info("Building Block Devices")

  devs: list[str] = []
  for dev in cfg['block_devices']:
    logger.debug(f"Building Block Device: {dev['path']}")
    img_path = pathlib.Path(dev['path'])
    dev_size = utils.convert_to_bytes(dev['size'])
    mount_path = pathlib.Path(dev['mount_point'])
    fs_uuid = uuid.UUID(dev['fs_uuid']) if 'fs_uuid' in dev else None
    dev_status: BlkDevStatus = { # Fill in defaults, but we expect the operations to override
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

def cleanup_blkdevs(build_result: BuildResult) -> None:
  for dev in build_result['block_devices']:
    safe_cleanup_blkdev(dev)
    
def build_rootfs(cfg: BuildConfig) -> BuildResult:
  """Writes the RootFS for the target architecture onto the specified target"""
  logger.info('Building the RootFS')

  logger.debug('Checking for RootFS Path')
  rootfs = pathlib.Path(cfg['rootfs'])
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
    elif cfg['os']['release'] == 'ubuntu': raise NotImplementedError
    else: raise BuildError(f'Unsupported OS Release: {cfg["os"]["release"]}')
  except RuntimeError as e:
    raise BuildError(f'Failed to build rootfs: {e}')

  logger.success('RootFS Build Complete')
  return {}

def main():
  logger.debug('Checking for an AlpineLinux Environment')
  if not re.search(r'ID=alpine', pathlib.Path('/etc/os-release').read_text()): raise BuildError('Not running in an Alpine environment')
  logger.success("AlpineLinux Environment Detected")

  logger.debug('Checking we are root')
  if not os.getuid() == 0: raise BuildError('Must run as root')
  logger.success('Running as Root')

  build_cfg: BuildConfig = {
    'target_arch': platform.machine(),
    'os': {
      'release': 'alpine',
      'version': '3.19',
    },
    'rootfs': '/mnt/build/rootfs',
    'block_devices': [
      {
        "kind": "raw",
        "path": "/mnt/build/rootfs.img",
        "size": "4GiB",
        "fs_type": "ext4",
        "volume_label": "ROOT",
        # Let the UUID be auto-generated
        "mount_point": "/mnt/build/rootfs",
      }
    ]
  }
  build_result: BuildResult = {}

  build_result |= build_blkdevs(build_cfg)
  try:
    build_result |= build_rootfs(build_cfg)
  except:
    cleanup_blkdevs(build_result)
    raise
  
  buf = orjson.dumps(build_result, default=BuildResult.json_default, option=orjson.OPT_APPEND_NEWLINE)
  buf_len = len(buf)
  buf_offset = 0
  while buf_offset < buf_len: buf_offset += sys.stdout.buffer.write(buf[0:])

  cleanup_blkdevs(build_result)

if __name__ == '__main__':
  logger.remove()
  logger.add(sys.stderr, level=os.environ.get('LOG_LEVEL', 'DEBUG'), enqueue=True, colorize=True)
  try: main()
  except BuildError as e: logger.error(f'Build Failed: {e}')
  except Exception as e: logger.opt(exception=e).critical("Unhandled Exception")
  finally:
    logger.complete()
    sys.stderr.flush()
    sys.stdout.flush()