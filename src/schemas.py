
from typing import TypedDict, Literal, NotRequired
import pathlib, uuid

supported_arch_t = Literal['x86_64', 'aarch64']
supported_blkdev_t = Literal['raw']
supported_fs_t = Literal['ext4']
supported_osrel_t = Literal['alpine']
supported_rootfs_t = Literal['tar', 'tar.gz', 'tar.xz', 'tar.bz2', 'tar.lzma', 'tar.lzip', 'tar.lzop', 'tar.zstd' ]

class ArtifactStatus(TypedDict):
  path: str
  """The path to the Artifact"""
  fmt: str
  """The File Format of the Artifact"""
  size_bytes: int
  """The Size of the Artifact in bytes"""
  hash: str
  """The Hash of the Artifact in ALGO:FINGERPRINT format"""

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

class RootFSConfig(TypedDict):
  """The Configuration for the RootFS to build"""
  artifact_path: str
  """The path to write the RootFS artifact to"""
  fmt: supported_rootfs_t
  """The File Format of the build artifact"""
  build_path: NotRequired[str]
  """The Path in which to build the RootFS"""

class RootFSStatus(TypedDict):
  """The State of the RootFS post build"""
  fmt: supported_rootfs_t
  """The File Format of the build artifact"""
  build_path: str
  """The Path containing the built RootFS"""

class KernelCfg(TypedDict):
  path: str
  """The Path where the root of the kernel source will be extracted, built, etc..."""
  version: str
  """The Mainline Kernel Version to build"""
  
  ### TODO: Where should the following go?
  patch_path: str
  """The Path where the root of the Kernel Patch source will be extracted to"""
  patch_src: Literal['alpine']
  """Which Kernel Patch to apply to the Mainline Kernel"""
  patch_ref: str
  """The Git reference to the Alpine Linux Kernel aports project to fetch the Kernel Patches from; dependent on the patch source"""
  patch_kind: Literal['lts', 'virt']
  """The kind of Kernel Patches to apply; dependent on the patch source"""
  ###
  
class KernelStatus(TypedDict):
  version: str
  """The Kernel Version built"""
  build_path: str
  """The Path containing the built Kernel"""
  kernel_src: str
  """The Kernel Source"""
  patch_path: str
  """The Path containing the Kernel Patch source"""
  patch_src: str
  """The Kernel Patch Source"""

class BuildConfig(TypedDict):
  workdir: str
  """The Working Directory to persist runtime data"""
  target_arch: supported_arch_t
  """The target architecture to build for"""
  os: OSConfig
  """The OS to build for"""
  rootfs: RootFSConfig
  """The RootFS to build"""
  block_devices: list[BlkDevCfg]
  """The Block Devices to Configure"""
  kernel: KernelCfg

class BuildResult(TypedDict):
  rootfs: RootFSStatus
  """The Runtime State for the RootFS"""
  block_devices: list[BlkDevStatus]
  """The Runtime State for each Block Device ordered by the configuration"""
  artifacts: list[ArtifactStatus]
  """The Artifacts produced by the build"""
  kernel: KernelStatus
  """The Runtime State for the Kernel"""

  @staticmethod
  def json_default(obj) -> object:
    if isinstance(obj, pathlib.Path): return obj.as_posix()
    elif isinstance(obj, uuid.UUID): return str(obj)
    else: return obj
