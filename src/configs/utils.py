import pathlib, uuid

def json_default(obj) -> object:
  if isinstance(obj, pathlib.Path): return obj.as_posix()
  elif isinstance(obj, uuid.UUID): return str(obj)
  else: return obj
