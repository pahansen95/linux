
import sys, subprocess, pathlib
from loguru import logger

def is_mounted(mount_path: pathlib.Path) -> bool:
  """Check if a Mount Point is Mounted"""
  for _mount_line in pathlib.Path("/proc/mounts").read_text().splitlines():
    (
      _device, _mount_point, _fs_type, _mount_opts, _fs_freq, _fs_pass
    ) = _mount_line.split()
    if _mount_point == mount_path.as_posix(): return True
  return False

def mount(
  device_path: pathlib.Path,
  mount_point: pathlib.Path,
  fs_type: str,
  mount_opts: list[str] = [],
  volume_label: str | None = None,
  fs_uuid: str | None = None,
) -> dict[str, str]:
  """Mount the Block Device to the Mount Point
  
  Args:
    device_path (pathlib.Path): The path to the block device
    mount_point (pathlib.Path): The path to the mount point
    fs_type (str): The filesystem type.
    mount_opts (list[str], optional): Additional mount options. Defaults to [].
    volume_label (str, optional): The volume label of partition to mount. Defaults to None. Mutually exclusive with `fs_uuid`.
    fs_uuid (str, optional): The filesystem UUID of the partition to mount. Defaults to None. Mutually exclusive with `volume_label`.
  """
  if not (device_path.exists() and device_path.is_block_device()): raise RuntimeError(f"Device Path does not exist or is not a block device: {device_path.as_posix()}")
  if not mount_point.parent.exists(): raise RuntimeError(f"Mount Point parent directory does not exist: {mount_point.parent.as_posix()}")
  if not (mount_point.exists() and mount_point.is_dir()): raise RuntimeError(f"Mount Point does not exist or is not a directory: {mount_point.as_posix()}")
  if volume_label is not None and fs_uuid is not None: raise ValueError("Volume Label and UUID are mutually exclusive")
  
  args = [
    "mount", "-v",
      "-t", fs_type,
      "-o", ",".join(mount_opts),
  ]
  if volume_label is not None: args += ["-L", volume_label]
  elif fs_uuid is not None: args += ["-U", fs_uuid]
  args += [device_path.as_posix(), mount_point.as_posix()]

  proc: subprocess.CompletedProcess = subprocess.run(
    args,
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to mount loop device `{device_path.as_posix()}` to `{mount_point.as_posix()}`")

  return {
    "mount_point": mount_point.as_posix(),
    "mount_info": { k: v for k, v in {
      "fs_type": fs_type,
      "mount_opts": mount_opts,
      "volume_label": volume_label,
      "fs_uuid": fs_uuid,
    }.items() if v is not None }
  }

def unmount(
  mount_point: pathlib.Path,
) -> None:
  """Unmount the Block Device from the Mount Point"""
  if not (mount_point.exists() and mount_point.is_dir()): raise RuntimeError(f"Mount Point does not exist or is not a directory: {mount_point.as_posix()}")

  proc: subprocess.CompletedProcess = subprocess.run(
    [
      "umount",
        mount_point.as_posix(),
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to unmount loop device from `{mount_point.as_posix()}`")
