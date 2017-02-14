import tables, posix, times

import reactor
import reactorfuse/raw

type
  # file content in-memory buffer
  Buf = ref object
    data: seq[char]
    size: int
    pos: int

  Inode = ref object
    attr: Attributes
    content: Buf
    isDir: bool
    children: TableRef[string, NodeId]

  FS = ref object
    id: NodeId
    inodes: TableRef[NodeId, Inode]
    conn: FuseConnection
    mountPoint: string


proc newBuf(): Buf =
  result = Buf (
    data: @[],
    size: 0,
    pos: 0
    )
proc extend*(buf: Buf, size: int) =
  if (buf.size >= size):
      return
  var newData = newSeq[char](size)
  if buf.size > 0:
    copyMem(addr(newData[0]), addr(buf.data[0]), buf.size)
  buf.size = size
  buf.data = newData

proc writeBuf(buf: Buf, data: cstring, offset, size: int)=
  buf.extend(offset + size)
  copyMem(addr(buf.data[offset]), data.pointer, size)

proc toString(buf: Buf, offset, size: int): string =
  var endOffset = offset + size - 1
  if endOffset > (buf.size - 1):
    endOffset = buf.size - 1

  # get the data
  let data = buf.data[offset..endOffset]

  result = newStringOfCap(size)
  for ch in data:
    result.add(ch)
  
proc initDir(nodeId: NodeId): Inode =
  var attr = Attributes(
    ino: nodeId,
    size: 4096,
    mode: cast [uint32](S_IFDIR or 0755),
    nlink: 0
    )

  result = Inode(
      attr: attr,
      children: newTable[string, NodeId](),
      isDIr: true
      )

proc newFS(mountPoint: string): FS =
  result = FS(
      id: 1,
      mountPoint: mountPoint,
      inodes: newTable[NodeId, Inode]()
      )

  # initialize attribute fors root dir
  result.inodes[1.NodeId] = initDir(1.NodeId)

proc fd(ino: Inode): uint64 =
  # generate fd from an inode
  # TODO : proper ID generator
  return ino.attr.ino.uint64

proc getNewId(fs: FS): NodeId =
  # generate new inode id
  fs.id += 1
  fs.id

template checkInode(fs: FS, nodeId: NodeId) =
  # check inode id exists
  if not fs.inodes.hasKey(nodeId):
    await fs.conn.respondError(req, ENOENT)
    return

proc getAttr(fs: FS, req: Request) {.async} =
  # FUSE_GETATTR handler
  fs.checkInode(req.nodeId)
  let inode = fs.inodes[req.nodeId]
  await fs.conn.respondToGetAttr(req, inode.attr)

proc openDirectory(fs: FS, req: Request) {.async} =
  # opendir handler
  fs.checkInode(req.nodeId)
  await fs.conn.respondToOpen(req, req.nodeId)

proc readDirectory(fs: FS, req: Request) {.async} =
  # readdir handler
  fs.checkInode(req.nodeId)

  let dir = fs.inodes[req.nodeId]
  
  var buf = ""
  for child, childId in dir.children:
    buf.appendDirent(child, childId)
  
  await fs.conn.respondToReadAll(req, buf)

proc lookup(fs: FS, req: Request) {.async} =
  # lookup handler
  fs.checkInode(req.nodeId)
 
  # get parent inode
  var parent = fs.inodes[req.nodeId]

  # check file exist in parent dir
  if not parent.children.hasKey(req.lookupName):
    await fs.conn.respondError(req, ENOENT)
    return

  # get inode
  let nodeId = parent.children[req.lookupName]
  fs.checkInode(nodeId)
  let inode = fs.inodes[nodeId]

  await fs.conn.respondToLookup(req, nodeId, inode.attr)

proc create(fs: FS, req: Request) {.async} =
  # FUSE_CREATE creates file
  
  # check parent inode exists and get it
  fs.checkInode(req.nodeId)
  var dir = fs.inodes[req.nodeId]

  # create attr for newly created files
  var now = getTime()
  let attr = Attributes(
    ino: fs.getNewId(),
    size: 0,
    blocks: 0,
    atime: now.toSeconds().uint64,
    ctime: now.toSeconds().uint64,
    mtime: now.toSeconds().uint64,
    mode: req.createMode,
    nlink: 1,
    uid: req.uid,
    gid: req.gid
    #rdev:
  )
  let newFile = Inode(
      attr: attr,
      content: newBuf()
      )
  
  # add to inode tables
  fs.inodes[newFile.attr.ino] = newFile

  # add newly created filename to this dir
  dir.children[req.createName] = newFile.attr.ino

  await fs.conn.respondToCreate(req, attr.ino, newFile.fd, attr)

proc writeHandler(fs: FS, req: Request) {.async} =
  # write handler
  fs.checkInode(req.nodeId)

  var inode = fs.inodes[req.nodeId]
  inode.content.writeBuf(req.writeData, req.writeOffset.int, req.writeData.len)
  
  await fs.conn.respondToWrite(req, req.writeData.len.uint32)

proc readHandler(fs: FS, req: Request) {.async} =
  fs.checkInode(req.nodeId)

  let inode = fs.inodes[req.nodeId]
  let str = inode.content.toString(req.offset.int, req.size.int)
  
  echo("readHandler....str=", str)
  
  await fs.conn.respondToRead(req, str)

proc loop(fs: FS) {.async} =
  let conn = await mount(fs.mountPoint, ())
  fs.conn = conn

  while true:
    let req = await conn.requests.receive()
    echo("recv ", req.repr)

    case req.kind
    of fuseGetAttr:
      await fs.getAttr(req)
    of fuseOpen:
      if req.isDir:
        await fs.openDirectory(req)
      else:
        #await fs.openFile(req)
        await conn.respondError(req, ENOSYS)
    of fuseRead:
      if req.isDir:
        await fs.readDirectory(req)
      else:
        await fs.readHandler(req)
    of fuseCreate:
      await fs.create(req)
    of fuseWrite:
      await fs.writeHandler(req)
    of fuseLookup:
      await fs.lookup(req)
    else:
      echo("unknown message kind:", req.kind)
      await conn.respondError(req, ENOSYS)

proc main(mountPoint: string) {.async} =
  var fs = newFS(mountPoint)
  await fs.loop()

main("/mnt/rf").runLoop()
