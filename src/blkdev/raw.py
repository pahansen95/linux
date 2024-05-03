import sys, subprocess, pathlib, orjson
from loguru import logger

def is_attached(img_file: pathlib.Path, device_info: dict[str, str]) -> str:
  """Checks if the Image File is attached on the Loopback Device. If so returns the name of the loopback device. Otherwise returns an empty string. Allows for boolean evaluation"""

  proc: subprocess.CompletedProcess = subprocess.run(
    ["losetup", "--json"],
    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to list loop devices")
  loopback_cfg: list[dict[str, str]] = orjson.loads(proc.stdout)["loopdevices"]
  for loop_dev in loopback_cfg:
    if loop_dev["back-file"] == img_file.as_posix(): return loop_dev["name"]
  return ""

def create(img_file: pathlib.Path, size_bytes: int) -> dict[str, str]:
  """Creates a Raw Block Device using QEMU"""
  if not img_file.parent.exists(): raise RuntimeError(f"Block Device parent directory does not exist: {img_file.parent.as_posix()}")
  if img_file.exists(): raise RuntimeError(f"Block Device already exists: {img_file.as_posix()}")

  raw_opts = {
    "size": size_bytes,
  }

  proc: subprocess.CompletedProcess = subprocess.run(
    [
      "qemu-img",
        "create",
          "-f", "raw",
          "-o", ",".join(f"{k}={v}" for k, v in raw_opts.items()),
          img_file.as_posix(),
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )

  if proc.returncode != 0: raise RuntimeError(f"Failed to create raw block device: {img_file.as_posix()}")

  return { "file": img_file.as_posix(), "size": size_bytes, "kind": "raw" }

def attach(image_file: pathlib.Path ) -> dict[str, str]:
  """Attach the Image File as a Block Device as a loopback device"""

  if not image_file.exists(): raise RuntimeError(f"Image File does not exist: {image_file.as_posix()}")

  ### Setup the Loopback Device

  lo_proc: subprocess.CompletedProcess = subprocess.run(
    [
      "losetup",
        "-f", "--show",
        image_file.as_posix(),
    ],
    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=sys.stderr,
  )
  if lo_proc.returncode != 0: raise RuntimeError(f"Failed to setup loop device: {image_file.as_posix()}")

  loop_dev_raw: str | bytes = lo_proc.stdout
  if isinstance(loop_dev_raw, bytes): loop_dev = pathlib.Path(loop_dev_raw.decode().strip())
  elif isinstance(loop_dev_raw, str): loop_dev = pathlib.Path(loop_dev_raw.strip())
  else: raise TypeError("Unknown loop device format")
  
  if not loop_dev.exists(): raise RuntimeError(f"Loop Device does not exist: {loop_dev.as_posix()}")
  return {
    "device_path": loop_dev.as_posix(),
    "device_info": { "loop_dev": loop_dev.as_posix() }
  }

def cleanup(
  device_info: dict[str, str],
) -> None:
  """Cleanup the Block Device Loopback Device"""
  loop_dev = pathlib.Path(device_info['loop_dev'])
  if not loop_dev.exists(): raise RuntimeError(f"Loop Device does not exist: {loop_dev.as_posix()}")
  proc: subprocess.CompletedProcess = subprocess.run(
    [
      "losetup",
        "-d",
        loop_dev.as_posix(),
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to cleanup loop device: {loop_dev.as_posix()}")
