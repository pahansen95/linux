import pathlib, sys, subprocess, uuid

def wipe(
  device_path: pathlib.Path,
  secure: bool = False,
) -> None:
  """Wipe a Filesystem from a Device; Optionally scrub data if secure is True"""
  if secure: raise NotImplementedError("Secure Wipe not implemented")
  if not (device_path.exists() and device_path.is_block_device()): raise RuntimeError(f"Device Path does not exist or is not a block device: {device_path.as_posix()}")

  proc: subprocess.CompletedProcess = subprocess.run(
    [
      "wipefs",
        "--all", "--force", 
        device_path.as_posix(),
    ],
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError(f"Failed to wipe block device: {device_path.as_posix()}")
