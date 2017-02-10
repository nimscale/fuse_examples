import posix, tables, os, times

import reactor/async
include reactorfuse

type
  FS = ref object
    mountPoint: string
    backend: string
    inodePathTab: Table[NodeId, string]
    fdInodeTab: Table[cint,NodeId]
    inodeFdTab: Table[NodeId, cint]
    fdOpenCountTab: Table[cint, int]
    conn: FuseConnection

proc newFS(mountPoint, backend: string): FS =
  result = FS(
    mountPoint: mountPoint,
    backend: backend,
    inodePathTab: initTable[NodeId, string](),
    inodeFdTab: initTable[NodeId, cint](),
    fdInodeTab: initTable[cint, NodeId](),
    fdOpenCountTab: initTable[cint, int]()
    )

  result.inodePathTab[1] = backend

proc getPath(fs: FS, nodeId: NodeId): tuple[path: string, exists: bool] =
  if not fs.inodePathTab.hasKey(nodeId):
    return ("", false)
  
  return (fs.inodePathTab[nodeId], true)

proc getPathFromInodePath(fs: FS, nodeId: NodeId, path: string): tuple[path: string, exists: bool] =
   # check parent inode/path
  let (parentPath, exists) = fs.getPath(nodeId)
  if not exists:
    return ("", false)

  return (joinPath(parentPath, path), true)

proc doGetAttr(fs: FS, path: string="", nodeId: NodeId=0, fd:cint=0 ): tuple[attr:Attributes, ok: bool] =
  var st: Stat
  let ret = if fd == 0: lstat(path, st) else: fstat(fd, st)
  if ret != 0:
    var attr: Attributes
    return (attr, false)

  let inodeId = if nodeId == 0: st.st_ino.NodeId else: nodeId
  let attr= Attributes (
    ino:  inodeId,
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

  return (attr, true)

proc getAttr(fs: FS, req: Request) {.async} =
  let (path, exists) = fs.getPath(req.nodeId)
  if not exists:
    await fs.conn.respondError(req, ENOENT)
    return

  let (attr, _) = fs.doGetAttr(path, req.nodeId)
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

proc lookup(fs: FS, req: Request) {.async} =
  # get lookup path
  let (path, exists) = fs.getPathFromInodePath(req.nodeId, req.lookupName)
  if not exists:
    await fs.conn.respondError(req, ENOENT)
    return

  # get attr
  let (attr, ok) = fs.doGetAttr(path, 0)
  if not ok:
    await fs.conn.respondError(req, ENOENT)
    return

  await fs.conn.respondToLookup(req, attr.ino, attr)

proc create(fs: FS, req: Request) {.async} =
  let (path, parentExists) = fs.getPathFromInodePath(req.nodeId, req.createName)
  if not parentExists:
    await fs.conn.respondError(req, ENOENT)
    return

  let fd = posix.open(path, req.createFlags.cint or O_CREAT or O_TRUNC)

  let (attr, _) = fs.doGetAttr(fd=fd)
  # add metadata
  fs.inodePathTab[attr.ino.NodeId] = path
  fs.inodeFdTab[attr.ino.NodeId] = fd
  fs.fdInodeTab[fd] = attr.ino.NodeId
  fs.fdOpenCountTab[fd] = 1

  await fs.conn.respondToCreate(req, attr.ino.NodeId, fd.uint64, attr)

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
        echo("********* fuseOpen file *********")
    of fuseRead:
      if req.isDir:
        await fs.readDirectory(req)
      else:
        echo("********* fuseRead file **********")
    of fuseLookup:
      await fs.lookup(req)
    of fuseCreate:
      await fs.create(req)
    else:
      echo("unknown message kind:", req.kind)
      await conn.respondError(req, ENOSYS)

proc mymain(mountPoint, backend: string) {.async} =
  var fs = newFS(mountPoint, backend)
  await fs.loop()

mymain("/mnt/rf", "/root/backend").runLoop()
