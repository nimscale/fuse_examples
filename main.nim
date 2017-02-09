import posix, tables

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

proc getAttr(fs: FS, req: Request) {.async} =
  echo("getAttr")

  if not fs.inodePathTab.hasKey(req.nodeId):
      await fs.conn.respondError(req, ENOENT)
  let path = fs.inodePathTab[req.nodeId]


proc loop(fs: FS) {.async} =
  let conn = await mount(fs.mountPoint, ())
  fs.conn = conn
  
  while true:
    let msg = await conn.requests.receive()
    echo("recv", msg.repr)

    case msg.kind
    of fuseGetAttr:
      await fs.getAttr(msg)
    of fuseOpen:
      echo("fuseOpen")
    of fuseRead:
      echo("fuseRead")
    of fuseLookup:
      echo("fuseLookup")
      await conn.respondError(msg, ENOENT)
    else:
      echo("unknown message kind:", msg.kind)
proc mymain(mountPoint, backend: string) {.async} =
  var fs = newFS(mountPoint, backend)
  await fs.loop()

mymain("/mnt/rf", "/root/backend").runLoop()
