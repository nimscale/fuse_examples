import posix, tables, os, times

import reactor/async
include reactorfuse

type
  FS = ref object
    mountPoint: string
    backend: string
    inodePathTab: Table[NodeId, string]
    fdInodeTab: Table[int,int]
    inodeFdTab: Table[int, int]
    fdOpenCountTab: Table[int, int]
    conn: FuseConnection

proc newFS(mountPoint, backend: string): FS =
  result = FS(
    mountPoint: mountPoint,
    backend: backend,
    inodePathTab: initTable[NodeId, string]()
    )

  result.inodePathTab[1] = backend

proc getPath(fs: FS, nodeId: NodeId): tuple[path: string, exists: bool] =
  if not fs.inodePathTab.hasKey(nodeId):
    return ("", false)
  
  return (fs.inodePathTab[nodeId], true)

proc getAttr(fs: FS, req: Request) {.async} =
  let (path, exists) = fs.getPath(req.nodeId)
  if not exists:
    await fs.conn.respondError(req, ENOENT)
    return
  
  var st: Stat
  if lstat(path, st) != 0:
    await fs.conn.respondError(req, ENOENT)
    return

  let attr= Attributes (
    ino:  req.nodeId,
    size: st.st_size.uint64,
    blocks: st.st_blocks.uint64,
    atime: st.st_atime.toSeconds().uint64,
    mtime: st.st_mtime.toSeconds().uint64,
    ctime: st.st_ctime.toSeconds().uint64,
    mode: st.st_mode.uint32,
    nlink: st.st_nlink.uint32,
    uid: st.st_uid.uint32,
    gid: st.st_gid.uint32,
    rdev: st.st_rdev.uint32
    )

  await fs.conn.respondToGetAttr(req, attr)

proc openDirectory(fs: FS, req: Request) {.async} =
  await fs.conn.respondToOpen(req, req.nodeId)

proc readDirectory(fs: FS, req: Request) {.async} =
  let (path, exists) = fs.getPath(req.nodeId)
  if not exists:
    await fs.conn.respondError(req, ENOENT)
    return

  var buf = ""
  let dir = opendir(path)
  var dirent: ptr Dirent
  while true:
    dirent = readdir(dir)
    if dirent == nil:
      break
    buf.appendDirent($dirent.d_name, dirent.d_ino.uint64)

  discard closedir(dir)
  await fs.conn.respondToReadAll(req, buf)
  
proc loop(fs: FS) {.async} =
  let conn = await mount(fs.mountPoint, ())
  fs.conn = conn
  
  while true:
    let req = await conn.requests.receive()
    echo("recv", req.repr)

    case req.kind
    of fuseGetAttr:
      await fs.getAttr(req)
    of fuseOpen:
      if req.isDir:
        await fs.openDirectory(req)
      else:
        echo("fuseOpen")
    of fuseRead:
      if req.isDir:
        await fs.readDirectory(req)
      else:
        echo("fuseRead")
    of fuseLookup:
      echo("fuseLookup")
      await conn.respondError(req, ENOENT)
    else:
      echo("unknown message kind:", req.kind)
      await conn.respondError(req, ENOSYS)

proc mymain(mountPoint, backend: string) {.async} =
  var fs = newFS(mountPoint, backend)
  await fs.loop()

mymain("/mnt/rf", "/root/backend").runLoop()
