import os, sys, orjson
from typing import TypedDict, Literal
from loguru import logger

### Local Imports
from . import alpine, default, utils
###

supported_tmpl_t = ['alpine']

def args_to_kv(argv: list[str]) -> dict:
  kv = {}
  for arg in argv:
    if arg.startswith('-'): continue
    if '=' in arg:
      k, v = arg.split('=', 1)
      kv[k] = v
  return kv

def main() -> int:
  argv = sys.argv[1:]
  if len(argv) < 1: raise CLIError("Missing Template Type")
  tmpl = argv[0].lower()
  if len(argv) > 1: kv = args_to_kv(argv[1:])
  else: kv = {}
  cfg = default.assemble(**kv)
  try:
    if tmpl == 'alpine': cfg |= alpine.assemble(**kv)
    else: raise CLIError(f'Unsupported Template Type: {tmpl}')
  except RuntimeError as e:
    raise CLIError(f'Failed to Initialize Template: {tmpl}') from e

  buf = orjson.dumps(cfg, default=utils.json_default, option=orjson.OPT_INDENT_2 | orjson.OPT_APPEND_NEWLINE)
  buf_len = len(buf)
  buf_offset = 0
  while buf_offset < buf_len: buf_offset += sys.stdout.buffer.write(buf[0:])
  return 0

class CLIError(RuntimeError): ...

if __name__ == '__main__':
  _rc = 1
  logger.remove()
  logger.add(sys.stderr, level=os.environ.get('LOG_LEVEL', 'DEBUG'), enqueue=True, colorize=True)
  try: _rc = main()
  except CLIError as e: logger.critical(str(e))
  except Exception as e: logger.opt(exception=e).critical("Unhandled Exception")
  finally:
    logger.complete()
    sys.stderr.flush()
    sys.stdout.flush()
    exit(_rc)
