
import pathlib, sys, subprocess, uuid

def format(
  device_path: pathlib.Path,
  volume_label: str,
  fs_uuid: uuid.UUID | None = None,
  mke2fs_opts: list[str] = [],
  blocks_count: int | None = None,
) -> dict[str, str]:
  """Format a Device as an ext4 filesystem
  
  Args:
    device_path (pathlib.Path): The path to the block device
    volume_label (str): The label to assign to the volume
    uuid (str, optional): The UUID to assign to the volume. Defaults to None.
    mke2fs_opts (list[str], optional): Additional options to pass to mke2fs. Defaults to [].
    blocks_count (int, optional): The number of blocks to format. Defaults to None: `blocks-count is the number of blocks on the device. If omitted, mke2fs automagically figures the file system size.`
  """
  if not (device_path.exists() and device_path.is_block_device()): raise RuntimeError(f"Device Path does not exist or is not a block device: {device_path.as_posix()}")
  if len(volume_label.encode()) > 16: raise ValueError(f"Volume Label must be 16 bytes or less: {len(volume_label.encode())}")
  if '-L' in mke2fs_opts: raise ValueError("Don't set the Volume Label in the mke2fs options; use the `volume_label` parameter instead")
  if '-U' in mke2fs_opts: raise ValueError("Don't set the UUID in mke2fs options; use the `fs_uuid` parameter instead")

  if fs_uuid is None: fs_uuid = uuid.uuid4()
  proc: subprocess.CompletedProcess = subprocess.run(
    [a for a in [
      "mkfs.ext4",
        "-v", # Verbose
        "-L", volume_label,
        "-U", str(fs_uuid),
        *mke2fs_opts,
        device_path.as_posix(),
        blocks_count,
    ] if a is not None],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to format block device: {device_path.as_posix()}")
  return {
    "fs_label": volume_label,
    "fs_uuid": str(fs_uuid),
    "fs_info": {
      "fs_type": "ext4",
      "fs_opts": mke2fs_opts,
    }
  }
