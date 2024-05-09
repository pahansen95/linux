import pathlib, subprocess, sys
from loguru import logger

### Local Imports
import schemas
###

def create(
  src: pathlib.Path,
  dst: pathlib.Path,
  compress_algo: str | None,
) -> schemas.ArtifactStatus:
  """Creates the Artifact as a Compressed Archive"""

  if dst.exists(): raise RuntimeError(f"Artifact already exists: {dst.as_posix()}")

  if compress_algo is None: _algo_flag = None # Don't compress the archive
  elif compress_algo == 'gz': _algo_flag = '--gzip'
  elif compress_algo == 'xz': _algo_flag = '--xz'
  elif compress_algo == 'bz2': _algo_flag = '--bzip2'
  elif compress_algo == 'lzma': _algo_flag = '--lzma'
  elif compress_algo == 'lzip': _algo_flag = '--lzip'
  elif compress_algo == 'lzop': _algo_flag = '--lzop'
  elif compress_algo == 'zstd': _algo_flag = '--zstd'
  else: raise ValueError(f"Unsupported Compression Algorithm: {compress_algo}")

  if src.is_dir():
    workdir: pathlib.Path = src
    name = './'
  else:
    workdir: pathlib.Path = src.parent
    name = src.name
  args = [a for a in [
    'tar', '-cv', _algo_flag,
      '-f', dst.as_posix(),
      '-C', workdir.as_posix(),
      name,
  ] if a is not None]
  logger.debug(f"Creating Artifact: {' '.join(args)}")
  proc: subprocess.CompletedProcess = subprocess.run(
    args,
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to create a compressed archive")

  ### Calculate the Hash of the Artifact
  proc: subprocess.CompletedProcess = subprocess.run(
    [
      'md5sum', dst.as_posix(),
    ],
    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to calculate the hash of the artifact")
  artifact_hash = proc.stdout.decode().split()[0]

  return {
    "path": dst.as_posix(),
    "fmt": f"tar.{compress_algo}",
    "size_bytes": dst.stat().st_size,
    "hash": f'md5:{artifact_hash}',
  }

def extract(
  src: pathlib.Path,
  dst: pathlib.Path,
  hash: str,
  compress_algo: str | None,
) -> None:
  """Extracts the Artifact from a Compressed Archive"""

  if not src.exists(): raise RuntimeError(f"Artifact does not exist: {src.as_posix()}")
  if dst.exists() and dst.resolve().is_file(): raise RuntimeError("You cannot extract a tar archive into a file!")
  if not (dst.exists() and dst.resolve().is_dir()): raise RuntimeError(f"Destination Folder does not exist or is not a directory: {dst.as_posix()}")

  try: _algo, _hash = hash.split(':', 1)
  except ValueError: raise ValueError("Invalid Hash Format; expected ALGO:FINGERPRINT")

  proc = subprocess.run(
    [ f"{_algo.lower()}sum", src.as_posix() ],
    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to calculate the hash of the artifact")
  calc_hash = proc.stdout.decode().split()[0]
  if calc_hash != _hash: raise ValueError(f"Hash Mismatch; expected `{_hash}`, got `{calc_hash}`")

  if compress_algo is None: _algo_flag = None # Don't compress the archive
  elif compress_algo == 'gz': _algo_flag = '--gzip'
  elif compress_algo == 'xz': _algo_flag = '--xz'
  elif compress_algo == 'bz2': _algo_flag = '--bzip2'
  elif compress_algo == 'lzma': _algo_flag = '--lzma'
  elif compress_algo == 'lzip': _algo_flag = '--lzip'
  elif compress_algo == 'lzop': _algo_flag = '--lzop'
  elif compress_algo == 'zstd': _algo_flag = '--zstd'
  else: raise ValueError(f"Unsupported Compression Algorithm: {compress_algo}")

  args = [a for a in [
    'tar', '-xv', _algo_flag,
      '-f', src.as_posix(),
      '-C', dst.as_posix(),
  ] if a is not None]
  logger.debug(f"Extracting Artifact: {' '.join(args)}")
  proc: subprocess.CompletedProcess = subprocess.run(
    args,
    stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr,
  )
  if proc.returncode != 0: raise RuntimeError("Failed to extract the compressed archive")
