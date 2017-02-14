import posix, tables, os, times

import reactor/async
import reactorfuse/raw
import reactorfuse/fuse_kernel

type
  FS = ref object
    mountPoint: string
    backend: string
    inodePathTab: Table[NodeId, string]
    fdInodeTab: Table[uint64,NodeId]
    inodeFdTab: Table[NodeId, uint64]
    fdOpenCountTab: Table[uint64, int]
    conn: FuseConnection

proc newFS(mountPoint, backend: string): FS =
  result = FS(
    mountPoint: mountPoint,
    backend: backend,
    inodePathTab: initTable[NodeId, string](),
    inodeFdTab: initTable[NodeId, uint64](),
    fdInodeTab: initTable[uint64, NodeId](),
    fdOpenCountTab: initTable[uint64, int]()
    )

  result.inodePathTab[1] = backend

template checkInode(fs: FS, nodeId: NodeId) =
  # check inode id exists
  if not fs.inodePathTab.hasKey(nodeId):
    await fs.conn.respondError(req, ENOENT)
    return

proc getPath(fs: FS, nodeId: NodeId): string =
  return fs.inodePathTab[nodeId]

proc getPathFromInodePath(fs: FS, nodeId: NodeId, path: string): string =
  let parentPath = fs.getPath(nodeId)

  return joinPath(parentPath, path)

proc addPath(fs: FS, nodeId: NodeId, path: string) =
  # add path with give inode id to FS metadata

  # handle hardlink
  # one inode may map to multiple paths
  if not fs.inodePathTab.hasKey(nodeId):
    fs.inodePathTab[nodeId] = path
    return

  fs.inodePathTab[nodeId] = path


proc doGetAttr(fs: FS, path: string="", nodeId: NodeId=0, fd:cint=0 ): tuple[attr:Attributes, ok: bool] =
  # get attribute of a file or dir
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
  fs.checkInode(req.nodeId)
  let path = fs.getPath(req.nodeId)

  let (attr, _) = fs.doGetAttr(path, req.nodeId)
  await fs.conn.respondToGetAttr(req, attr)
 
proc openDirectory(fs: FS, req: Request) {.async} =
  # FUSE_OPENDIR
  await fs.conn.respondToOpen(req, req.nodeId)

proc readDirectory(fs: FS, req: Request) {.async} =
  # FUSE_READDIR
  fs.checkInode(req.nodeId)
  let path = fs.getPath(req.nodeId)

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

proc mkdirHandler(fs: FS, req: Request) {.async} =
  # FUSE_MKDIR handler
  fs.checkInode(req.nodeId)
  let path = fs.getPathFromInodePath(req.nodeId, req.mkdirName)
  discard mkdir(path.cstring, req.mkdirMode.cint)
  discard chown(path.cstring, req.uid.Uid, req.gid.Gid)
 
  # get attr
  let (attr, ok) = fs.doGetAttr(path, 0)
  if not ok:
    await fs.conn.respondError(req, posix.EIO)
    return

  fs.addPath(attr.ino, path)
  await fs.conn.respondToMkdir(req, attr.ino, attr)
  
proc lookup(fs: FS, req: Request) {.async} =
  # FUSE_LOOKUP handler
  fs.checkInode(req.nodeId)

  # get lookup path
  let path = fs.getPathFromInodePath(req.nodeId, req.lookupName)

  # get attr
  let (attr, ok) = fs.doGetAttr(path, 0)
  if not ok:
    await fs.conn.respondError(req, ENOENT)
    return

  if req.lookupName != "." and req.lookupName != "..":
    fs.addPath(attr.ino, path)

  await fs.conn.respondToLookup(req, attr.ino, attr)

proc create(fs: FS, req: Request) {.async} =
  # FUSE_CREATE handler
  fs.checkInode(req.nodeId)
  
  let path = fs.getPathFromInodePath(req.nodeId, req.createName)

  # open the file
  let fd = posix.open(path, req.createFlags.cint or O_CREAT or O_TRUNC)

  let (attr, _) = fs.doGetAttr(fd=fd)
  # add metadata
  fs.addPath(attr.ino, path)
  fs.inodeFdTab[attr.ino.NodeId] = fd.uint64
  fs.fdInodeTab[fd.uint64] = attr.ino.NodeId
  fs.fdOpenCountTab[fd.uint64] = 1

  await fs.conn.respondToCreate(req, attr.ino.NodeId, fd.uint64, attr)

proc writeHandler(fs: FS, req: Request) {.async} =
  # FUSE_WRITE handler
  discard lseek(req.fileHandle.cint, req.writeOffset.Off, SEEK_SET)
  let written = posix.write(req.fileHandle.cint, req.writeData.pointer, req.writeData.len)
  await fs.conn.respondToWrite(req, written.uint32)

proc releaseFile(fs: FS, req: Request) {.async} =
  # FUSE_RELEASE handler
  if not fs.fdOpenCountTab.hasKey(req.fileHandle):
    return

  if fs.fdOpenCountTab[req.fileHandle] > 1:
    fs.fdOpenCountTab[req.fileHandle] -= 1
    return

  # if not opened anymore, delete from table
  fs.fdOpenCountTab.del(req.fileHandle)
  fs.inodeFdTab.del(req.nodeId)
  fs.fdInodeTab.del(req.fileHandle)
  discard close(req.fileHandle.cint)
    

proc openFile(fs: FS, req: Request) {.async} =
  # FUSE_OPEN handler
  
  if fs.inodeFdTab.hasKey(req.nodeId):
    # already opened
    let fd = fs.inodeFdTab[req.nodeId]
    fs.fdOpenCountTab[fd] += 1
    await fs.conn.respondToOpen(req, fd)
    return

  # make sure it has O_CREAT in flags
  #assert req.flags and O_CREAT == 0

  # open the file
  let path = fs.getPath(req.nodeId)
  let fd = open(path.cstring, req.flags.cint)
  if fd < 0:
    await fs.conn.respondError(req, posix.EIO)
    return

  # register
  fs.inodeFdTab[req.nodeId] = fd.uint64
  fs.fdInodeTab[fd.uint64] = req.nodeId
  fs.fdOpenCountTab[fd.uint64] = 1

  await fs.conn.respondToOpen(req, fd.uint64)

proc readFileHandler(fs: FS, req: Request) {.async} =
  # FUSE_READ handler

  # seek and read
  var buf = newString(req.size)
  discard lseek(req.fileHandle.cint, req.offset.Off, SEEK_SET)
  discard posix.read(req.fileHandle.cint, buf.cstring.pointer, req.size.int)

  await fs.conn.respondToRead(req, buf)

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
        await fs.openFile(req)
    of fuseRead:
      if req.isDir:
        await fs.readDirectory(req)
      else:
        await fs.readFileHandler(req)
    of fuseLookup:
      await fs.lookup(req)
    of fuseCreate:
      await fs.create(req)
    of fuseWrite:
      await fs.writeHandler(req)
    of fuseRelease:
      await fs.releaseFile(req)
    of fuseMkdir:
      await fs.mkdirHandler(req)
    else:
      echo("unknown message kind:", req.kind)
      await conn.respondError(req, ENOSYS)

proc mymain(mountPoint, backend: string) {.async} =
  var fs = newFS(mountPoint, backend)
  await fs.loop()

mymain("/mnt/rf", "/root/backend").runLoop()
